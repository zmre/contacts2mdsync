public import ContactModel
public import Foundation

/// A Contacts container (account) this device has seen, with how many cards
/// it held the last time it was available (architecture §9 "Unavailable
/// accounts").
public struct TrackedContainer: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: AccountKind
    /// Cards in the container the last time it was available.
    public var cardCount: Int
    public var firstSeen: Date
    public var lastSeen: Date

    /// Creates a tracked container.
    public init(id: String, name: String, kind: AccountKind, cardCount: Int, firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.cardCount = cardCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case cardCount = "card_count"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }
}

/// One card of an unavailable account, as last seen (from the Contacts mirror).
public struct FrozenCard: Codable, Hashable, Sendable {
    /// The card as last seen; `values == nil` when they were never read
    /// (no mirror): the record is then frozen whole.
    public var card: AppleCard
    /// The record the card was bound to, when any.
    public var recordID: UUID?
    /// The other cards of the unified contact it belonged to.
    public var siblingIDs: [String]
    /// Groups of that contact in the card's own container.
    public var groupIDs: [String]
    /// The unified view it belonged to (a ghost contact's display values).
    public var unified: CanonicalContact?
    /// The card's note was read (notes on, and the mirror had it).
    public var notesKnown: Bool
    /// The contact had an image (the image stays unknown, never "removed").
    public var hadImage: Bool

    enum CodingKeys: String, CodingKey {
        case card
        case recordID = "record_id"
        case siblingIDs = "sibling_ids"
        case groupIDs = "group_ids"
        case unified
        case notesKnown = "notes_known"
        case hadImage = "had_image"
    }
}

/// Why an account counts as unavailable.
public enum UnavailableReason: String, Codable, Hashable, Sendable {
    /// The container is gone from Contacts (account or its Contacts turned off).
    case absent
    /// The container is there but lost (almost) all its cards at once: an
    /// account in a partial state (signing out, re-syncing).
    case collapsed
}

/// An account whose cards are kept as last seen.
public struct UnavailableAccount: Codable, Hashable, Sendable {
    public var containerID: String
    public var name: String
    public var kind: AccountKind
    /// Cards it held when last available.
    public var cardCount: Int
    /// When it was last available.
    public var lastSeen: Date
    /// When this device first found it unavailable.
    public var since: Date
    public var reason: UnavailableReason
    /// When it became visible again (cards are being re-matched), if it did.
    public var returnedAt: Date?
    /// The container it came back as, when Contacts gave it a new id.
    public var successorID: String?
    /// Its cards as last seen (still unresolved, once it returned).
    public var cards: [FrozenCard]
    /// Its groups as last seen (iCloud and On My Mac).
    public var groups: [AppleGroup]

    /// The container its cards are in now (its successor once it returned).
    public var currentContainerID: String { successorID ?? containerID }

    /// `Google ("Gmail", 1,353 cards)`.
    public var label: String {
        "\(kind.displayName) (\"\(name)\", \(AccountGuard.count(cardCount)) cards)"
    }

    enum CodingKeys: String, CodingKey {
        case containerID = "container_id"
        case name, kind
        case cardCount = "card_count"
        case lastSeen = "last_seen"
        case since, reason
        case returnedAt = "returned_at"
        case successorID = "successor_id"
        case cards, groups
    }
}

/// The accounts this device tracks (`meta.accounts`).
public struct AccountsState: Codable, Hashable, Sendable {
    static let currentVersion = 1

    public var version = AccountsState.currentVersion
    public var containers: [TrackedContainer] = []
    public var unavailable: [UnavailableAccount] = []

    /// Creates an empty state.
    public init() {}

    /// The unavailable account of `containerID`.
    public func account(_ containerID: String) -> UnavailableAccount? {
        unavailable.first { $0.containerID == containerID }
    }
}

/// What a run reports about one unavailable account.
public struct AccountStatus: Hashable, Sendable {
    public var account: UnavailableAccount
    /// Records whose every card is in it (kept as last seen, nothing synced).
    public var frozenRecords: Int
    /// Records that also have cards elsewhere (values on its cards kept).
    public var linkedRecords: Int
    /// Apple changes held because they would touch its cards.
    public var heldChanges: Int

    /// Creates a status.
    public init(account: UnavailableAccount, frozenRecords: Int, linkedRecords: Int, heldChanges: Int) {
        self.account = account
        self.frozenRecords = frozenRecords
        self.linkedRecords = linkedRecords
        self.heldChanges = heldChanges
    }

    /// `true` once the account is visible again (cards being re-matched).
    public var isReturning: Bool { account.returnedAt != nil }

    /// The `WARNING account` text: `Google ("Gmail", 1,353 cards) is not
    /// visible in Contacts; its cards are kept as last seen`.
    public var message: String {
        if isReturning {
            return "\(account.label) is visible in Contacts again; \(AccountGuard.count(account.cards.count, "card")) "
                + "still being matched to their notes, kept as last seen meanwhile"
        }
        let partial = account.reason == .collapsed ? " (it lost almost all its cards at once)" : ""
        return "\(account.label) is not visible in Contacts\(partial); its cards are kept as last seen"
    }

    /// Where to look: the account's switch in System Settings (stronger for iCloud).
    public var hint: String {
        switch account.kind {
        case .iCloud: "This is your iCloud account: check System Settings ▸ Apple Account ▸ iCloud ▸ Contacts"
        case .local: "On My Mac contacts are missing: check Contacts ▸ Settings ▸ Accounts"
        default: "Turn its Contacts back on in System Settings ▸ Internet Accounts"
        }
    }

    /// The app's banner: `Google account isn't visible in Contacts — 1,353 cards kept as last seen`.
    public var banner: String {
        if isReturning {
            return "\(account.kind.displayName) account is back — \(AccountGuard.count(account.cards.count, "card")) "
                + "still being matched"
        }
        return "\(account.kind.displayName) account isn't visible in Contacts — "
            + "\(AccountGuard.count(account.cardCount, "card")) kept as last seen"
    }
}

extension AccountGuard {
    /// `meta` key of the tracked accounts.
    public static let stateKey = "accounts"

    /// `1 card`, `1,353 cards`.
    public static func count(_ value: Int, _ noun: String) -> String {
        "\(count(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    /// A count with thousands separators (`1,353`).
    public static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// The tracked accounts of a device (`nil`: never recorded).
    public static func load(from state: any SyncStateStore) -> AccountsState? {
        guard let data = try? state.metadata(stateKey),
            let json = try? (data as NSData).decompressed(using: .lzfse) as Data,
            let decoded = try? JSONDecoder.accounts.decode(AccountsState.self, from: json),
            decoded.version == AccountsState.currentVersion
        else { return nil }
        return decoded
    }

    /// Stores `accounts`. A dry run (`executed == false`) only adds what it
    /// found: accounts it resolved or forgot stay as stored until an
    /// executed run resolves or forgets them too.
    static func save(
        _ accounts: AccountsState, forgotten: Set<String>, executed: Bool, in state: any SyncStateStore
    ) throws {
        var stored = accounts
        if !executed, let previous = load(from: state) {
            let before = Set(previous.unavailable.map(\.containerID))
            stored.unavailable = previous.unavailable + accounts.unavailable.filter { !before.contains($0.containerID) }
            let tracked = Set(stored.containers.map(\.id))
            stored.containers += previous.containers.filter { forgotten.contains($0.id) && !tracked.contains($0.id) }
        }
        let json = try JSONEncoder.accounts.encode(stored)
        try state.setMetadata(stateKey, try (json as NSData).compressed(using: .lzfse) as Data)
    }
}

extension JSONEncoder {
    fileprivate static var accounts: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var accounts: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
