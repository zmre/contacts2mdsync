import ContactModel
import Foundation
import SyncEngine
import SyncStateDB
import Testing
import VaultIndex

@Suite("SQLite device state")
struct GRDBSyncStateStoreTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sampleMap() -> (UUID, RecordMap) {
        let id = UUID()
        var map = RecordMap(lastExport: Self.start)
        map[id] = RecordBinding(
            unifiedID: "SYNTH-1",
            cards: [
                BoundCard(
                    id: "i1", containerID: "icloud", accountKind: .iCloud, firstSeen: Self.start, stampSeen: true),
                BoundCard(id: "g1", containerID: "google", accountKind: .google, firstSeen: Self.start + 60),
            ],
            path: "People/Ann.md",
            base: RecordBase(fields: ["emails": ["a@example.com"], "name": ["ann one"]]))
        map[UUID()] = RecordBinding(unifiedID: nil, cards: [], path: "Inbox/B.md")
        return (id, map)
    }

    @Test("records, cards, merge base and field hashes round-trip; saves replace")
    func records() throws {
        let store = try GRDBSyncStateStore()
        #expect(try store.load() == RecordMap())
        let (id, map) = sampleMap()
        try store.save(map)
        let loaded = try store.load()
        #expect(loaded == map)
        #expect(loaded[id]?.cards.map(\.isTrusted) == [true, false])
        var smaller = RecordMap()
        smaller[id] = map[id]
        try store.save(smaller)
        #expect(try store.load().records.count == 1)
        #expect(map[id]?.base?.fieldHashes.count == 2)
    }

    @Test("file cache, pending queue, decisions, groups, problems, sessions and metadata round-trip")
    func everythingElse() throws {
        let store = try GRDBSyncStateStore()
        let cache = [
            "a.md": FileCacheEntry(
                path: "a.md", modificationDate: Self.start, size: 3, sha256: "ab", kind: .contact, syncID: UUID(),
                title: "A", aliases: ["Al"]),
            "b.md": FileCacheEntry(
                path: "b.md", modificationDate: Self.start, size: 4, sha256: "cd", kind: .problem, problem: "bad",
                contactRelated: true),
        ]
        try store.saveFileCache(cache)
        #expect(try store.loadFileCache() == cache)

        let items: [ReviewItem] = [
            .missingFile(title: "X", id: UUID(), lastPath: "x.md"), .undownloaded(paths: ["y.md"]),
        ]
        let pending = PendingReviews().replacing(with: items, at: Self.start)
        try store.savePending(pending)
        #expect(try store.loadPending() == pending)
        let later = try store.loadPending().replacing(with: [items[1]], at: Self.start + 100)
        #expect(later.items.first?.firstSeen == Self.start)  // first-seen kept

        let decision = Decision(
            kind: .adopt, createdAt: Self.start, device: DeviceIdentity(id: "d", name: "D"),
            contacts: [ContactRef(cardIDs: ["c"], title: "C")], path: "p.md", itemID: "match-1")
        try store.saveDecisionMirror([decision])
        #expect(try store.loadDecisionMirror() == [decision])

        let groups = [GroupBinding(groupID: "g", containerID: "icloud", name: "Family", tag: "family")]
        try store.saveGroups(groups)
        #expect(try store.loadGroups() == groups)

        try store.markProblemsReported(["sha1": "j.md"])
        #expect(try store.reportedProblemHashes() == ["sha1"])

        let session = SessionRecord(
            startedAt: Self.start, finishedAt: Self.start + 2, command: "export", trigger: "CLI", deviceID: "d",
            created: 3)
        try store.appendSession(session)
        try store.appendSession(
            SessionRecord(
                startedAt: Self.start + 9, finishedAt: Self.start + 9, command: "plan", trigger: "GUI", deviceID: "d"))
        #expect(try store.recentSessions(limit: 5).map(\.command) == ["plan", "export"])

        try store.setMetadata("history_token", Data([1, 2]))
        #expect(try store.metadata("history_token") == Data([1, 2]))
        try store.setMetadata("history_token", nil)
        #expect(try store.metadata("history_token") == nil)
    }

    @Test("on disk: persists across opens and imports an M1 records.json once")
    func legacyImport() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "c2m-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
            {"lastExport":"2027-01-15T08:00:00Z","records":{"\(id.uuidString.lowercased())":\
            {"cardIDs":["c1:icloud"],"path":"Inbox/A.md","unifiedID":"c1:icloud"}}}
            """
        try Data(json.utf8).write(to: directory.appending(path: "records.json"))
        let store = try GRDBSyncStateStore.open(directory: directory, now: Self.start)
        #expect(try store.load()[id]?.cardIDs == ["c1:icloud"])
        #expect(try store.load().lastExport == Self.start)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "records.json.imported").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "records.json").path))
        let reopened = try GRDBSyncStateStore.open(directory: directory)
        #expect(try reopened.load()[id]?.path == "Inbox/A.md")
    }
}
