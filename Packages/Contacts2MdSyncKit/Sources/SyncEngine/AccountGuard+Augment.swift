public import ContactModel
public import Foundation

/// A snapshot with unavailable accounts' cards put back as last seen.
struct AugmentedSnapshot: Sendable {
    var snapshot: AppleSnapshot
    /// Cards kept as last seen (not in Contacts now; never written to).
    var frozenCardIDs: Set<String> = []
    /// Contacts made only of frozen cards → their record (frozen, bound, not synced).
    var ghostRecords: [String: UUID] = [:]
    /// Unified ids of contacts that are not synced at all this run: made only
    /// of frozen cards, or holding a frozen card whose values are unknown.
    var frozenContacts: Set<String> = []
}

extension AccountGuard {
    /// `snapshot` as the planner sees it: every card of an unavailable
    /// account removed (unknown, even if a few are still there), returned
    /// cards held back during the grace period removed, and the frozen
    /// cards put back: into the live contact of their record or old
    /// siblings, else as a contact of their own. The account's groups are
    /// put back too, so group-based tags do not look removed.
    func augment(_ snapshot: AppleSnapshot) -> AugmentedSnapshot {
        guard isActive || !hiddenCardIDs.isEmpty else { return AugmentedSnapshot(snapshot: snapshot) }
        var result = AugmentedSnapshot(snapshot: snapshot)
        var contacts = live(snapshot.contacts)
        var byCard: [String: Int] = [:]
        for (offset, contact) in contacts.enumerated() {
            for card in contact.cards { byCard[card.id] = offset }
        }
        var ghosts: [String: [FrozenCard]] = [:]
        for frozen in frozenCards where byCard[frozen.card.id] == nil {
            result.frozenCardIDs.insert(frozen.card.id)
            let anchor = (anchors[frozen.card.id] ?? frozen.siblingIDs).lazy.compactMap { byCard[$0] }.first
            guard let anchor else {
                ghosts[Self.ghostKey(frozen), default: []].append(frozen)
                continue
            }
            if !Self.attach(frozen, to: &contacts[anchor], notesAvailable: snapshot.notesAvailable) {
                result.frozenContacts.insert(contacts[anchor].unifiedID)
            }
        }
        for key in ghosts.keys.sorted() {
            guard let cards = ghosts[key] else { continue }
            let ghost = Self.ghost(cards, notesAvailable: snapshot.notesAvailable)
            result.frozenContacts.insert(ghost.unifiedID)
            if let record = cards.lazy.compactMap(\.recordID).first { result.ghostRecords[ghost.unifiedID] = record }
            contacts.append(ghost)
        }
        result.snapshot.contacts = contacts
        let known = Set(snapshot.groups.map(\.id))
        result.snapshot.groups += state.unavailable.filter { $0.returnedAt == nil }.flatMap(\.groups).filter {
            !known.contains($0.id)
        }
        return result
    }

    /// The live contacts without unavailable accounts' cards and without
    /// returned contacts held back.
    private func live(_ contacts: [AppleContact]) -> [AppleContact] {
        let removed = unavailableContainerIDs
        return contacts.compactMap { contact in
            guard !contact.cards.contains(where: { hiddenCardIDs.contains($0.id) }) else { return nil }
            var copy = contact
            copy.cards.removeAll { removed.contains($0.containerID) }
            guard !copy.cards.isEmpty else { return nil }
            if copy.cards.count != contact.cards.count {
                Self.materialize(&copy, from: contact)
                copy.unifiedID = copy.cards.count == 1 ? copy.cards[0].id : copy.unifiedID
            }
            return copy
        }
    }

    /// Ghost contacts are keyed by the lowest card id of the contact they came from.
    private static func ghostKey(_ frozen: FrozenCard) -> String {
        ([frozen.card.id] + frozen.siblingIDs).min() ?? frozen.card.id
    }

    /// Gives a contact's remaining cards their own values (the unified view
    /// of a contact that had a single card is that card's values).
    private static func materialize(_ contact: inout AppleContact, from original: AppleContact) {
        for index in contact.cards.indices where contact.cards[index].values == nil && original.cards.count == 1 {
            contact.cards[index].values = original.contact
        }
    }

    /// Puts a frozen card into a live contact. `false` when the contact's
    /// values can no longer be computed per card (a value is unknown): the
    /// contact is then not synced this run.
    private static func attach(_ frozen: FrozenCard, to contact: inout AppleContact, notesAvailable: Bool) -> Bool {
        if contact.cards.count == 1, contact.cards[0].values == nil { contact.cards[0].values = contact.contact }
        let known = contact.cards.allSatisfy { $0.values != nil } && frozen.card.values != nil
        contact.cards.append(frozen.card)
        for group in frozen.groupIDs where !contact.groupIDs.contains(group) { contact.groupIDs.append(group) }
        if notesAvailable, !frozen.notesKnown { contact.notesUnknown = true }
        if frozen.hadImage, contact.imageData == nil { contact.imageUnavailable = true }
        return known
    }

    /// A contact made only of frozen cards (as last seen).
    private static func ghost(_ cards: [FrozenCard], notesAvailable: Bool) -> AppleContact {
        let ordered = cards.sorted { $0.card.id < $1.card.id }
        let first = ordered[0]
        let whole = Set(first.siblingIDs + [first.card.id]) == Set(ordered.map(\.card.id))
        let display =
            (whole ? first.unified : nil) ?? first.card.values ?? first.unified
            ?? CanonicalContact(kind: .person, title: "")
        var contact = AppleContact(
            unifiedID: first.card.id, cards: ordered.map(\.card), contact: display,
            imageUnavailable: ordered.contains(where: \.hadImage),
            groupIDs: Array(Set(ordered.flatMap(\.groupIDs))).sorted())
        if notesAvailable, ordered.contains(where: { !$0.notesKnown }) { contact.notesUnknown = true }
        return contact
    }
}

extension AccountGuard {
    /// The snapshot a one-way export may use (`contacts2md export` on a
    /// vault this Mac synced before): unavailable accounts' cards put back as
    /// last seen, and contacts that would only be frozen left out, so the
    /// export never strips values or touches their notes. Nothing is stored.
    public static func protectExport(
        _ snapshot: AppleSnapshot, state: any SyncStateStore, records: RecordMap, decisions: DecisionSet, now: Date
    ) -> AppleSnapshot {
        let tracker = AppleChangeTracker(store: EmptyStore(), state: state, deviceID: "")
        let accounts = evaluate(
            AccountObservation(
                snapshot: snapshot, previous: load(from: state), records: records, mirror: { tracker.loadCache() },
                decisions: decisions, now: now, keyer: nil))
        guard accounts.isActive else { return snapshot }
        var augmented = accounts.augment(snapshot)
        augmented.snapshot.contacts.removeAll { augmented.frozenContacts.contains($0.unifiedID) }
        return augmented.snapshot
    }
}

/// A store that is never read (the tracker is only used for its mirror).
private struct EmptyStore: ContactStore {
    var capabilities: StoreCapabilities {
        StoreCapabilities(notesAvailable: false, iCloudContainerID: nil, writableContainerIDs: [])
    }

    func snapshot() throws -> AppleSnapshot {
        AppleSnapshot(contacts: [], containers: [], groups: [], notesAvailable: false)
    }

    func fetch(unifiedIDs: [String]) throws -> [AppleContact] { [] }

    func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        AppleWriteResult(applied: [])
    }

    func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult { .unsupported }

    func exportVCards() throws -> Data { Data() }
}
