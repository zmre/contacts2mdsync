public import ContactModel
public import Foundation
internal import Synchronization

/// An in-memory `ContactStore` that behaves like the real address book in the
/// ways that matter to the engine: unified contacts spanning iCloud / Google /
/// local cards, groups only in iCloud and local containers, images, name-only
/// relations, and a switchable notes entitlement (no entitlement → no notes,
/// `notesAvailable == false`, exactly like error 102 on a real store).
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
            let contacts = state.contacts.map { contact in
                var copy = contact
                if !state.notesEntitled { copy.contact.body = nil }
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
