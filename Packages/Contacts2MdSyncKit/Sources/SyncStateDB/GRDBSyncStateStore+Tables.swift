internal import Foundation
internal import GRDB
public import SyncEngine
public import VaultIndex

/// File cache, pending queue, decision mirror, groups, reported problems and
/// sessions (see `GRDBSyncStateStore`).
extension GRDBSyncStateStore {
    // MARK: - File cache

    public func loadFileCache() throws -> [String: FileCacheEntry] {
        try queue.read { database in
            var cache: [String: FileCacheEntry] = [:]
            let rows = try Row.fetchCursor(database, sql: "SELECT * FROM file_cache")
            while let row = try rows.next() {
                let aliasesJSON: String? = row["aliases_json"]
                let syncID: String? = row["sync_id"]
                let entry = FileCacheEntry(
                    path: row["path"], modificationDate: Date(timeIntervalSince1970: row["mtime"]), size: row["size"],
                    sha256: row["sha256"], kind: FileCacheEntry.Kind(rawValue: row["kind"]) ?? .problem,
                    syncID: syncID.flatMap(UUID.init(uuidString:)), title: row["title"],
                    aliases: try aliasesJSON.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [],
                    problem: row["problem"], contactRelated: row["contact_related"])
                cache[entry.path] = entry
            }
            return cache
        }
    }

    public func saveFileCache(_ cache: [String: FileCacheEntry]) throws {
        try queue.write { database in
            try database.execute(sql: "DELETE FROM file_cache")
            for entry in cache.values {
                let aliases =
                    entry.aliases.isEmpty
                    ? nil : utf8(try JSONEncoder().encode(entry.aliases))
                try database.execute(
                    sql: """
                        INSERT INTO file_cache
                        (path, mtime, size, sha256, kind, sync_id, title, aliases_json, problem, contact_related)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        entry.path, entry.modificationDate.timeIntervalSince1970, entry.size, entry.sha256,
                        entry.kind.rawValue, entry.syncID?.uuidString.lowercased(), entry.title, aliases,
                        entry.problem, entry.contactRelated,
                    ])
            }
        }
    }

    // MARK: - Pending reviews

    public func loadPending() throws -> PendingReviews {
        try queue.read { database in
            var items: [PendingReview] = []
            let rows = try Row.fetchCursor(database, sql: "SELECT * FROM pending ORDER BY position")
            while let row = try rows.next() {
                let json: String = row["json"]
                // An item this version cannot read (written by a newer one) is dropped.
                guard let item = try? JSONDecoder().decode(ReviewItem.self, from: Data(json.utf8)) else { continue }
                items.append(PendingReview(item: item, firstSeen: Date(timeIntervalSince1970: row["first_seen"])))
            }
            return PendingReviews(computedAt: try Self.metaDate(database, "pending_computed_at"), items: items)
        }
    }

    public func savePending(_ pending: PendingReviews) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try queue.write { database in
            try database.execute(sql: "DELETE FROM pending")
            for (position, entry) in pending.items.enumerated() {
                try database.execute(
                    sql:
                        """
                        INSERT OR REPLACE INTO pending (item_id, kind, json, first_seen, position)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        entry.id, String(entry.id.prefix { $0 != "-" }),
                        utf8(try encoder.encode(entry.item)),
                        entry.firstSeen.timeIntervalSince1970, position,
                    ])
            }
            try Self.setMeta(
                database, "pending_computed_at", pending.computedAt.map { Data(String($0.timeIntervalSince1970).utf8) })
        }
    }

    // MARK: - Decisions mirror

    public func loadDecisionMirror() throws -> [Decision] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try queue.read { database in
            try String.fetchAll(database, sql: "SELECT json FROM decisions ORDER BY created_at, id").compactMap {
                try? decoder.decode(Decision.self, from: Data($0.utf8))
            }
        }
    }

    public func saveDecisionMirror(_ decisions: [Decision]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        try queue.write { database in
            try database.execute(sql: "DELETE FROM decisions")
            for decision in decisions {
                try database.execute(
                    sql:
                        """
                        INSERT OR REPLACE INTO decisions (id, device_id, kind, created_at, json)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        decision.id.uuidString.lowercased(), decision.deviceID, decision.kindName,
                        decision.createdAt.timeIntervalSince1970,
                        utf8(try encoder.encode(decision)),
                    ])
            }
        }
    }

    // MARK: - Groups

    public func loadGroups() throws -> [GroupBinding] {
        try queue.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM groups ORDER BY name, group_id").map { row in
                GroupBinding(
                    groupID: row["group_id"], containerID: row["container_id"], name: row["name"], tag: row["tag"])
            }
        }
    }

    public func saveGroups(_ groups: [GroupBinding]) throws {
        try queue.write { database in
            try database.execute(sql: "DELETE FROM groups")
            for group in groups {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO groups (group_id, container_id, name, tag) VALUES (?, ?, ?, ?)",
                    arguments: [group.groupID, group.containerID, group.name, group.tag])
            }
        }
    }

    // MARK: - Reported problems

    public func reportedProblemHashes() throws -> Set<String> {
        try queue.read { database in Set(try String.fetchAll(database, sql: "SELECT sha256 FROM reported_problems")) }
    }

    public func markProblemsReported(_ problems: [String: String]) throws {
        try queue.write { database in
            for (sha, path) in problems {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO reported_problems (sha256, path) VALUES (?, ?)",
                    arguments: [sha, path])
            }
        }
    }

    // MARK: - Unapplyable writes

    public func loadUnapplyable() throws -> [UnapplyableEntry] {
        try queue.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT * FROM unapplyable ORDER BY record_id, card_id, field")
            return rows.compactMap { row in
                let record: String = row["record_id"]
                guard let id = UUID(uuidString: record) else { return nil }
                return UnapplyableEntry(
                    recordID: id, cardID: row["card_id"], field: row["field"], attempted: row["attempted"],
                    observed: row["observed"])
            }
        }
    }

    public func saveUnapplyable(_ entries: [UnapplyableEntry]) throws {
        try queue.write { database in
            try database.execute(sql: "DELETE FROM unapplyable")
            for entry in entries {
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO unapplyable
                        (record_id, card_id, field, value_hash, attempted, observed) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        entry.recordID.uuidString.lowercased(), entry.cardID, entry.field,
                        FieldHash.of([entry.attempted]), entry.attempted, entry.observed,
                    ])
            }
        }
    }

    // MARK: - Sessions

    public func appendSession(_ session: SessionRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO sessions (started_at, json) VALUES (?, ?)",
                arguments: [
                    session.startedAt.timeIntervalSince1970,
                    utf8(try encoder.encode(session)),
                ])
            // Keep the last 500 runs.
            try database.execute(
                sql: "DELETE FROM sessions WHERE id NOT IN (SELECT id FROM sessions ORDER BY id DESC LIMIT 500)")
        }
    }

    public func recentSessions(limit: Int) throws -> [SessionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try queue.read { database in
            try String.fetchAll(database, sql: "SELECT json FROM sessions ORDER BY id DESC LIMIT ?", arguments: [limit])
                .compactMap { try? decoder.decode(SessionRecord.self, from: Data($0.utf8)) }
        }
    }
}
