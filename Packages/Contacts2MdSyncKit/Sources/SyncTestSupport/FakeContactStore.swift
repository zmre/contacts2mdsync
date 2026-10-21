public import ContactModel
public import Foundation
internal import Synchronization

/// An in-memory `ContactStore` that behaves like the real address book in the
/// ways that matter to the engine: unified contacts spanning iCloud / Google /
/// local cards, groups only in iCloud and local containers, images, name-only
/// relations, and a switchable notes entitlement (no entitlement → no notes,
/// `notesAvailable == false`, like the silently unavailable key on a real store).
///
/// Spike behaviours (S4/S9) on demand:
/// - `synthesizeLinkedIDs`: a contact with several cards gets a synthesized
///   unified id that is neither card's id and changes on every snapshot;
/// - `link(_:)`: Contacts auto-linking two contacts (cards keep their own
///   values; unified single-valued fields follow the last card, like
///   "most recently saved wins");
/// - `churnGoogleCardIDs()`: Google replacing new cards, so their ids change once.
///
/// Never touches Contacts.framework.
public final class FakeContactStore: ContactStore {
    private struct State {
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
    }

    private let state: Mutex<State>

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

    /// Linked contacts get a fresh synthesized unified id on every snapshot.
    public func setSynthesizeLinkedIDs(_ enabled: Bool) { state.withLock { $0.synthesizeLinkedIDs = enabled } }

    /// Links the contacts with these (stored) unified ids into one, as
    /// Contacts does on its own for same-name iCloud + Google cards. Each card
    /// keeps its own values; the unified view takes single-valued fields from
    /// the last contact and the union of multi-valued ones.
    public func link(_ unifiedIDs: [String]) {
        state.withLock { state in
            let members = unifiedIDs.compactMap { id in state.contacts.first { $0.unifiedID == id } }
            guard members.count > 1 else { return }
            state.contacts.removeAll { unifiedIDs.contains($0.unifiedID) }
            var cards: [AppleCard] = []
            for member in members {
                for var card in member.cards {
                    if card.values == nil { card.values = member.contact }
                    cards.append(card)
                }
            }
            var unified = members.last?.contact ?? members[0].contact
            for member in members.dropLast() {
                unified.emails += member.contact.emails.filter { !unified.emails.contains($0) }
                unified.phones += member.contact.phones.filter { !unified.phones.contains($0) }
            }
            state.contacts.append(
                AppleContact(
                    unifiedID: members[0].unifiedID, cards: cards, contact: unified,
                    imageData: members.compactMap(\.imageData).last,
                    groupIDs: Array(Set(members.flatMap(\.groupIDs))).sorted()))
        }
    }

    /// Changes every Google card id once (`x` → `x~google-sync`), like Google
    /// sync replacing a newly created card. Single-card contacts' unified ids
    /// change with them; stamps and values are kept.
    public func churnGoogleCardIDs() {
        state.withLock { state in
            for contactIndex in state.contacts.indices {
                var contact = state.contacts[contactIndex]
                for cardIndex in contact.cards.indices where contact.cards[cardIndex].accountKind == .google {
                    let old = contact.cards[cardIndex].id
                    guard !state.churned.contains(old) else { continue }
                    let new = old + "~google-sync"
                    state.churned.insert(new)
                    contact.cards[cardIndex].id = new
                    if contact.unifiedID == old { contact.unifiedID = new }
                }
                state.contacts[contactIndex] = contact
            }
        }
    }

    /// Simulates Contacts access being denied.
    public func denyAccess() { state.withLock { $0.accessGranted = false } }

    /// Batches applied so far, with their transaction authors.
    public var appliedBatches: [(batch: AppleWriteBatch, author: String)] { state.withLock { $0.batches } }

    /// Number of vCard exports (backups) taken.
    public var vCardExportCount: Int { state.withLock { $0.vCardExports } }

    /// Replaces the contacts (simulate edits made in Contacts.app).
    public func replaceContacts(_ contacts: [AppleContact]) { state.withLock { $0.contacts = contacts } }

    /// Current contacts (including stamps applied so far).
    public var contacts: [AppleContact] { state.withLock { $0.contacts } }

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
    }

    public func fetch(unifiedIDs: [String]) throws -> [AppleContact] {
        let wanted = Set(unifiedIDs)
        return try snapshot().contacts.filter { wanted.contains($0.unifiedID) }
    }

    public func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        try state.withLock { state in
            guard state.accessGranted else { throw ContactStoreError.accessDenied }
            var applied: [AppleWriteOperation] = []
            var failed: [AppleWriteFailure] = []
            for operation in batch.operations {
                switch operation {
                case .stamp(let cardID, let id):
                    guard
                        let contactIndex = state.contacts.firstIndex(where: { $0.cards.contains { $0.id == cardID } }),
                        let cardIndex = state.contacts[contactIndex].cards.firstIndex(where: { $0.id == cardID })
                    else {
                        failed.append(AppleWriteFailure(operation: operation, message: "card not found"))
                        continue
                    }
                    state.contacts[contactIndex].cards[cardIndex].stampID = id
                    applied.append(operation)
                }
            }
            state.batches.append((batch, author))
            return AppleWriteResult(applied: applied, failed: failed)
        }
    }

    public func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult { .unsupported }

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
}
