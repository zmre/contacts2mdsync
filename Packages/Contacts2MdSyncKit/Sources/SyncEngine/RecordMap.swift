public import ContactModel
public import Foundation

/// One underlying Apple card bound to a record, as last seen on this device.
public struct BoundCard: Hashable, Sendable {
    public var id: String
    public var containerID: String
    public var accountKind: AccountKind
    /// When this device first saw this card id bound to the record.
    public var firstSeen: Date
    /// A snapshot found this card carrying the record's stamp.
    public var stampSeen: Bool

    /// Creates a bound card.
    public init(id: String, containerID: String, accountKind: AccountKind, firstSeen: Date, stampSeen: Bool = false) {
        self.id = id
        self.containerID = containerID
        self.accountKind = accountKind
        self.firstSeen = firstSeen
        self.stampSeen = stampSeen
    }

    /// Whether the cached id alone identifies the record (architecture §6,
    /// cascade step 2). iCloud and other ids are stable; a Google card's id
    /// changes once after Google sync replaces a new card (spike S9), so a
    /// Google id counts only after a snapshot found the card by its stamp.
    /// Untrusted ids are kept as hints that need corroboration.
    public var isTrusted: Bool { accountKind != .google || stampSeen }
}

/// What the Apple side looked like at the last export, per markdown field, as
/// comparison keys (the per-device merge base, architecture §4 `base_json`).
///
/// M2 uses it so one-way export never drops markdown-only additions: a
/// markdown value Apple lacks is kept unless Apple had it at the last export
/// (then Apple deleted it). M3's three-way merge builds on the same data.
public struct RecordBase: Codable, Hashable, Sendable {
    /// Field name → comparison keys (one for scalars, sorted for lists).
    public var fields: [String: [String]]

    /// Creates a base.
    public init(fields: [String: [String]] = [:]) { self.fields = fields }

    /// Keys of `field` (empty when absent).
    public func keys(_ field: String) -> [String] { fields[field] ?? [] }

    /// Lowercase hex SHA-256 per field, for change detection (M3).
    public var fieldHashes: [String: String] {
        fields.mapValues { FieldHash.of($0) }
    }
}

/// Field-hash helper shared with the state store.
public enum FieldHash {
    /// SHA-256 of the keys joined by U+001F.
    public static func of(_ keys: [String]) -> String {
        hexSHA256(Data(keys.joined(separator: "\u{1F}").utf8))
    }
}

/// Where one record (`c2mdsync.id`) was last seen on each side.
public struct RecordBinding: Hashable, Sendable {
    /// Unified contact id at the last export: a volatile cache (linked
    /// contacts get synthesized ids), never used for identity.
    public var unifiedID: String?
    /// Underlying cards at the last export.
    public var cards: [BoundCard]
    /// Root-relative path of the note at the last export.
    public var path: String
    /// Apple-side field keys at the last export; `nil` for records exported
    /// before M2 or not yet exported.
    public var base: RecordBase?

    /// Creates a binding.
    public init(unifiedID: String?, cards: [BoundCard], path: String, base: RecordBase? = nil) {
        self.unifiedID = unifiedID
        self.cards = cards
        self.path = path
        self.base = base
    }

    /// Card ids, in order.
    public var cardIDs: [String] { cards.map(\.id) }
}

/// Per-device map from record id to Apple card ids, note path and merge base
/// (the `records` table of the device state, architecture §4).
public struct RecordMap: Hashable, Sendable {
    /// Bindings by record id.
    public var records: [UUID: RecordBinding]
    /// When the last export finished.
    public var lastExport: Date?

    /// An empty map.
    public init(records: [UUID: RecordBinding] = [:], lastExport: Date? = nil) {
        self.records = records
        self.lastExport = lastExport
    }

    /// The binding for `id`.
    public subscript(id: UUID) -> RecordBinding? {
        get { records[id] }
        set { records[id] = newValue }
    }

    /// Record ids present in the map.
    public var ids: Set<UUID> { Set(records.keys) }

    /// How a contact's cards point at records.
    public struct CardHit: Hashable, Sendable {
        public var recordID: UUID
        /// At least one shared card id is trusted (cascade step 2, 0.95).
        public var trusted: Bool
        /// A shared card is an iCloud card.
        public var viaICloud: Bool
    }

    /// Precomputed card-id index.
    public struct Lookup: Sendable {
        private var byCardID: [String: [(UUID, BoundCard)]] = [:]

        /// Indexes `map`.
        public init(_ map: RecordMap) {
            for (id, binding) in map.records {
                for card in binding.cards { byCardID[card.id, default: []].append((id, card)) }
            }
        }

        /// Records sharing any of `cardIDs`, strongest first.
        public func hits(cardIDs: [String]) -> [CardHit] {
            var best: [UUID: CardHit] = [:]
            for cardID in cardIDs {
                for (record, card) in byCardID[cardID] ?? [] {
                    var hit = best[record] ?? CardHit(recordID: record, trusted: false, viaICloud: false)
                    hit.trusted = hit.trusted || card.isTrusted
                    hit.viaICloud = hit.viaICloud || card.accountKind == .iCloud
                    best[record] = hit
                }
            }
            return best.values.sorted { lhs, rhs in
                (lhs.trusted ? 0 : 1, lhs.viaICloud ? 0 : 1, lhs.recordID.uuidString)
                    < (rhs.trusted ? 0 : 1, rhs.viaICloud ? 0 : 1, rhs.recordID.uuidString)
            }
        }
    }
}

/// Loads and saves the `RecordMap` (the seam the executor writes through).
public protocol RecordMapStore: Sendable {
    func load() throws -> RecordMap
    func save(_ map: RecordMap) throws
}

/// The M1 `records.json` format, read once to import into the M2 state store.
public enum LegacyRecordMapFile {
    private struct Binding: Decodable {
        var unifiedID: String
        var cardIDs: [String]
        var path: String
    }

    private struct File: Decodable {
        var records: [String: Binding]
        var lastExport: Date?
    }

    /// Reads `url` (nil when absent). Imported cards have unknown containers;
    /// they are trusted (they came from real snapshots) and the next export
    /// refreshes their account kinds.
    public static func read(_ url: URL, now: Date) throws -> RecordMap? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(File.self, from: Data(contentsOf: url))
        var map = RecordMap(lastExport: file.lastExport)
        for (key, binding) in file.records {
            guard let id = UUID(uuidString: key) else { continue }
            let cards = binding.cardIDs.map {
                BoundCard(id: $0, containerID: "", accountKind: .unknown, firstSeen: file.lastExport ?? now)
            }
            map[id] = RecordBinding(unifiedID: binding.unifiedID, cards: cards, path: binding.path)
        }
        return map
    }
}
