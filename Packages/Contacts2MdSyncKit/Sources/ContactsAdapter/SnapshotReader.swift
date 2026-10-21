internal import ContactModel
internal import Contacts
internal import Foundation

/// Reads a full `AppleSnapshot`: unified contacts, the underlying cards of
/// each (`unifyResults = false`), containers, and iCloud/local groups.
///
/// Card → unified mapping: a single card's unified id is its own id, so those
/// map directly. A linked contact's unified id is synthesized (neither card's
/// id, spike S4), so its cards are found with
/// `isUnifiedWithContact(withIdentifier:)` against unified contacts with the
/// same name, then, as a last resort, `unifiedContact(withIdentifier:)`.
///
/// Each card is read with every field except images (`AppleCard.values`) so
/// the engine can apply card precedence instead of the unified blend.
struct SnapshotReader {
    let store: CNContactStore

    func read() throws -> AppleSnapshot {
        let notesAvailable = CNContactStoreAdapter.notesAvailable(in: store)
        let containers = try CNContactStoreAdapter.containers(in: store)
        let unified = try fetchUnified(includeNote: notesAvailable)
        let cards = try fetchCards(in: containers, unified: unified, includeNote: notesAvailable)
        let groups = try fetchGroups(in: containers, unifiedIDByCard: cards.unifiedIDByCard)
        let contacts = unified.map { contact in
            let ownCards = cards.byUnified[contact.identifier] ?? []
            return AppleContact(
                unifiedID: contact.identifier,
                cards: ownCards.isEmpty
                    ? [AppleCard(id: contact.identifier, containerID: "", accountKind: .unknown)] : ownCards,
                contact: AppleContactMapper.canonical(from: contact),
                imageData: AppleContactMapper.imageData(of: contact),
                imageUnavailable: AppleContactMapper.imageUnavailable(of: contact),
                groupIDs: groups.byUnified[contact.identifier] ?? []
            )
        }
        return AppleSnapshot(
            contacts: contacts, containers: containers, groups: groups.all, notesAvailable: notesAvailable)
    }

    /// 1. Unified contacts with the full key set.
    private func fetchUnified(includeNote: Bool) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: AppleContactMapper.keysToFetch(includeNote: includeNote))
        request.unifyResults = true
        var unified: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in unified.append(contact) }
        return unified
    }

    private struct Cards {
        var byUnified: [String: [AppleCard]] = [:]
        var unifiedIDByCard: [String: String] = [:]
    }

    /// 2. Underlying cards per container, mapped to their unified contact.
    private func fetchCards(in containers: [AppleContainer], unified: [CNContact], includeNote: Bool) throws -> Cards {
        let unifiedByID = Dictionary(unified.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(grouping: unified, by: Self.nameKey)
        var result = Cards()
        for container in containers {
            let request = CNContactFetchRequest(keysToFetch: AppleContactMapper.cardKeys(includeNote: includeNote))
            request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.id)
            request.unifyResults = false
            var cards: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, _ in cards.append(contact) }
            for card in cards {
                guard let owner = try unifiedID(for: card, unifiedByID: unifiedByID, byName: byName) else { continue }
                result.unifiedIDByCard[card.identifier] = owner
                result.byUnified[owner, default: []].append(
                    AppleCard(
                        id: card.identifier, containerID: container.id, accountKind: container.kind,
                        stampID: AppleContactMapper.stampID(of: card),
                        values: AppleContactMapper.canonical(from: card)))
            }
        }
        return result
    }

    private struct Groups {
        var all: [AppleGroup] = []
        var byUnified: [String: [String]] = [:]
    }

    /// 3. Groups (iCloud / On My Mac only) and their members.
    private func fetchGroups(in containers: [AppleContainer], unifiedIDByCard: [String: String]) throws -> Groups {
        var result = Groups()
        for container in containers where container.kind.supportsGroups {
            let found = try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: container.id))
            for group in found {
                result.all.append(AppleGroup(id: group.identifier, name: group.name, containerID: container.id))
                let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as NSString])
                request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
                request.unifyResults = false
                try store.enumerateContacts(with: request) { member, _ in
                    guard let owner = unifiedIDByCard[member.identifier] else { return }
                    if result.byUnified[owner]?.contains(group.identifier) != true {
                        result.byUnified[owner, default: []].append(group.identifier)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Partial re-read (history acceleration, M5)

    /// The unified contacts that contain any of `cardIDs`, each with all its
    /// cards (found among `siblingHints`, the requested cards, and cards with
    /// the same name), plus every container and group. Cards that no longer
    /// exist are skipped.
    func refetch(cardIDs: [String], siblingHints: [String]) throws -> AppleRefetch {
        let notesAvailable = CNContactStoreAdapter.notesAvailable(in: store)
        let containers = try CNContactStoreAdapter.containers(in: store)
        let unified = try unifiedContacts(
            containing: cardIDs, keys: AppleContactMapper.keysToFetch(includeNote: notesAvailable))
        let candidates = try sameNameCards(of: unified).union(cardIDs + siblingHints + unified.map(\.identifier))
        let cards = try cards(candidates, of: unified, containers: containers, includeNote: notesAvailable)
        let groups = try fetchGroups(in: containers, unifiedIDByCard: cards.unifiedIDByCard)
        let contacts = unified.map { contact in
            let ownCards = cards.byUnified[contact.identifier] ?? []
            return AppleContact(
                unifiedID: contact.identifier,
                cards: ownCards.isEmpty
                    ? [AppleCard(id: contact.identifier, containerID: "", accountKind: .unknown)] : ownCards,
                contact: AppleContactMapper.canonical(from: contact),
                imageData: AppleContactMapper.imageData(of: contact),
                imageUnavailable: AppleContactMapper.imageUnavailable(of: contact),
                groupIDs: groups.byUnified[contact.identifier] ?? [])
        }
        return AppleRefetch(
            contacts: contacts, containers: containers, groups: groups.all, notesAvailable: notesAvailable)
    }

    /// The unified contact holding each card (deduplicated; deleted cards skipped).
    private func unifiedContacts(containing cardIDs: [String], keys: [any CNKeyDescriptor]) throws -> [CNContact] {
        var unified: [CNContact] = []
        for id in cardIDs where !unified.contains(where: { Self.holds($0, card: id) }) {
            do {
                unified.append(try store.unifiedContact(withIdentifier: id, keysToFetch: keys))
            } catch let error as NSError
                where error.domain == CNErrorDomain && error.code == CNError.Code.recordDoesNotExist.rawValue
            {
                continue
            }
        }
        return unified
    }

    /// Card ids with the same name as any of `unified` (Contacts links same-name cards on its own).
    private func sameNameCards(of unified: [CNContact]) throws -> Set<String> {
        var ids = Set<String>()
        for contact in unified {
            let name = Self.nameKey(contact).split(separator: "|").filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty else { continue }
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as NSString])
            request.predicate = CNContact.predicateForContacts(matchingName: name)
            request.unifyResults = false
            try store.enumerateContacts(with: request) { card, _ in ids.insert(card.identifier) }
        }
        return ids
    }

    /// The `candidates` that belong to one of `unified`, with their containers.
    private func cards(
        _ candidates: Set<String>, of unified: [CNContact], containers: [AppleContainer], includeNote: Bool
    ) throws -> Cards {
        let byID = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let request = CNContactFetchRequest(keysToFetch: AppleContactMapper.cardKeys(includeNote: includeNote))
        request.predicate = CNContact.predicateForContacts(withIdentifiers: candidates.sorted())
        request.unifyResults = false
        var fetched: [CNContact] = []
        try store.enumerateContacts(with: request) { card, _ in fetched.append(card) }
        var result = Cards()
        for card in fetched {
            guard let owner = unified.first(where: { Self.holds($0, card: card.identifier) }) else { continue }
            let predicate = CNContainer.predicateForContainerOfContact(withIdentifier: card.identifier)
            let containerID = try store.containers(matching: predicate).first?.identifier ?? ""
            result.unifiedIDByCard[card.identifier] = owner.identifier
            result.byUnified[owner.identifier, default: []].append(
                AppleCard(
                    id: card.identifier, containerID: containerID, accountKind: byID[containerID]?.kind ?? .unknown,
                    stampID: AppleContactMapper.stampID(of: card), values: AppleContactMapper.canonical(from: card)))
        }
        return result
    }

    private static func holds(_ unified: CNContact, card id: String) -> Bool {
        unified.identifier == id || unified.isUnifiedWithContact(withIdentifier: id)
    }

    private func unifiedID(
        for card: CNContact, unifiedByID: [String: CNContact], byName: [String: [CNContact]]
    )
        throws -> String?
    {
        if unifiedByID[card.identifier] != nil { return card.identifier }
        if let match = byName[Self.nameKey(card)]?.first(where: {
            $0.isUnifiedWithContact(withIdentifier: card.identifier)
        }) {
            return match.identifier
        }
        let owner = try? store.unifiedContact(
            withIdentifier: card.identifier, keysToFetch: [CNContactIdentifierKey as NSString])
        return owner.flatMap { unifiedByID[$0.identifier] != nil ? $0.identifier : nil }
    }

    private static func nameKey(_ contact: CNContact) -> String {
        let parts = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey].map { key -> String in
            guard contact.isKeyAvailable(key) else { return "" }
            switch key {
            case CNContactGivenNameKey: return contact.givenName
            case CNContactFamilyNameKey: return contact.familyName
            default: return contact.organizationName
            }
        }
        return parts.joined(separator: "|").lowercased()
    }
}
