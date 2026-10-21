public import Foundation
internal import Synchronization
public import VaultIndex

/// A review item as stored in the device's pending queue.
public struct PendingReview: Codable, Hashable, Sendable {
    public var item: ReviewItem
    /// When this device first saw the item.
    public var firstSeen: Date

    /// Creates a pending entry.
    public init(item: ReviewItem, firstSeen: Date) {
        self.item = item
        self.firstSeen = firstSeen
    }

    /// The item's stable id.
    public var id: String { item.id }
}

/// The pending review queue as of the last plan or export.
public struct PendingReviews: Hashable, Sendable {
    /// When the queue was computed (`nil`: never).
    public var computedAt: Date?
    public var items: [PendingReview]

    /// Creates a queue.
    public init(computedAt: Date? = nil, items: [PendingReview] = []) {
        self.computedAt = computedAt
        self.items = items
    }

    /// Replaces the queue with `items`, keeping first-seen dates.
    public func replacing(with items: [ReviewItem], at date: Date) -> PendingReviews {
        let known = Dictionary(self.items.map { ($0.id, $0.firstSeen) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let fresh = items.filter { seen.insert($0.id).inserted }.map {
            PendingReview(item: $0, firstSeen: known[$0.id] ?? date)
        }
        return PendingReviews(computedAt: date, items: fresh)
    }
}

/// An Apple group as tracked on this device (CN id ↔ name ↔ tag).
public struct GroupBinding: Codable, Hashable, Sendable {
    public var groupID: String
    public var containerID: String
    public var name: String
    public var tag: String?

    /// Creates a group binding.
    public init(groupID: String, containerID: String, name: String, tag: String?) {
        self.groupID = groupID
        self.containerID = containerID
        self.name = name
        self.tag = tag
    }
}

/// One run, for Activity / `status`.
public struct SessionRecord: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    /// `export`, `plan`, …
    public var command: String
    /// `CLI`, `GUI`.
    public var trigger: String
    public var deviceID: String
    public var created: Int
    public var updated: Int
    public var adopted: Int
    public var unchanged: Int
    public var skipped: Int
    public var pendingReview: Int
    public var stamped: Int
    public var failures: Int

    /// Creates a session record.
    public init(
        startedAt: Date, finishedAt: Date, command: String, trigger: String, deviceID: String, created: Int = 0,
        updated: Int = 0, adopted: Int = 0, unchanged: Int = 0, skipped: Int = 0, pendingReview: Int = 0,
        stamped: Int = 0, failures: Int = 0
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.command = command
        self.trigger = trigger
        self.deviceID = deviceID
        self.created = created
        self.updated = updated
        self.adopted = adopted
        self.unchanged = unchanged
        self.skipped = skipped
        self.pendingReview = pendingReview
        self.stamped = stamped
        self.failures = failures
    }
}

/// Per-device sync state (architecture §4): `~/Library/Application Support/
/// Contacts2MdSync/<vault_id>/state.sqlite` in production (`SyncStateDB`),
/// in memory for tests and dry runs.
///
/// The record map is the M1 `RecordMapStore` seam, extended with the file
/// cache, pending review queue, decision mirror, group map, reported-problem
/// hashes, sessions and small key/value metadata (history token from M5).
public protocol SyncStateStore: RecordMapStore {
    func loadFileCache() throws -> [String: FileCacheEntry]
    func saveFileCache(_ cache: [String: FileCacheEntry]) throws
    func loadPending() throws -> PendingReviews
    func savePending(_ pending: PendingReviews) throws
    /// Local mirror of the vault's decision logs (for display and offline reads).
    func loadDecisionMirror() throws -> [Decision]
    func saveDecisionMirror(_ decisions: [Decision]) throws
    func loadGroups() throws -> [GroupBinding]
    func saveGroups(_ groups: [GroupBinding]) throws
    /// Content hashes of non-contact problem files already reported.
    func reportedProblemHashes() throws -> Set<String>
    /// Remembers that these problems (sha256 → path) were reported.
    func markProblemsReported(_ problems: [String: String]) throws
    func appendSession(_ session: SessionRecord) throws
    /// Newest first.
    func recentSessions(limit: Int) throws -> [SessionRecord]
    func metadata(_ key: String) throws -> Data?
    func setMetadata(_ key: String, _ value: Data?) throws
}

/// In-memory `SyncStateStore` (tests, dry runs).
public final class InMemorySyncStateStore: SyncStateStore {
    private struct State {
        var records = RecordMap()
        var fileCache: [String: FileCacheEntry] = [:]
        var pending = PendingReviews()
        var decisions: [Decision] = []
        var groups: [GroupBinding] = []
        var problems: [String: String] = [:]
        var sessions: [SessionRecord] = []
        var metadata: [String: Data] = [:]
        var saves = 0
    }

    private let state: Mutex<State>

    /// Creates a store holding `records`.
    public init(_ records: RecordMap = RecordMap()) {
        var initial = State()
        initial.records = records
        state = Mutex(initial)
    }

    /// Number of `save(_:)` calls (tests).
    public var recordSaves: Int { state.withLock { $0.saves } }

    public func load() throws -> RecordMap { state.withLock { $0.records } }

    public func save(_ map: RecordMap) throws {
        state.withLock {
            $0.records = map
            $0.saves += 1
        }
    }

    public func loadFileCache() throws -> [String: FileCacheEntry] { state.withLock { $0.fileCache } }
    public func saveFileCache(_ cache: [String: FileCacheEntry]) throws { state.withLock { $0.fileCache = cache } }
    public func loadPending() throws -> PendingReviews { state.withLock { $0.pending } }
    public func savePending(_ pending: PendingReviews) throws { state.withLock { $0.pending = pending } }
    public func loadDecisionMirror() throws -> [Decision] { state.withLock { $0.decisions } }
    public func saveDecisionMirror(_ decisions: [Decision]) throws { state.withLock { $0.decisions = decisions } }
    public func loadGroups() throws -> [GroupBinding] { state.withLock { $0.groups } }
    public func saveGroups(_ groups: [GroupBinding]) throws { state.withLock { $0.groups = groups } }
    public func reportedProblemHashes() throws -> Set<String> { state.withLock { Set($0.problems.keys) } }

    public func markProblemsReported(_ problems: [String: String]) throws {
        state.withLock { $0.problems.merge(problems) { _, new in new } }
    }

    public func appendSession(_ session: SessionRecord) throws { state.withLock { $0.sessions.append(session) } }

    public func recentSessions(limit: Int) throws -> [SessionRecord] {
        state.withLock { Array($0.sessions.reversed().prefix(limit)) }
    }

    public func metadata(_ key: String) throws -> Data? { state.withLock { $0.metadata[key] } }

    public func setMetadata(_ key: String, _ value: Data?) throws { state.withLock { $0.metadata[key] = value } }
}
