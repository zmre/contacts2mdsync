internal import ContactModel
public import Foundation
internal import GRDB
public import SyncEngine

/// The per-device state database (architecture §4):
/// `~/Library/Application Support/Contacts2MdSync/<vault_id>/state.sqlite`.
///
/// Tables: `records` + `record_cards` + `field_hashes` (record map and merge
/// base), `file_cache`, `groups`, `pending`, `decisions` (mirror of the vault
/// logs), `reported_problems`, `unapplyable` (M3), `sessions`, `meta`.
/// Every save is one transaction.
public final class GRDBSyncStateStore: SyncStateStore {
    /// File name inside the vault's state folder.
    public static let fileName = "state.sqlite"

    let queue: DatabaseQueue

    /// Opens (creating and migrating) the database at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: url.path(percentEncoded: false))
        try Self.migrator.migrate(queue)
    }

    /// An in-memory database (tests).
    public init() throws {
        queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
    }

    /// Opens `<directory>/state.sqlite` and, the first time, imports an M1
    /// `records.json` from the same folder (renamed to `records.json.imported`).
    public static func open(directory: URL, now: Date = Date()) throws -> GRDBSyncStateStore {
        let store = try GRDBSyncStateStore(url: directory.appending(path: fileName))
        let legacy = directory.appending(path: "records.json")
        if try store.load().records.isEmpty, let map = try LegacyRecordMapFile.read(legacy, now: now) {
            try store.save(map)
            let imported = directory.appending(path: "records.json.imported")
            try? FileManager.default.removeItem(at: imported)
            try FileManager.default.moveItem(at: legacy, to: imported)
        }
        return store
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in
            try database.execute(
                sql: """
                    CREATE TABLE records (
                        id TEXT PRIMARY KEY NOT NULL,
                        unified_id TEXT,
                        path TEXT NOT NULL,
                        base_json TEXT
                    );
                    CREATE TABLE record_cards (
                        record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
                        card_id TEXT NOT NULL,
                        container_id TEXT NOT NULL,
                        account_kind TEXT NOT NULL,
                        first_seen DOUBLE NOT NULL,
                        stamp_seen INTEGER NOT NULL DEFAULT 0,
                        position INTEGER NOT NULL,
                        PRIMARY KEY (record_id, card_id)
                    );
                    CREATE INDEX record_cards_card ON record_cards(card_id);
                    CREATE TABLE field_hashes (
                        record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
                        field TEXT NOT NULL,
                        hash TEXT NOT NULL,
                        PRIMARY KEY (record_id, field)
                    );
                    CREATE TABLE file_cache (
                        path TEXT PRIMARY KEY NOT NULL,
                        mtime DOUBLE NOT NULL,
                        size INTEGER NOT NULL,
                        sha256 TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        sync_id TEXT,
                        title TEXT,
                        aliases_json TEXT,
                        problem TEXT,
                        contact_related INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE groups (
                        group_id TEXT PRIMARY KEY NOT NULL,
                        container_id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        tag TEXT
                    );
                    CREATE TABLE pending (
                        item_id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        json TEXT NOT NULL,
                        first_seen DOUBLE NOT NULL,
                        position INTEGER NOT NULL
                    );
                    CREATE TABLE decisions (
                        id TEXT PRIMARY KEY NOT NULL,
                        device_id TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        created_at DOUBLE NOT NULL,
                        json TEXT NOT NULL
                    );
                    CREATE TABLE reported_problems (
                        sha256 TEXT PRIMARY KEY NOT NULL,
                        path TEXT NOT NULL
                    );
                    CREATE TABLE unapplyable (
                        record_id TEXT NOT NULL,
                        card_id TEXT NOT NULL,
                        field TEXT NOT NULL,
                        value_hash TEXT NOT NULL,
                        PRIMARY KEY (record_id, card_id, field)
                    );
                    CREATE TABLE sessions (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        started_at DOUBLE NOT NULL,
                        json TEXT NOT NULL
                    );
                    CREATE TABLE meta (
                        key TEXT PRIMARY KEY NOT NULL,
                        value BLOB
                    );
                    """)
        }
        migrator.registerMigration("v2") { database in
            // M3: unapplyable writes keep what the card showed afterwards;
            // Google card ids can be confirmed without stamps.
            try database.execute(
                sql: """
                    ALTER TABLE unapplyable ADD COLUMN attempted TEXT NOT NULL DEFAULT '';
                    ALTER TABLE unapplyable ADD COLUMN observed TEXT NOT NULL DEFAULT '';
                    ALTER TABLE record_cards ADD COLUMN confirmed INTEGER NOT NULL DEFAULT 0;
                    """)
        }
        return migrator
    }

    // MARK: - Records

    public func load() throws -> RecordMap {
        try queue.read { database in
            var cardsByRecord: [String: [BoundCard]] = [:]
            let cardRows = try Row.fetchCursor(database, sql: "SELECT * FROM record_cards ORDER BY record_id, position")
            while let row = try cardRows.next() {
                let card = BoundCard(
                    id: row["card_id"], containerID: row["container_id"],
                    accountKind: AccountKind(rawValue: row["account_kind"]) ?? .unknown,
                    firstSeen: Date(timeIntervalSince1970: row["first_seen"]), stampSeen: row["stamp_seen"],
                    confirmed: row["confirmed"])
                cardsByRecord[row["record_id"], default: []].append(card)
            }
            var map = RecordMap()
            let rows = try Row.fetchCursor(database, sql: "SELECT * FROM records")
            while let row = try rows.next() {
                let key: String = row["id"]
                guard let id = UUID(uuidString: key) else { continue }
                let baseJSON: String? = row["base_json"]
                let base = try baseJSON.map { try JSONDecoder().decode(RecordBase.self, from: Data($0.utf8)) }
                map[id] = RecordBinding(
                    unifiedID: row["unified_id"], cards: cardsByRecord[key] ?? [], path: row["path"], base: base)
            }
            map.lastExport = try Self.metaDate(database, "last_export")
            return map
        }
    }

    public func save(_ map: RecordMap) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try queue.write { database in
            try database.execute(sql: "DELETE FROM records")
            for (id, binding) in map.records.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                let key = id.uuidString.lowercased()
                let baseJSON = try binding.base.map { utf8(try encoder.encode($0)) }
                try database.execute(
                    sql: "INSERT INTO records (id, unified_id, path, base_json) VALUES (?, ?, ?, ?)",
                    arguments: [key, binding.unifiedID, binding.path, baseJSON])
                for (position, card) in binding.cards.enumerated() {
                    try database.execute(
                        sql: """
                            INSERT OR REPLACE INTO record_cards
                            (record_id, card_id, container_id, account_kind, first_seen, stamp_seen, position,
                             confirmed)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            key, card.id, card.containerID, card.accountKind.rawValue,
                            card.firstSeen.timeIntervalSince1970, card.stampSeen, position, card.confirmed,
                        ])
                }
                for (field, hash) in binding.base?.fieldHashes ?? [:] {
                    try database.execute(
                        sql: "INSERT INTO field_hashes (record_id, field, hash) VALUES (?, ?, ?)",
                        arguments: [key, field, hash])
                }
            }
            try Self.setMeta(
                database, "last_export", map.lastExport.map { Data(String($0.timeIntervalSince1970).utf8) })
        }
    }

    // MARK: - Metadata

    public func metadata(_ key: String) throws -> Data? {
        try queue.read { database in try Self.meta(database, key) }
    }

    public func setMetadata(_ key: String, _ value: Data?) throws {
        try queue.write { database in try Self.setMeta(database, key, value) }
    }

    static func meta(_ database: Database, _ key: String) throws -> Data? {
        try Data.fetchOne(database, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    static func metaDate(_ database: Database, _ key: String) throws -> Date? {
        guard let data = try meta(database, key), let seconds = Double(utf8(data)) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    static func setMeta(_ database: Database, _ key: String, _ value: Data?) throws {
        if let value {
            try database.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
        } else {
            try database.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }
}

/// UTF-8 text of encoded JSON (always valid UTF-8).
func utf8(_ data: Data) -> String {
    String(bytes: data, encoding: .utf8) ?? ""
}
