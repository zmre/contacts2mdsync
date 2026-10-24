public import ContactModel
internal import Contacts
internal import ContactsShim
public import Foundation

/// Bridges Apple's Contacts framework (`CNContactStore`) to `ContactModel`
/// values: snapshots, the notes-entitlement probe, the identity stamp, and
/// vCard backups.
///
/// A fresh `CNContactStore` is created per operation, so the adapter holds no
/// framework state and is trivially `Sendable`. It never requests access:
/// without authorization every call throws `ContactStoreError.accessDenied`.
public struct CNContactStoreAdapter: ContactStore {
    /// Creates an adapter.
    public init() {}

    /// `true` when Contacts access is granted. Reading the status never prompts.
    public static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    public var capabilities: StoreCapabilities {
        get throws {
            try Self.ensureAccess()
            let store = CNContactStore()
            let containers = try Self.containers(in: store)
            return StoreCapabilities(
                notesAvailable: Self.notesAvailable(in: store),
                iCloudContainerID: containers.first { $0.kind == .iCloud }?.id,
                writableContainerIDs: containers.filter { $0.kind != .unknown }.map(\.id)
            )
        }
    }

    public func snapshot() throws -> AppleSnapshot {
        try Self.ensureAccess()
        return try SnapshotReader(store: CNContactStore()).read()
    }

    public func fetch(unifiedIDs: [String]) throws -> [AppleContact] {
        let wanted = Set(unifiedIDs)
        return try snapshot().contacts.filter { wanted.contains($0.unifiedID) }
    }

    /// Saves `batch` card by card (never a unified contact, architecture §6)
    /// in one `CNSaveRequest` tagged with `author`. If that request fails,
    /// each card's operations (and each create) are retried in their own
    /// request, so one rejected card does not sink the rest.
    public func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        try Self.ensureAccess()
        let store = CNContactStore()
        let writer = CardWriter(store: store, includeNote: Self.notesAvailable(in: store))
        guard !batch.operations.isEmpty else { return AppleWriteResult(applied: []) }
        do {
            let saved = try writer.save(batch.operations, author: author)
            return AppleWriteResult(applied: batch.operations, createdCardIDs: saved.created)
        } catch {
            guard Self.units(of: batch.operations).count > 1 else {
                return AppleWriteResult(applied: [], failed: batch.operations.map { Self.failure($0, error) })
            }
        }
        var result = AppleWriteResult(applied: [])
        for unit in Self.units(of: batch.operations) {
            do {
                let saved = try writer.save(unit, author: author)
                result.applied += unit
                result.createdCardIDs.merge(saved.created) { _, new in new }
            } catch {
                result.failed += unit.map { Self.failure($0, error) }
            }
        }
        return result
    }

    /// `NSCocoaErrorDomain` 134092 ("… occurred during faulting"): without the
    /// notes entitlement, every save that updates a card with a note fails
    /// this way and changes nothing (spike S15).
    static func isNotedCardRejection(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == 134_092
    }

    static func failure(_ operation: AppleWriteOperation, _ error: any Error) -> AppleWriteFailure {
        let rejected = isNotedCardRejection(error)
        let message =
            rejected
            ? "\(operation.summary): Contacts refused the save because the card has a note "
                + "(NSCocoaErrorDomain 134092; needs the notes entitlement or Contacts.app scripting)"
            : String(describing: error)
        return AppleWriteFailure(operation: operation, message: message, rejectedForNote: rejected)
    }

    /// Operations grouped by target card (in first-seen order); each create alone.
    static func units(of operations: [AppleWriteOperation]) -> [[AppleWriteOperation]] {
        var order: [String] = []
        var byCard: [String: [AppleWriteOperation]] = [:]
        var creates: [[AppleWriteOperation]] = []
        for operation in operations {
            guard let cardID = operation.cardID else {
                creates.append([operation])
                continue
            }
            if byCard[cardID] == nil { order.append(cardID) }
            byCard[cardID, default: []].append(operation)
        }
        return order.compactMap { byCard[$0] } + creates
    }

    /// Change history since `token`, card-level (`shouldUnifyResults = NO`),
    /// without the saves of `authors`. A `DropEverything` event, a `nil`
    /// token, or error 603/604 → `.reset` (architecture §10).
    public func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult {
        try Self.ensureAccess()
        let store = CNContactStore()
        do {
            let batch = try ContactsAdapter.changeHistory(
                in: store, keysToFetch: [CNContactIdentifierKey as NSString], since: token, unify: false,
                excludingAuthors: authors)
            return ContactsAdapter.summarize(
                batch.events.compactMap(ContactsAdapter.classify), since: token, newToken: batch.currentToken)
        } catch let error where ContactsAdapter.isTokenError(error) {
            return .reset(token: store.currentHistoryToken)
        }
    }

    public func currentHistoryToken() throws -> Data? {
        try Self.ensureAccess()
        return CNContactStore().currentHistoryToken
    }

    public func refetch(cardIDs: [String], siblingHints: [String]) throws -> AppleRefetch {
        try Self.ensureAccess()
        return try SnapshotReader(store: CNContactStore()).refetch(cardIDs: cardIDs, siblingHints: siblingHints)
    }

    public func exportVCards() throws -> Data {
        try Self.ensureAccess()
        let store = CNContactStore()
        var keys: [any CNKeyDescriptor] = [CNContactVCardSerialization.descriptorForRequiredKeys()]
        if Self.notesAvailable(in: store) { keys.append(CNContactNoteKey as NSString) }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = false  // back up every underlying card as stored
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in contacts.append(contact) }
        var error: NSError?
        guard let data = C2MVCardData(contacts, &error) else {
            throw error ?? ContactStoreError.notImplemented("vCard serialization returned no data")
        }
        return data
    }

    // MARK: - Helpers

    static func ensureAccess() throws {
        guard isAuthorized else { throw ContactStoreError.accessDenied }
    }

    /// Probes the notes entitlement. Error 102 (or any failure) → `false`; never crashes.
    static func notesAvailable(in store: CNContactStore) -> Bool {
        do {
            try store.c2m_probeNoteAccess()
            return true
        } catch {
            return false
        }
    }

    static func card(_ id: String, in store: CNContactStore) throws -> CNContact {
        let request = CNContactFetchRequest(
            keysToFetch: [CNContactIdentifierKey, CNContactUrlAddressesKey] as [NSString])
        request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        request.unifyResults = false
        var found: CNContact?
        try store.enumerateContacts(with: request) { contact, stop in
            if contact.identifier == id {
                found = contact
                stop.pointee = true
            }
        }
        guard let found else { throw ContactStoreError.cardNotFound(id) }
        return found
    }

    static func containers(in store: CNContactStore) throws -> [AppleContainer] {
        let defaultID = store.defaultContainerIdentifier()
        return try store.containers(matching: nil).map { container in
            AppleContainer(
                id: container.identifier,
                name: container.name,
                kind: accountKind(type: container.type, name: container.name),
                isDefault: container.identifier == defaultID
            )
        }
    }

    /// Classifies a container. CardDAV covers both iCloud and Google, so the
    /// name decides (heuristic; iCloud's container is named "iCloud").
    static func accountKind(type: CNContainerType, name: String) -> AccountKind {
        switch type {
        case .local: return .local
        case .exchange: return .exchange
        case .cardDAV:
            let lower = name.lowercased()
            if lower.contains("icloud") { return .iCloud }
            if lower.contains("google") || lower.contains("gmail") { return .google }
            return .cardDAV
        case .unassigned: return .unknown
        @unknown default: return .unknown
        }
    }
}

/// Namespace for Contacts.framework helpers that are not part of the
/// `ContactStore` seam (change-history plumbing).
public enum ContactsAdapter {
    /// The `ContactModel` schema version this adapter maps to.
    public static let schemaVersion = ContactModel.schemaVersion
}
