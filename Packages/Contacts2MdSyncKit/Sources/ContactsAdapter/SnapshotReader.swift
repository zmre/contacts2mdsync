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
