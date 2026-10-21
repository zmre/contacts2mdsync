public import Foundation

/// The engine's only view of Apple Contacts (architecture §2 seams).
///
/// Implemented by `ContactsAdapter.CNContactStoreAdapter` for real and by
/// `SyncTestSupport.FakeContactStore` in tests. All methods are synchronous
/// and may block; callers run them off the main actor.
public protocol ContactStore: Sendable {
    /// What this store can do (notes entitlement, writable containers, …).
    var capabilities: StoreCapabilities { get throws }

    /// Every unified contact with its underlying cards, plus containers and groups.
    func snapshot() throws -> AppleSnapshot

    /// Re-fetches specific unified contacts (missing ids are omitted).
    func fetch(unifiedIDs: [String]) throws -> [AppleContact]

    /// Applies a batch of writes as one save request tagged with `author`.
    func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult

    /// Change history since `token` (M5). Implementations may return
    /// `HistoryResult.unsupported` to force a full snapshot.
    func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult

    /// All contacts serialized as vCards (backup before any Apple write session).
    func exportVCards() throws -> Data
}

/// Feature flags discovered at runtime.
public struct StoreCapabilities: Hashable, Sendable {
    /// `CNContactNoteKey` readable (the notes entitlement is present).
    public var notesAvailable: Bool
    /// The iCloud container's identifier, when there is one.
    public var iCloudContainerID: String?
    /// Containers we may write to.
    public var writableContainerIDs: [String]

    /// Creates capabilities.
    public init(notesAvailable: Bool, iCloudContainerID: String?, writableContainerIDs: [String]) {
        self.notesAvailable = notesAvailable
        self.iCloudContainerID = iCloudContainerID
        self.writableContainerIDs = writableContainerIDs
    }
}

/// What kind of account a container belongs to.
public enum AccountKind: String, Hashable, Sendable, Codable {
    case iCloud = "icloud"
    case google
    case exchange
    case local
    case cardDAV = "carddav"
    case unknown

    /// Groups exist only in iCloud and On-My-Mac containers.
    public var supportsGroups: Bool { self == .iCloud || self == .local }

    /// Short human-readable name for output (`iCloud`, `Google`, …).
    public var displayName: String {
        switch self {
        case .iCloud: "iCloud"
        case .google: "Google"
        case .exchange: "Exchange"
        case .local: "On My Mac"
        case .cardDAV: "CardDAV"
        case .unknown: "Unknown"
        }
    }
}

/// One Contacts account container.
public struct AppleContainer: Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: AccountKind
    /// The user's default container (where new contacts land).
    public var isDefault: Bool

    /// Creates a container.
    public init(id: String, name: String, kind: AccountKind, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
    }
}

/// One Contacts group (only iCloud / local containers have them).
public struct AppleGroup: Hashable, Sendable {
    public var id: String
    public var name: String
    public var containerID: String

    /// Creates a group.
    public init(id: String, name: String, containerID: String) {
        self.id = id
        self.name = name
        self.containerID = containerID
    }
}

/// One underlying card of a unified contact (`unifyResults = false`).
public struct AppleCard: Hashable, Sendable {
    public var id: String
    public var containerID: String
    public var accountKind: AccountKind
    /// `x-c2mdsync:<uuid>` stamp found on this card, if any.
    public var stampID: UUID?

    /// Creates a card.
    public init(id: String, containerID: String, accountKind: AccountKind, stampID: UUID? = nil) {
        self.id = id
        self.containerID = containerID
        self.accountKind = accountKind
        self.stampID = stampID
    }
}

/// One unified Apple contact as the engine sees it.
public struct AppleContact: Hashable, Sendable {
    /// Unified contact identifier (one of its cards' ids; may churn).
    public var unifiedID: String
    /// Underlying cards; at least one.
    public var cards: [AppleCard]
    /// The unified values mapped to the canonical model. `title` is empty and
    /// `sync`/`tags` are unset: those are markdown/engine-owned. Relationship
    /// targets are `.name` (Apple stores names only). The stamp URL is
    /// already filtered out of `urls`.
    public var contact: CanonicalContact
    /// Original image bytes (`imageData`), if any.
    public var imageData: Data?
    /// Groups any underlying card belongs to.
    public var groupIDs: [String]

    /// Creates a contact.
    public init(
        unifiedID: String,
        cards: [AppleCard],
        contact: CanonicalContact,
        imageData: Data? = nil,
        groupIDs: [String] = []
    ) {
        self.unifiedID = unifiedID
        self.cards = cards
        self.contact = contact
        self.imageData = imageData
        self.groupIDs = groupIDs
    }

    /// Distinct stamp ids across cards, in card order.
    public var stampIDs: [UUID] {
        var seen = Set<UUID>()
        return cards.compactMap(\.stampID).filter { seen.insert($0).inserted }
    }

    /// The card that carries our stamp: the iCloud card, else the first
    /// iCloud/local/CardDAV card, else the first card.
    public var stampTargetCard: AppleCard? {
        cards.first { $0.accountKind == .iCloud }
            ?? cards.first { [.local, .cardDAV, .google].contains($0.accountKind) }
            ?? cards.first
    }

    /// `true` when any card lives in iCloud.
    public var isICloudBacked: Bool { cards.contains { $0.accountKind == .iCloud } }
}

/// A full snapshot of the Contacts database.
public struct AppleSnapshot: Hashable, Sendable {
    public var contacts: [AppleContact]
    public var containers: [AppleContainer]
    public var groups: [AppleGroup]
    public var notesAvailable: Bool

    /// Creates a snapshot.
    public init(contacts: [AppleContact], containers: [AppleContainer], groups: [AppleGroup], notesAvailable: Bool) {
        self.contacts = contacts
        self.containers = containers
        self.groups = groups
        self.notesAvailable = notesAvailable
    }
}

/// The URL stamp that ties an Apple card to a markdown record.
public enum SyncStamp {
    /// Label of the stamp URL.
    public static let label = "c2mdsync"
    /// Scheme prefix of the stamp URL value.
    public static let prefix = "x-c2mdsync:"

    /// `x-c2mdsync:<uuid>` for `id`.
    public static func url(for id: UUID) -> String { prefix + id.uuidString.lowercased() }

    /// The id in a stamp URL value, or `nil` when `value` is not a stamp.
    public static func id(fromURL value: String) -> UUID? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(trimmed.dropFirst(prefix.count)))
    }

    /// `true` for any value using our scheme (even with a malformed uuid);
    /// such values are never exported to markdown.
    public static func isStamp(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix)
    }
}

/// One Apple-side write. M1 implements only `.stamp`.
public enum AppleWriteOperation: Hashable, Sendable {
    /// Add `x-c2mdsync:<id>` (label `c2mdsync`) to `cardID`, replacing any other stamp.
    case stamp(cardID: String, id: UUID)
}

/// A batch of Apple writes saved together.
public struct AppleWriteBatch: Hashable, Sendable {
    public var operations: [AppleWriteOperation]

    /// Creates a batch.
    public init(operations: [AppleWriteOperation]) { self.operations = operations }
}

/// Outcome of `ContactStore.apply`.
public struct AppleWriteResult: Hashable, Sendable {
    /// Operations that were saved.
    public var applied: [AppleWriteOperation]
    /// Operations that failed, with a message each.
    public var failed: [AppleWriteFailure]

    /// Creates a result.
    public init(applied: [AppleWriteOperation], failed: [AppleWriteFailure] = []) {
        self.applied = applied
        self.failed = failed
    }
}

/// One failed Apple write.
public struct AppleWriteFailure: Hashable, Sendable {
    public var operation: AppleWriteOperation
    public var message: String

    /// Creates a failure.
    public init(operation: AppleWriteOperation, message: String) {
        self.operation = operation
        self.message = message
    }
}

/// Change-history result (M5).
public enum HistoryResult: Hashable, Sendable {
    /// History is not available; take a full snapshot.
    case unsupported
    /// Ids changed since the token, ids deleted, and the new token.
    case changes(changedUnifiedIDs: [String], deletedIDs: [String], token: Data?)
}

/// Errors any `ContactStore` may throw.
public enum ContactStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Contacts access has not been granted. The CLI never prompts.
    case accessDenied
    /// The operation is not implemented yet (milestone noted).
    case notImplemented(String)
    /// A card id did not resolve.
    case cardNotFound(String)

    public var description: String {
        switch self {
        case .accessDenied: "Contacts access has not been granted; open Contacts2MdSync once to allow it"
        case .notImplemented(let what): "not implemented yet: \(what)"
        case .cardNotFound(let id): "contact card not found: \(id)"
        }
    }
}
