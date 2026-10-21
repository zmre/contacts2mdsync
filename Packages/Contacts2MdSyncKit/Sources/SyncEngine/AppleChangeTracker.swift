public import ContactModel
public import Foundation

/// How a run wants to read Apple Contacts.
public enum AppleReadMode: String, Hashable, Sendable, Codable {
    /// Always a full snapshot (launch / wake catch-up, safety sweep, Sync Now, `sync --full`).
    case full
    /// Use the change-history token when it is valid; fall back to a full
    /// snapshot whenever it is not (live events, `contacts2md sync`).
    case incremental
}

/// Why a run read a full snapshot instead of an incremental change set.
public enum FullSnapshotReason: String, Hashable, Sendable, Codable {
    /// The run asked for one.
    case requested
    /// No usable cached snapshot or token (first run, cache from an older version).
    case noCache = "no-cache"
    /// The store has no change history.
    case historyUnsupported = "history-unsupported"
    /// `DropEverything`, error 603/604 or a token the store does not know.
    case historyReset = "history-reset"
    /// Reading the history failed.
    case historyFailed = "history-failed"
    /// Cards were deleted: only full snapshots may observe deletions (§9).
    case deletions
    /// A group was added, renamed or deleted.
    case groupsChanged = "groups-changed"
    /// So many cards changed that a full snapshot is as cheap.
    case tooManyChanges = "many-changes"
    /// The vault config or the decision logs changed since the cached snapshot.
    case settingsChanged = "settings-changed"
    /// A possibly deleted record is due for its second (confirming) snapshot.
    case deleteConfirmationDue = "delete-confirmation-due"
    /// A synced record has no card in the patched snapshot.
    case cacheInconsistent = "cache-inconsistent"
    /// The plan needs image bytes of a contact the history did not touch.
    case imagesNeeded = "images-needed"

    /// Short text for output.
    public var text: String {
        switch self {
        case .requested: "requested"
        case .noCache: "no cached snapshot"
        case .historyUnsupported: "no change history"
        case .historyReset: "change history reset"
        case .historyFailed: "change history unreadable"
        case .deletions: "contacts deleted"
        case .groupsChanged: "groups changed"
        case .tooManyChanges: "many contacts changed"
        case .settingsChanged: "config or decisions changed"
        case .deleteConfirmationDue: "deletion due for confirmation"
        case .cacheInconsistent: "cache inconsistent"
        case .imagesNeeded: "images needed"
        }
    }
}

/// How a run's Apple snapshot was obtained.
public enum AppleReadKind: Hashable, Sendable {
    /// A full snapshot (the source of truth for deletions and the breaker).
    case full(FullSnapshotReason)
    /// The cached snapshot patched with the cards the history reported
    /// (`changedCards`) and the cards of notes that changed, re-read as
    /// `refetchedContacts` unified contacts.
    case incremental(changedCards: Int, refetchedContacts: Int)

    /// `true` for a full snapshot.
    public var isFull: Bool {
        if case .full = self { return true }
        return false
    }

    /// One line for output: `full snapshot (reason)` / `incremental: …`.
    public var summary: String {
        switch self {
        case .full(let reason): "full snapshot (\(reason.text))"
        case .incremental(let changed, let refetched):
            "incremental: \(changed) changed cards, \(refetched) contacts re-read"
        }
    }
}

/// The Apple side of one run, plus what to remember about it afterwards.
public struct AppleRead: Sendable {
    /// What the planner sees: a full snapshot, or the cache patched with re-read contacts.
    public var snapshot: AppleSnapshot
    public var kind: AppleReadKind
    /// History token that `snapshot` is current as of.
    var token: Data?
    /// Image sha256 by contact key (first card id), for the cache.
    var imageHashes: [String: String]
    /// Card ids of contacts whose image is masked as unknown (not re-read).
    var maskedCards: Set<String>
    /// `AppleChangeTracker.settingsKey` at read time.
    var settingsKey: String

    /// `true` when `snapshot` is a full snapshot.
    public var isComplete: Bool { kind.isFull }

    /// Wraps a full snapshot read without a tracker.
    public static func full(_ snapshot: AppleSnapshot, reason: FullSnapshotReason = .requested) -> AppleRead {
        AppleRead(
            snapshot: snapshot, kind: .full(reason), token: nil, imageHashes: [:], maskedCards: [], settingsKey: "")
    }
}

/// What the tracker needs to know about the vault side of a run.
public struct AppleReadContext: Sendable {
    public var records: RecordMap
    /// Records whose note changed since the last run (their contacts are re-read).
    public var vaultTouchedRecords: Set<UUID>
    /// `AppleChangeTracker.settingsKey(configText:decisions:)`.
    public var settingsKey: String
    public var vanished: [UUID: Date]
    public var now: Date
    public var deleteConfirmInterval: TimeInterval

    /// Creates a context.
    public init(
        records: RecordMap, vaultTouchedRecords: Set<UUID>, settingsKey: String, vanished: [UUID: Date], now: Date,
        deleteConfirmInterval: TimeInterval = SyncOptions().deleteConfirmInterval
    ) {
        self.records = records
        self.vaultTouchedRecords = vaultTouchedRecords
        self.settingsKey = settingsKey
        self.vanished = vanished
        self.now = now
        self.deleteConfirmInterval = deleteConfirmInterval
    }
}

/// History-token acceleration (architecture §10).
///
/// The device state keeps a mirror of Apple Contacts as of a history token
/// (`meta.apple_cache`). An incremental read asks the store what changed
/// since that token (our own saves excluded by `transactionAuthor`),
/// re-reads only the touched cards' contacts (plus the contacts of notes
/// that changed), and patches the mirror. Anything unusual — no token,
/// `DropEverything`, a history error, a deletion, a group added or renamed,
/// many changes, changed config or decisions, a deletion due for
/// confirmation, an inconsistent patch — falls back to a full snapshot.
///
/// **Incremental runs never conclude deletions.** Deleted cards force a full
/// snapshot, and the planner, told the snapshot is not complete
/// (`SyncInputs.appleSnapshotComplete == false`), neither records newly
/// vanished records, confirms queued ones, nor counts them toward the
/// mass-vanish breaker. Only full snapshots feed the two-snapshot delete
/// rule and the breaker; a vanished record due for confirmation forces one.
///
/// Images of contacts that were not re-read are not cached as bytes: they
/// are marked unknown (`imageUnavailable`), which the merge already treats
/// as "never removed, never compared". A plan that would create a note for
/// such a contact is re-planned on a full snapshot (`imagesNeeded`).
public struct AppleChangeTracker: Sendable {
    /// `meta` key of the cached snapshot (token included).
    public static let cacheKey = "apple_cache"
    /// `meta` key of the last run planned on a full snapshot.
    public static let lastFullCompareKey = "last_full_compare"

    public let store: any ContactStore
    public let state: any SyncStateStore
    /// `transactionAuthor`s whose saves are ours (excluded from history).
    public let authors: [String]
    /// More touched cards than this (and than `maxChangeFraction` of all
    /// cards) → a full snapshot instead.
    public var maxChangedCards: Int
    public var maxChangeFraction: Double

    /// Creates a tracker for this device's own `transactionAuthor`s.
    public init(
        store: any ContactStore, state: any SyncStateStore, deviceID: String, maxChangedCards: Int = 100,
        maxChangeFraction: Double = 0.2
    ) {
        self.store = store
        self.state = state
        self.authors = [SyncEngine.transactionAuthor(deviceID: deviceID), SyncEngine.transactionAuthorPrefix + "cli"]
        self.maxChangedCards = maxChangedCards
        self.maxChangeFraction = maxChangeFraction
    }

    /// Hash of what changes the meaning of untouched contacts (config text,
    /// decision ids): when it differs from the cache's, the run goes full.
    public static func settingsKey(configText: String?, decisions: [Decision]) -> String {
        let ids = decisions.map { "\($0.id)" }.sorted().joined(separator: "\n")
        return hexSHA256(Data(((configText ?? "") + "\n" + ids).utf8))
    }

    // MARK: - Read

    /// Reads Apple Contacts for one run (see the type documentation).
    public func read(
        mode: AppleReadMode, context: AppleReadContext, fullReason: FullSnapshotReason = .requested
    ) throws -> AppleRead {
        guard mode == .incremental else { return try full(fullReason, context: context) }
        switch try incrementalChanges(context: context) {
        case .failure(let reason):
            return try full(reason, context: context)
        case .success(let (cache, changes)):
            var touched = Set(changes.changedCardIDs)
            for id in context.vaultTouchedRecords {
                touched.formUnion(context.records[id]?.cards.map(\.id) ?? [])
            }
            let totalCards = cache.contacts.reduce(0) { $0 + $1.cards.count }
            if touched.count > max(maxChangedCards, Int(Double(totalCards) * maxChangeFraction)) {
                return try full(.tooManyChanges, context: context)
            }
            let patched = try patch(
                cache, touched: touched, changedCards: changes.changedCardIDs.count, token: changes.token,
                context: context)
            return try patched ?? full(.cacheInconsistent, context: context)
        }
    }

    /// The cache and the history since its token, or why a full read is needed.
    private func incrementalChanges(context: AppleReadContext) throws -> IncrementalChanges {
        guard let cache = loadCache(), let token = cache.token else { return .failure(.noCache) }
        guard cache.settingsKey == context.settingsKey else { return .failure(.settingsChanged) }
        let due = { (since: Date) in context.now.timeIntervalSince(since) >= context.deleteConfirmInterval }
        if context.vanished.values.contains(where: due) {
            return .failure(.deleteConfirmationDue)
        }
        let history: HistoryResult
        do {
            history = try store.changes(since: token, excluding: authors)
        } catch ContactStoreError.accessDenied {
            throw ContactStoreError.accessDenied
        } catch {
            return .failure(.historyFailed)
        }
        switch history {
        case .unsupported: return .failure(.historyUnsupported)
        case .reset: return .failure(.historyReset)
        case .changes(let changes) where !changes.deletedCardIDs.isEmpty: return .failure(.deletions)
        case .changes(let changes) where changes.groupsChanged: return .failure(.groupsChanged)
        case .changes(let changes): return .success((cache, changes))
        }
    }

    private func full(_ reason: FullSnapshotReason, context: AppleReadContext) throws -> AppleRead {
        // The token is read before the snapshot: anything saved in between
        // is reported again next time (harmless), never lost.
        let token = try? store.currentHistoryToken()
        let snapshot = try store.snapshot()
        return AppleRead(
            snapshot: snapshot, kind: .full(reason), token: token, imageHashes: Self.imageHashes(snapshot),
            maskedCards: [], settingsKey: context.settingsKey)
    }

    /// The cache with the touched contacts re-read; `nil` when a synced
    /// record would be left without any card (then the run goes full).
    private func patch(
        _ cache: AppleSnapshotCache, touched: Set<String>, changedCards: Int, token: Data?, context: AppleReadContext
    ) throws -> AppleRead? {
        var contacts = cache.contacts
        var containers = cache.containers
        var groups = cache.groups
        var notesAvailable = cache.notesAvailable
        var hashes = cache.imageHashes
        var refetched: [AppleContact] = []
        if !touched.isEmpty {
            let siblings = contacts.filter { $0.cards.contains { touched.contains($0.id) } }.flatMap(\.cardIDs)
            let result = try store.refetch(
                cardIDs: touched.sorted(), siblingHints: Array(Set(siblings).subtracting(touched)).sorted())
            refetched = result.contacts
            let replaced = touched.union(refetched.flatMap(\.cardIDs))
            contacts.removeAll { $0.cards.contains { replaced.contains($0.id) } }
            containers = result.containers
            groups = result.groups
            notesAvailable = result.notesAvailable
            for contact in refetched {
                hashes[Self.key(contact)] = contact.imageData.map(hexSHA256)
            }
        }
        var masked = Set<String>()
        contacts = contacts.map { contact in
            var copy = contact
            if hashes[Self.key(contact)] != nil {
                copy.imageUnavailable = true  // bytes not re-read: unknown, never "removed"
                masked.formUnion(contact.cardIDs)
            }
            return copy
        }
        contacts += refetched
        let present = Set(contacts.flatMap(\.cardIDs))
        for (id, binding) in context.records.records where context.vanished[id] == nil && !binding.cards.isEmpty {
            guard binding.cards.contains(where: { present.contains($0.id) }) else { return nil }
        }
        let snapshot = AppleSnapshot(
            contacts: contacts, containers: containers, groups: groups, notesAvailable: notesAvailable)
        return AppleRead(
            snapshot: snapshot, kind: .incremental(changedCards: changedCards, refetchedContacts: refetched.count),
            token: token, imageHashes: hashes.filter { present.contains($0.key) }, maskedCards: masked,
            settingsKey: context.settingsKey)
    }

    // MARK: - Commit

    /// Remembers the Apple state after a run: the post-write snapshot and the
    /// token read just before it when the run wrote to Apple (so our own
    /// saves are never reported back), else what the run read. `compared`
    /// marks a run planned on a full snapshot (the safety sweep's window).
    public func commit(
        _ read: AppleRead, postWrite: (snapshot: AppleSnapshot, token: Data?)?, compared: Bool, now: Date
    ) throws {
        if compared {
            try state.setMetadata(Self.lastFullCompareKey, Data(String(now.timeIntervalSince1970).utf8))
        }
        var cache: AppleSnapshotCache
        if let postWrite {
            cache = AppleSnapshotCache(
                snapshot: postWrite.snapshot, token: postWrite.token, imageHashes: Self.imageHashes(postWrite.snapshot),
                masked: [], settingsKey: read.settingsKey, savedAt: now)
        } else {
            cache = AppleSnapshotCache(
                snapshot: read.snapshot, token: read.token, imageHashes: read.imageHashes, masked: read.maskedCards,
                settingsKey: read.settingsKey, savedAt: now)
        }
        guard cache.token != nil else {
            try state.setMetadata(Self.cacheKey, nil)
            return
        }
        cache.version = AppleSnapshotCache.currentVersion
        try state.setMetadata(Self.cacheKey, try cache.encoded())
    }

    /// Forgets the cached snapshot (the next incremental read goes full).
    public func invalidate() throws { try state.setMetadata(Self.cacheKey, nil) }

    /// When a run was last planned on a full snapshot (any process on this device).
    public func lastFullCompare() -> Date? { Self.lastFullCompare(in: state) }

    /// When a run was last planned on a full snapshot, from a device state.
    public static func lastFullCompare(in state: any SyncStateStore) -> Date? {
        guard let data = try? state.metadata(lastFullCompareKey),
            let text = String(bytes: data, encoding: .utf8), let seconds = Double(text)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func loadCache() -> AppleSnapshotCache? {
        guard let data = try? state.metadata(Self.cacheKey) else { return nil }
        return AppleSnapshotCache.decode(data)
    }

    // MARK: - Helpers

    /// A contact's cache key: its first card id (unified ids are volatile).
    static func key(_ contact: AppleContact) -> String { contact.cards.first?.id ?? contact.unifiedID }

    static func imageHashes(_ snapshot: AppleSnapshot) -> [String: String] {
        var hashes: [String: String] = [:]
        for contact in snapshot.contacts {
            if let data = contact.imageData { hashes[key(contact)] = hexSHA256(data) }
        }
        return hashes
    }
}

/// `FullSnapshotReason` as a `Result` failure.
typealias FullReadNeeded = FullSnapshotReason

/// The cache and the history since its token, or why a full read is needed.
typealias IncrementalChanges = Result<(AppleSnapshotCache, HistoryChanges), FullReadNeeded>

extension FullSnapshotReason: Error {}
