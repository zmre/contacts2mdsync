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

    /// Change history since `token` (M5): which cards changed, excluding
    /// saves tagged with any of `authors` (our own writes). Implementations
    /// may return `.unsupported` or `.reset` to force a full snapshot.
    func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult

    /// The store's current change-history token (`nil`: history unsupported).
    /// Read it *before* a snapshot, so changes made while the snapshot is
    /// read are reported again next time (harmless) rather than lost.
    func currentHistoryToken() throws -> Data?

    /// Re-reads the unified contacts that contain any of `cardIDs`, each with
    /// all of its cards, plus every container and group. `siblingHints` are
    /// card ids the caller believes are linked to them (from its cache), so
    /// the store can find every card of a linked contact.
    func refetch(cardIDs: [String], siblingHints: [String]) throws -> AppleRefetch

    /// All contacts serialized as vCards (backup before any Apple write session).
    func exportVCards() throws -> Data
}

/// Feature flags discovered at runtime.
public struct StoreCapabilities: Hashable, Sendable {
    /// Notes readable: `CNContactNoteKey` (the notes entitlement), or the
    /// Contacts.app scripting bridge (`NotesBridgedStore`, architecture §8).
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
public struct AppleContainer: Hashable, Sendable, Codable {
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
public struct AppleGroup: Hashable, Sendable, Codable {
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
public struct AppleCard: Hashable, Sendable, Codable {
    public var id: String
    public var containerID: String
    public var accountKind: AccountKind
    /// `x-c2mdsync:<uuid>` stamp found on this card, if any.
    public var stampID: UUID?
    /// This card's own field values (no image), when the store read them.
    /// `nil` means "unknown": the engine then uses the unified view
    /// (`AppleContact.contact`). See `AppleContact.cardMergedContact`.
    public var values: CanonicalContact?

    /// Creates a card.
    public init(
        id: String, containerID: String, accountKind: AccountKind, stampID: UUID? = nil,
        values: CanonicalContact? = nil
    ) {
        self.id = id
        self.containerID = containerID
        self.accountKind = accountKind
        self.stampID = stampID
        self.values = values
    }
}

/// One unified Apple contact as the engine sees it.
public struct AppleContact: Hashable, Sendable, Codable {
    /// Unified contact identifier. For a single card it is the card's id; for
    /// linked cards Contacts synthesizes an id that is neither card's and is
    /// volatile (spike S4/S9). Never use it as identity: cache only.
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
    /// `true` when Contacts has a thumbnail but no original image data (seen
    /// after an iCloud round trip, spike S5). The image is then *unknown*:
    /// never treated as removed, never replaced by the thumbnail.
    public var imageUnavailable: Bool
    /// Groups any underlying card belongs to.
    public var groupIDs: [String]
    /// `true` when some card's note could not be read (scripting did not see
    /// the card): the body is *unknown*, never empty (§8). Optional so cached
    /// snapshots from before it decode. `nil`: known, or notes not read.
    public var notesUnknown: Bool?  // swiftlint:disable:this discouraged_optional_boolean

    /// Creates a contact.
    public init(
        unifiedID: String,
        cards: [AppleCard],
        contact: CanonicalContact,
        imageData: Data? = nil,
        imageUnavailable: Bool = false,
        groupIDs: [String] = []
    ) {
        self.unifiedID = unifiedID
        self.cards = cards
        self.contact = contact
        self.imageData = imageData
        self.imageUnavailable = imageUnavailable
        self.groupIDs = groupIDs
    }

    /// Underlying card ids, in card order.
    public var cardIDs: [String] { cards.map(\.id) }

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
public struct AppleSnapshot: Hashable, Sendable, Codable {
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

/// One Apple-side write. Every write targets an underlying card fetched
/// with `unifyResults = false`, never a unified contact: saving a unified
/// mutable copy writes to every linked card (spike S4).
public enum AppleWriteOperation: Hashable, Sendable {
    /// Add `x-c2mdsync:<id>` (label `c2mdsync`) to `cardID`, replacing any other stamp.
    case stamp(cardID: String, id: UUID)
    /// Remove every `x-c2mdsync:` stamp from `cardID` (unlink).
    case removeStamp(cardID: String)
    /// Field edits on one card (all edits for a card in one operation).
    case update(cardID: String, edits: [CardEdit])
    /// Create a contact (a single card) in a container.
    case create(NewAppleContact)
    /// Delete one card (confirmed deletes only).
    case delete(cardID: String)
    /// Add a card to a group (same container).
    case addMember(cardID: String, groupID: String)
    /// Remove a card from a group (no-op when it is not a member).
    case removeMember(cardID: String, groupID: String)

    /// The card the operation targets (`nil` for creates).
    public var cardID: String? {
        switch self {
        case .stamp(let id, _), .removeStamp(let id), .update(let id, _), .delete(let id), .addMember(let id, _),
            .removeMember(let id, _):
            id
        case .create: nil
        }
    }
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
    /// Card ids of created contacts, by `NewAppleContact.recordID`.
    public var createdCardIDs: [UUID: String]

    /// Creates a result.
    public init(
        applied: [AppleWriteOperation], failed: [AppleWriteFailure] = [], createdCardIDs: [UUID: String] = [:]
    ) {
        self.applied = applied
        self.failed = failed
        self.createdCardIDs = createdCardIDs
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

/// Change-history result (M5, architecture §10).
public enum HistoryResult: Hashable, Sendable {
    /// History is not available; take a full snapshot.
    case unsupported
    /// The token is unusable (a `DropEverything` event, error 603/604, or no
    /// starting token): take a full snapshot. `token` is the store's new token.
    case reset(token: Data?)
    /// What changed since the token.
    case changes(HistoryChanges)
}

/// Contact changes reported by the change history since a token.
public struct HistoryChanges: Hashable, Sendable {
    /// Cards added or updated, including cards added to or removed from a group.
    public var changedCardIDs: [String]
    /// Cards deleted.
    public var deletedCardIDs: [String]
    /// A group was added, renamed or deleted (membership changes are in
    /// `changedCardIDs`).
    public var groupsChanged: Bool
    /// Number of events read (after author exclusion).
    public var eventCount: Int
    /// Token to persist and pass as `since` next time.
    public var token: Data?

    /// Creates changes.
    public init(
        changedCardIDs: [String] = [], deletedCardIDs: [String] = [], groupsChanged: Bool = false,
        eventCount: Int = 0, token: Data?
    ) {
        self.changedCardIDs = changedCardIDs
        self.deletedCardIDs = deletedCardIDs
        self.groupsChanged = groupsChanged
        self.eventCount = eventCount
        self.token = token
    }

    /// `true` when nothing changed.
    public var isEmpty: Bool { changedCardIDs.isEmpty && deletedCardIDs.isEmpty && !groupsChanged }
}

/// A partial re-read of Apple Contacts (`ContactStore.refetch`).
public struct AppleRefetch: Hashable, Sendable {
    /// Unified contacts containing any requested card, each with all its cards.
    public var contacts: [AppleContact]
    /// Every container.
    public var containers: [AppleContainer]
    /// Every group (iCloud / local containers).
    public var groups: [AppleGroup]
    public var notesAvailable: Bool

    /// Creates a refetch result.
    public init(
        contacts: [AppleContact], containers: [AppleContainer], groups: [AppleGroup], notesAvailable: Bool
    ) {
        self.contacts = contacts
        self.containers = containers
        self.groups = groups
        self.notesAvailable = notesAvailable
    }
}

extension ContactStore {
    /// Default: no change history (always a full snapshot).
    public func currentHistoryToken() throws -> Data? { nil }

    /// Default: filters a full snapshot (correct, not faster).
    public func refetch(cardIDs: [String], siblingHints: [String]) throws -> AppleRefetch {
        let snapshot = try snapshot()
        let wanted = Set(cardIDs)
        return AppleRefetch(
            contacts: snapshot.contacts.filter { $0.cards.contains { wanted.contains($0.id) } },
            containers: snapshot.containers, groups: snapshot.groups, notesAvailable: snapshot.notesAvailable)
    }
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
