public import ContactModel
public import Foundation
internal import Synchronization

/// An in-memory `ContactStore` that behaves like the real address book in the
/// ways that matter to the engine: unified contacts spanning iCloud / Google /
/// local cards, groups only in iCloud and local containers, images, name-only
/// relations, and a switchable notes entitlement (no entitlement → no notes,
/// `notesAvailable == false`, like the silently unavailable key on a real store).
///
/// Spike behaviours (S4/S5/S9) on demand:
/// - `synthesizeLinkedIDs`: a contact with several cards gets a synthesized
///   unified id that is neither card's id and changes on every snapshot;
/// - `link(_:)`: Contacts auto-linking two contacts (cards keep their own
///   values; unified single-valued fields follow the most recently saved card);
/// - `churnGoogleCardIDs()`: Google replacing new cards, so their ids change once;
/// - `normalizePhonesOnSave`: server-normalization echo (`4155550100` →
///   `(415) 555-0100`) on every phone we write;
/// - `dropWrites(_:field:)`: a container that silently ignores writes to a
///   field (the card keeps its old value; the engine must mark it unapplyable);
/// - unified-save fan-out: an operation addressed to a linked contact's
///   unified id (never a card id) writes to **every** linked card, as saving a
///   unified mutable copy does; `unifiedSaveCount` counts such misuse.
///
/// Writes go to card values; the unified view is recomputed from the cards
/// (multi-valued fields: union; single-valued: the most recently saved card
/// first). Contacts that were never written keep the unified view they were
/// created with. Never touches Contacts.framework.
public final class FakeContactStore: ContactStore {
    struct State {
        var contacts: [AppleContact]
        var containers: [AppleContainer]
        var groups: [AppleGroup]
        var notesEntitled: Bool
        var batches: [(batch: AppleWriteBatch, author: String)] = []
        var accessGranted = true
        var vCardExports = 0
        var synthesizeLinkedIDs = false
        var snapshots = 0
        var churned = Set<String>()
        var normalizePhones = false
        var dropped = Set<String>()
        var saveSequence = 0
        /// Card id → save sequence (most recent save wins single-valued display).
        var lastSaved: [String: Int] = [:]
        var unifiedSaves = 0
        var created = 0
        var failNextApply = false
        /// Change history (M5): events with their transaction author (`nil`:
        /// the user, Contacts.app or account sync).
        var history: [(author: String?, event: FakeHistoryEvent)] = []
        /// Bumped by `resetHistory()`: older tokens get `DropEverything`.
        var historyEpoch = 0
        var historySupported = true
        var failNextHistory = false
        var historyReads = 0
        var refetches: [[String]] = []
    }

    let state: Mutex<State>

    /// Creates a store.
    public init(
        contacts: [AppleContact],
        containers: [AppleContainer] = Fixtures.containers,
        groups: [AppleGroup] = [],
        notesEntitled: Bool = true
    ) {
        state = Mutex(
            State(contacts: contacts, containers: containers, groups: groups, notesEntitled: notesEntitled))
    }

    // MARK: - Behaviour switches

    /// Linked contacts get a fresh synthesized unified id on every snapshot.
    public func setSynthesizeLinkedIDs(_ enabled: Bool) { state.withLock { $0.synthesizeLinkedIDs = enabled } }

    /// Phones we write come back reformatted (server-normalization echo).
    public func setNormalizePhonesOnSave(_ enabled: Bool) { state.withLock { $0.normalizePhones = enabled } }

    /// Writes to `field` (an `AppleScalarField` or `AppleListField` raw value,
    /// or `note`/`image`/`groups`) on cards of `kind` are silently ignored.
    public func dropWrites(_ kind: AccountKind, field: String) {
        state.withLock { _ = $0.dropped.insert("\(kind.rawValue):\(field)") }
    }

    /// The next `apply` throws (a failed save request).
    public func failNextApply() { state.withLock { $0.failNextApply = true } }

    /// Simulates Contacts access being denied.
    public func denyAccess() { state.withLock { $0.accessGranted = false } }

    // MARK: - ContactStore

    public var capabilities: StoreCapabilities {
        get throws {
            try state.withLock { state in
                guard state.accessGranted else { throw ContactStoreError.accessDenied }
                return StoreCapabilities(
                    notesAvailable: state.notesEntitled,
                    iCloudContainerID: state.containers.first { $0.kind == .iCloud }?.id,
                    writableContainerIDs: state.containers.map(\.id)
                )
            }
        }
    }

    public func snapshot() throws -> AppleSnapshot {
        try state.withLock { state in
            guard state.accessGranted else { throw ContactStoreError.accessDenied }
            state.snapshots += 1
            return Self.view(of: state)
        }
    }

    /// The store as a snapshot would show it (notes stripped without the
    /// entitlement, synthesized linked ids).
    static func view(of state: State) -> AppleSnapshot {
        let generation = state.snapshots
        let contacts = state.contacts.enumerated().map { offset, contact in
            var copy = contact
            if !state.notesEntitled {
                copy.contact.body = nil
                for index in copy.cards.indices { copy.cards[index].values?.body = nil }
            }
            if state.synthesizeLinkedIDs, copy.cards.count > 1 {
                copy.unifiedID = "SYNTH-\(generation)-\(offset)"
            }
            return copy
        }
        return AppleSnapshot(
            contacts: contacts, containers: state.containers, groups: state.groups,
            notesAvailable: state.notesEntitled)
    }

    public func fetch(unifiedIDs: [String]) throws -> [AppleContact] {
        let wanted = Set(unifiedIDs)
        return try snapshot().contacts.filter { wanted.contains($0.unifiedID) }
    }

    public func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        try state.withLock { state in
            guard state.accessGranted else { throw ContactStoreError.accessDenied }
            if state.failNextApply {
                state.failNextApply = false
                throw ContactStoreError.notImplemented("simulated save failure")
            }
            var result = AppleWriteResult(applied: [])
            for operation in batch.operations {
                do {
                    let created = result.createdCardIDs
                    try Self.apply(operation, to: &state, result: &result)
                    result.applied.append(operation)
                    for event in Self.events(for: operation, createdBefore: created, after: result.createdCardIDs) {
                        state.history.append((author, event))
                    }
                } catch {
                    result.failed.append(AppleWriteFailure(operation: operation, message: String(describing: error)))
                }
            }
            state.batches.append((batch, author))
            return result
        }
    }

    public func exportVCards() throws -> Data {
        try state.withLock { state in
            guard state.accessGranted else { throw ContactStoreError.accessDenied }
            state.vCardExports += 1
            let cards = state.contacts.map { contact in
                "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:\(TitleGenerator.title(for: contact.contact))\r\nEND:VCARD\r\n"
            }
            return Data(cards.joined().utf8)
        }
    }

    // MARK: - Writes

    struct FakeError: Error, CustomStringConvertible {
        let description: String
    }

    private static func apply(
        _ operation: AppleWriteOperation, to state: inout State, result: inout AppleWriteResult
    ) throws {
        if case .create(let new) = operation {
            try create(new, in: &state, result: &result)
            return
        }
        guard let cardID = operation.cardID else { return }
        for (index, ids) in try targets(cardID, in: &state) {
            FakeCardValues.materialize(&state.contacts[index])
            for id in ids { try apply(operation, card: id, contact: index, state: &state) }
            FakeCardValues.recomputeUnified(&state.contacts[index], lastSaved: state.lastSaved)
            if state.contacts[index].cards.isEmpty { state.contacts.remove(at: index) }
        }
    }

    /// The contact index and card ids an operation addressed to `id` reaches.
    /// A linked contact's unified id fans out to every card (misuse, counted).
    private static func targets(_ id: String, in state: inout State) throws -> [(Int, [String])] {
        if let index = state.contacts.firstIndex(where: { $0.cards.contains { $0.id == id } }) {
            return [(index, [id])]
        }
        var index = state.contacts.firstIndex { $0.unifiedID == id && $0.cards.count > 1 }
        if index == nil, id.hasPrefix("SYNTH-"), let offset = id.split(separator: "-").last.flatMap({ Int($0) }),
            state.contacts.indices.contains(offset)
        {
            index = offset
        }
        guard let index else { throw ContactStoreError.cardNotFound(id) }
        state.unifiedSaves += 1
        return [(index, state.contacts[index].cards.map(\.id))]
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func apply(
        _ operation: AppleWriteOperation, card cardID: String, contact index: Int, state: inout State
    ) throws {
        guard let cardIndex = state.contacts[index].cards.firstIndex(where: { $0.id == cardID }) else {
            throw ContactStoreError.cardNotFound(cardID)
        }
        let card = state.contacts[index].cards[cardIndex]
        switch operation {
        case .stamp(_, let id):
            state.contacts[index].cards[cardIndex].stampID = id
        case .removeStamp:
            state.contacts[index].cards[cardIndex].stampID = nil
        case .update(_, let edits):
            var values = card.values ?? state.contacts[index].contact
            var image = state.contacts[index].imageData
            for edit in edits where !isDropped(edit, kind: card.accountKind, state: state) {
                guard state.notesEntitled || !isNote(edit) else { throw FakeError(description: "notes unavailable") }
                FakeCardValues.apply(edit, to: &values, image: &image, normalizePhones: state.normalizePhones)
            }
            state.contacts[index].cards[cardIndex].values = values
            if image != state.contacts[index].imageData {
                state.contacts[index].imageData = image
                state.contacts[index].imageUnavailable = false
            }
        case .delete:
            state.contacts[index].cards.remove(at: cardIndex)
            return
        case .addMember(_, let groupID):
            guard let group = state.groups.first(where: { $0.id == groupID }) else {
                throw FakeError(description: "group not found")
            }
            guard group.containerID == card.containerID else {
                throw FakeError(description: "card and group are in different containers")
            }
            if !state.contacts[index].groupIDs.contains(groupID) { state.contacts[index].groupIDs.append(groupID) }
        case .removeMember(_, let groupID):
            state.contacts[index].groupIDs.removeAll { $0 == groupID }
        case .create:
            return
        }
        state.saveSequence += 1
        state.lastSaved[cardID] = state.saveSequence
    }

    private static func create(_ new: NewAppleContact, in state: inout State, result: inout AppleWriteResult) throws {
        guard let container = state.containers.first(where: { $0.id == new.containerID }) else {
            throw FakeError(description: "container not found")
        }
        state.created += 1
        let cardID = "new-\(state.created):\(container.kind.rawValue)"
        var values = CanonicalContact(kind: new.kind, title: "")
        var image: Data?
        for edit in new.edits {
            FakeCardValues.apply(edit, to: &values, image: &image, normalizePhones: state.normalizePhones)
        }
        if !state.notesEntitled { values.body = nil }
        let card = AppleCard(
            id: cardID, containerID: container.id, accountKind: container.kind, stampID: new.stamp, values: values)
        state.contacts.append(
            AppleContact(unifiedID: cardID, cards: [card], contact: values, imageData: image, groupIDs: new.groupIDs))
        state.saveSequence += 1
        state.lastSaved[cardID] = state.saveSequence
        result.createdCardIDs[new.recordID] = cardID
    }

    /// History events a saved operation produces.
    private static func events(
        for operation: AppleWriteOperation, createdBefore: [UUID: String], after: [UUID: String]
    ) -> [FakeHistoryEvent] {
        switch operation {
        case .create(let new):
            return createdBefore[new.recordID] == nil ? after[new.recordID].map { [.changed($0)] } ?? [] : []
        case .delete(let id): return [.deleted(id)]
        default: return operation.cardID.map { [.changed($0)] } ?? []
        }
    }

    private static func isNote(_ edit: CardEdit) -> Bool {
        if case .note = edit { return true }
        return false
    }

    private static func isDropped(_ edit: CardEdit, kind: AccountKind, state: State) -> Bool {
        let field: String =
            switch edit {
            case .scalar(let field, _): field.rawValue
            case .birthday: "birthday"
            case .list(let field, _): field.rawValue
            case .note: "note"
            case .image: "image"
            }
        return state.dropped.contains("\(kind.rawValue):\(field)")
    }
}

/// One change-history event of the fake store.
enum FakeHistoryEvent: Hashable, Sendable {
    case changed(String)
    case deleted(String)
    case group
}
