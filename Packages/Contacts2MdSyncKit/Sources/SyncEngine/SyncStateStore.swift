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
    /// Per-side counts of a two-way sync (M5; `nil` in older records and
    /// for exports, where `created`/`updated` are markdown counts).
    public var sides: SessionSides?

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

/// What a two-way sync did on each side, plus Apple changes held back.
public struct SessionSides: Codable, Hashable, Sendable {
    public var appleCreated: Int
    public var appleUpdated: Int
    public var appleDeleted: Int
    public var markdownCreated: Int
    public var markdownUpdated: Int
    /// Notes moved to the Trash.
    public var markdownDeleted: Int
    /// Apple changes planned but not written.
    public var held: Int
    /// Why they were held (`apple writes disabled`, the change limit).
    public var heldReason: String?
    /// `full` or `incremental` (how Apple Contacts was read).
    public var appleRead: String?
    /// Notes this run: `entitlement`, `scripting`, `skipped` or `nil` (off).
    public var notes: String?
    /// Records whose markdown body was written to Contacts notes / whose
    /// Contacts note was written to markdown (`nil`: notes off, or older runs).
    public var notesToContacts: Int?
    public var notesToMarkdown: Int?

    /// Creates counts.
    public init(
        appleCreated: Int = 0, appleUpdated: Int = 0, appleDeleted: Int = 0, markdownCreated: Int = 0,
        markdownUpdated: Int = 0, markdownDeleted: Int = 0, held: Int = 0, heldReason: String? = nil,
        appleRead: String? = nil
    ) {
        self.appleCreated = appleCreated
        self.appleUpdated = appleUpdated
        self.appleDeleted = appleDeleted
        self.markdownCreated = markdownCreated
        self.markdownUpdated = markdownUpdated
        self.markdownDeleted = markdownDeleted
        self.held = held
        self.heldReason = heldReason
        self.appleRead = appleRead
    }

    enum CodingKeys: String, CodingKey {
        case appleCreated = "apple_created"
        case appleUpdated = "apple_updated"
        case appleDeleted = "apple_deleted"
        case markdownCreated = "markdown_created"
        case markdownUpdated = "markdown_updated"
        case markdownDeleted = "markdown_deleted"
        case held
        case heldReason = "held_reason"
        case appleRead = "apple_read"
        case notes
        case notesToContacts = "notes_to_contacts"
        case notesToMarkdown = "notes_to_markdown"
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
    /// Writes cards refused (M3 sync).
    func loadUnapplyable() throws -> [UnapplyableEntry]
    func saveUnapplyable(_ entries: [UnapplyableEntry]) throws
}

extension SyncStateStore {
    /// Records whose Apple contact went missing, with when that was first
    /// seen (the Apple delete rail's two-snapshot rule), in `meta`.
    public func loadVanished() throws -> [UUID: Date] {
        guard let data = try metadata("vanished_records"),
            let raw = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return Dictionary(
            raw.compactMap { key, value in UUID(uuidString: key).map { ($0, Date(timeIntervalSince1970: value)) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// Cached image hashes (`meta`), so unchanged images are not re-read.
    public func loadImageHashes() throws -> [String: ImageHashEntry] {
        guard let data = try metadata("image_hashes") else { return [:] }
        return (try? JSONDecoder().decode([String: ImageHashEntry].self, from: data)) ?? [:]
    }

    public func saveImageHashes(_ hashes: [String: ImageHashEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try setMetadata("image_hashes", hashes.isEmpty ? nil : try encoder.encode(hashes))
    }

    public func saveVanished(_ vanished: [UUID: Date]) throws {
        let raw = Dictionary(
            vanished.map { ($0.key.uuidString.lowercased(), $0.value.timeIntervalSince1970) },
            uniquingKeysWith: { first, _ in first })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try setMetadata("vanished_records", raw.isEmpty ? nil : try encoder.encode(raw))
    }
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
        var unapplyable: [UnapplyableEntry] = []
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

    public func loadUnapplyable() throws -> [UnapplyableEntry] { state.withLock { $0.unapplyable } }

    public func saveUnapplyable(_ entries: [UnapplyableEntry]) throws {
        state.withLock { $0.unapplyable = entries }
    }
}
