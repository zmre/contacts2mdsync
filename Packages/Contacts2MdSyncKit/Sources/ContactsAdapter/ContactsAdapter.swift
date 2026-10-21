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

    public func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        try Self.ensureAccess()
        let store = CNContactStore()
        let request = CNSaveRequest()
        request.transactionAuthor = author
        var staged: [AppleWriteOperation] = []
        var failed: [AppleWriteFailure] = []
        for operation in batch.operations {
            switch operation {
            case .stamp(let cardID, let id):
                do {
                    let card = try Self.card(cardID, in: store)
                    let mutable = card.mutableCopy() as! CNMutableContact  // swiftlint:disable:this force_cast
                    var urls = mutable.urlAddresses.filter { !SyncStamp.isStamp($0.value as String) }
                    urls.append(CNLabeledValue(label: SyncStamp.label, value: SyncStamp.url(for: id) as NSString))
                    mutable.urlAddresses = urls
                    request.update(mutable)
                    staged.append(operation)
                } catch {
                    failed.append(AppleWriteFailure(operation: operation, message: String(describing: error)))
                }
            }
        }
        guard !staged.isEmpty else { return AppleWriteResult(applied: [], failed: failed) }
        do {
            try store.execute(request)
        } catch {
            let message = String(describing: error)
            return AppleWriteResult(
                applied: [], failed: failed + staged.map { AppleWriteFailure(operation: $0, message: message) })
        }
        return AppleWriteResult(applied: staged, failed: failed)
    }

    public func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult {
        .unsupported  // M5: change-history acceleration via ContactsShim.
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
/// `ContactStore` seam (change history, used from M5).
public enum ContactsAdapter {
    /// The `ContactModel` schema version this adapter maps to.
    public static let schemaVersion = ContactModel.schemaVersion
}
