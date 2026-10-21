public import Foundation
internal import Synchronization

/// Where one record (`mdsync.id`) was last seen on each side.
public struct RecordBinding: Codable, Hashable, Sendable {
    /// Unified contact id at last export (may churn; card ids are the backup).
    public var unifiedID: String
    /// Underlying card ids at last export.
    public var cardIDs: [String]
    /// Root-relative path of the note at last export.
    public var path: String

    /// Creates a binding.
    public init(unifiedID: String, cardIDs: [String], path: String) {
        self.unifiedID = unifiedID
        self.cardIDs = cardIDs
        self.path = path
    }
}

/// Per-device map from record id to Apple ids and note path.
///
/// M1 stand-in for the GRDB `records` table (architecture §4), persisted as a
/// small JSON file. It is what makes re-export idempotent before (and
/// without) the Apple-side stamp: an Apple contact whose card ids are known
/// keeps its `mdsync.id`.
public struct RecordMap: Codable, Hashable, Sendable {
    /// Bindings keyed by lowercase record id.
    public var records: [String: RecordBinding]
    /// When the last export finished.
    public var lastExport: Date?

    /// An empty map.
    public init(records: [String: RecordBinding] = [:], lastExport: Date? = nil) {
        self.records = records
        self.lastExport = lastExport
    }

    /// The binding for `id`.
    public subscript(id: UUID) -> RecordBinding? {
        get { records[id.uuidString.lowercased()] }
        set { records[id.uuidString.lowercased()] = newValue }
    }

    /// The record bound to a unified contact, by unified id or any card id.
    /// Ambiguous card overlaps (two records) yield `nil`. For many lookups,
    /// build a `Lookup` once instead.
    public func recordID(unifiedID: String, cardIDs: [String]) -> UUID? {
        Lookup(self).recordID(unifiedID: unifiedID, cardIDs: cardIDs)
    }

    /// Precomputed indexes for `recordID(unifiedID:cardIDs:)`.
    public struct Lookup: Sendable {
        private var byUnifiedID: [String: UUID] = [:]
        private var byCardID: [String: Set<UUID>] = [:]

        /// Indexes `map`.
        public init(_ map: RecordMap) {
            for (key, binding) in map.records {
                guard let id = UUID(uuidString: key) else { continue }
                byUnifiedID[binding.unifiedID] = id
                for card in binding.cardIDs { byCardID[card, default: []].insert(id) }
            }
        }

        /// See `RecordMap.recordID(unifiedID:cardIDs:)`.
        public func recordID(unifiedID: String, cardIDs: [String]) -> UUID? {
            if let exact = byUnifiedID[unifiedID] { return exact }
            let candidates = cardIDs.reduce(into: Set<UUID>()) { $0.formUnion(byCardID[$1] ?? []) }
            return candidates.count == 1 ? candidates.first : nil
        }
    }

    /// Record ids present in the map.
    public var ids: Set<UUID> { Set(records.keys.compactMap(UUID.init(uuidString:))) }
}

/// Loads and saves the `RecordMap`.
public protocol RecordMapStore: Sendable {
    func load() throws -> RecordMap
    func save(_ map: RecordMap) throws
}

/// JSON file implementation (`<state dir>/records.json`), written atomically.
public struct JSONRecordMapStore: RecordMapStore {
    /// The JSON file.
    public let url: URL

    /// Creates a store for `url`.
    public init(url: URL) { self.url = url }

    public func load() throws -> RecordMap {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return RecordMap() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordMap.self, from: Data(contentsOf: url))
    }

    public func save(_ map: RecordMap) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(map).write(to: url, options: .atomic)
    }
}

/// In-memory implementation (tests, dry runs).
public final class InMemoryRecordMapStore: RecordMapStore {
    private let map: Mutex<RecordMap>

    /// Creates a store holding `initial`.
    public init(_ initial: RecordMap = RecordMap()) { map = Mutex(initial) }

    public func load() throws -> RecordMap { map.withLock { $0 } }

    public func save(_ newValue: RecordMap) throws { map.withLock { $0 = newValue } }
}
