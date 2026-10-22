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
    /// Without stamps: the card was corroborated by the record's strong keys
    /// or name in a snapshot at least `BoundCard.settleInterval` after it was
    /// first seen (Google's id churn after create has settled).
    public var confirmed: Bool

    /// How long a Google card id must survive before corroboration confirms it.
    public static let settleInterval: TimeInterval = 10 * 60

    /// Creates a bound card.
    public init(
        id: String, containerID: String, accountKind: AccountKind, firstSeen: Date, stampSeen: Bool = false,
        confirmed: Bool = false
    ) {
        self.id = id
        self.containerID = containerID
        self.accountKind = accountKind
        self.firstSeen = firstSeen
        self.stampSeen = stampSeen
        self.confirmed = confirmed
    }

    /// Whether the cached id alone identifies the record (architecture §6,
    /// cascade step 2). iCloud and other ids are stable; a Google card's id
    /// changes once after Google sync replaces a new card (spike S9), so a
    /// Google id counts only after a snapshot found the card by its stamp or,
    /// without stamps, confirmed it by strong keys once churn had settled.
    /// Untrusted ids are kept as hints that need corroboration.
    public var isTrusted: Bool { accountKind != .google || stampSeen || confirmed }
}

/// The per-device merge base (architecture §4 `base_json`, §7).
///
/// M2 (version `nil`) stored only what the Apple side looked like at the
/// last export, as comparison keys per markdown field (`fields`); one-way
/// export uses it so a markdown value Apple lacks is kept unless Apple had it.
///
/// From M3 (version 2) the base is what both sides **agreed on** after the
/// last sync, field by field: a field (or list element) where Apple and the
/// markdown note still differ after a run — a held Apple write, an unresolved
/// conflict, a failed write — keeps its previous base, so the pending change
/// is found again next run. Absent keys mean "known empty"; `unknown` lists
/// fields with no base yet (merged with the first-bind rule).
public struct RecordBase: Codable, Hashable, Sendable {
    /// Field name → comparison keys (one for scalars, sorted for lists).
    public var fields: [String: [String]]
    /// `2` for an M3 merge base; `nil` for an M2 export base.
    public var version: Int?
    /// Fields without a base (first-bind rule), version 2 only.
    public var unknown: [String]?
    /// List field → element key → markdown label (`""` = no label).
    public var labels: [String: [String: String]]?
    /// Field → element key (`""` for scalars) → display text, for conflict views.
    public var displays: [String: [String: String]]?
    /// The note body (comparison form), when notes are synced.
    public var body: String?
    /// Managed tags (comparison keys).
    public var tags: [String]?
    /// SHA-256 of the contact image (`nil` = none).
    public var imageHash: String?
    /// The title generated from Apple's name at the last sync (title rule).
    public var generatedTitle: String?
    /// Name keys (folded, as in `fields["name"]`) the record answered to
    /// before a rename, oldest first, at most `RecordBase.formerNameLimit`.
    /// Relation names on other contacts' cards that still use one of them
    /// resolve to this record and are updated to its current name (§8).
    public var formerNames: [String]?

    /// How many former names a base keeps.
    public static let formerNameLimit = 8

    /// Creates an (M2-style) base.
    public init(fields: [String: [String]] = [:]) { self.fields = fields }

    /// Keys of `field` (empty when absent).
    public func keys(_ field: String) -> [String] { fields[field] ?? [] }

    /// Lowercase hex SHA-256 per field, for change detection.
    public var fieldHashes: [String: String] {
        fields.mapValues { FieldHash.of($0) }
    }

    /// `true` for an M3 merge base.
    public var isMergeBase: Bool { (version ?? 0) >= 2 }

    /// Every name key this record answered to at the last sync or before
    /// (the personal name and generated title keys, plus former names).
    public var nameHistoryKeys: [String] {
        var keys = (formerNames ?? []) + keys("name")
        if let generatedTitle { keys.append(ComparisonKeys.name(generatedTitle)) }
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
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
