import ContactModel
import Foundation
import SyncEngine
import Testing
import VaultIndex

@testable import SyncStateDB

@Suite("Device state: change log, reset and backup (schema v3)")
struct SyncStateV3Tests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000.75)

    static func stores() throws -> [any SyncStateStore] { [try GRDBSyncStateStore(), InMemorySyncStateStore()] }

    @Test("a run's change log round-trips by its log id and is capped")
    func changeLog() throws {
        for store in try Self.stores() {
            let id = UUID()
            let changes = [
                SessionChange(
                    side: .markdown, verb: "updated", title: "Ann One", path: "Inbox/Ann One.md", fields: ["job_title"],
                    recordID: id),
                SessionChange(side: .apple, verb: "created", title: "Bob Two"),
            ]
            try store.appendSessionChanges(changes, logID: "first")
            #expect(try store.sessionChanges(logID: "first") == changes)
            #expect(try store.sessionChanges(logID: "other").isEmpty)

            let many = (0..<(SessionChange.perSessionLimit + 20)).map {
                SessionChange(side: .markdown, verb: "created", title: "N\($0)")
            }
            try store.appendSessionChanges(many, logID: "many")
            #expect(try store.sessionChanges(logID: "many").count == SessionChange.perSessionLimit)
            for offset in 0..<SessionChange.sessionLimit {
                try store.appendSessionChanges(
                    [SessionChange(side: .apple, verb: "updated", title: "x")], logID: "run-\(offset)")
            }
            #expect(try store.sessionChanges(logID: "first").isEmpty)  // oldest dropped
            #expect(try store.sessionChanges(logID: "run-0").count == 1)
        }
    }

    @Test("sessions in the same second keep separate change logs; dry runs keep none")
    func sameSecond() throws {
        for store in try Self.stores() {
            let start = Self.start
            let export = SessionRecord(
                startedAt: start, finishedAt: start, command: "export", trigger: "CLI", deviceID: "d")
            try store.appendSession(export, changes: [SessionChange(side: .markdown, verb: "created", title: "A")])
            try store.appendSession(
                SessionRecord(startedAt: start, finishedAt: start, command: "plan", trigger: "CLI", deviceID: "d"),
                changes: [])
            try store.appendSession(
                SessionRecord(startedAt: start, finishedAt: start, command: "sync", trigger: "CLI", deviceID: "d"),
                changes: [SessionChange(side: .apple, verb: "updated", title: "B")])
            let sessions = try store.recentSessions(limit: 3)
            #expect(sessions.map(\.command) == ["sync", "plan", "export"])
            #expect(try sessions.map { try store.sessionChanges(of: $0).map(\.title) } == [["B"], [], ["A"]])
            #expect(sessions.map(\.changeCount) == [1, 0, 1])
        }
    }

    @Test("reset forgets sync state, keeps history, the decision mirror and the kept metadata keys")
    func reset() throws {
        for store in try Self.stores() {
            let id = UUID()
            try store.save(
                RecordMap(records: [id: RecordBinding(unifiedID: "u", cards: [], path: "a.md")], lastExport: Self.start)
            )
            try store.saveFileCache([
                "a.md": FileCacheEntry(
                    path: "a.md", modificationDate: Self.start, size: 1, sha256: "x", kind: .contact, syncID: id,
                    title: "A")
            ])
            try store.saveGroups([GroupBinding(groupID: "g", containerID: "c", name: "Family", tag: "family")])
            try store.setMetadata("apple_cache", Data([1]))
            try store.setMetadata("ui_sync_sessions", Data([2]))
            try store.appendSession(
                SessionRecord(
                    startedAt: Self.start, finishedAt: Self.start, command: "sync", trigger: "CLI", deviceID: "d"),
                changes: [SessionChange(side: .apple, verb: "updated", title: "A")])

            try store.resetSyncState(keepingMetadata: ["ui_sync_sessions"])
            let map = try store.load()
            #expect(map.records.isEmpty && map.lastExport == nil)
            #expect(try store.loadFileCache().isEmpty)
            #expect(try store.loadGroups().isEmpty)
            #expect(try store.metadata("apple_cache") == nil)
            #expect(try store.metadata("ui_sync_sessions") == Data([2]))
            #expect(try store.recentSessions(limit: 10).count == 1)
            let session = try #require(try store.recentSessions(limit: 1).first)
            #expect(try store.sessionChanges(of: session).count == 1)
        }
    }

    @Test("clearCaches forgets the file cache and the Apple mirror, nothing else")
    func clearCaches() throws {
        let store = try GRDBSyncStateStore()
        let id = UUID()
        try store.save(RecordMap(records: [id: RecordBinding(unifiedID: nil, cards: [], path: "a.md")]))
        try store.saveFileCache([
            "a.md": FileCacheEntry(
                path: "a.md", modificationDate: Self.start, size: 1, sha256: "x", kind: .contact, syncID: id, title: "A"
            )
        ])
        try store.setMetadata("apple_cache", Data([1]))
        try store.clearCaches()
        #expect(try store.loadFileCache().isEmpty)
        #expect(try store.metadata("apple_cache") == nil)
        #expect(try store.load().records.count == 1)
    }

    @Test("backup writes a readable copy and never overwrites one")
    func backup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "c2m-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBSyncStateStore.open(directory: directory)
        let id = UUID()
        try store.save(RecordMap(records: [id: RecordBinding(unifiedID: nil, cards: [], path: "a.md")]))
        let copy = directory.appending(path: "backups/state-1.sqlite")
        try store.backup(to: copy)
        #expect(try GRDBSyncStateStore(url: copy).load().records.keys.contains(id))
        #expect(throws: (any Error).self) { try store.backup(to: copy) }
    }
}
