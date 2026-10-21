import ContactModel
import Foundation
import SyncEngine
import Testing

@testable import SyncStateDB

@Suite("Device state: M3 additions (schema v2)")
struct SyncStateV2Tests {
    @Test("unapplyable writes, vanished records and confirmed cards round-trip")
    func roundTrip() throws {
        let store = try GRDBSyncStateStore()
        let id = UUID()
        let entries = [
            UnapplyableEntry(recordID: id, cardID: "g1", field: "job_title", attempted: "CTO", observed: "Eng"),
            UnapplyableEntry(recordID: id, cardID: "*", field: "tags|family", attempted: "+", observed: "absent"),
        ]
        try store.saveUnapplyable(entries)
        #expect(Set(try store.loadUnapplyable()) == Set(entries))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveVanished([id: when])
        #expect(try store.loadVanished() == [id: when])
        try store.saveVanished([:])
        #expect(try store.loadVanished().isEmpty)

        var base = RecordBase(fields: ["job_title": ["CTO"]])
        base.version = 2
        base.labels = ["emails": ["a@b.example": "home"]]
        base.body = "notes"
        let card = BoundCard(
            id: "g1", containerID: "google", accountKind: .google, firstSeen: when, stampSeen: false, confirmed: true)
        try store.save(RecordMap(records: [id: RecordBinding(unifiedID: "u", cards: [card], path: "a.md", base: base)]))
        let loaded = try #require(try store.load()[id])
        #expect(loaded.cards.first?.confirmed == true && loaded.cards.first?.isTrusted == true)
        #expect(loaded.base == base)
    }

    @Test("a v1 database migrates: existing rows read with defaults")
    func migration() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "c2m-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBSyncStateStore.open(directory: directory)
        let id = UUID()
        try store.save(
            RecordMap(
                records: [
                    id: RecordBinding(
                        unifiedID: nil,
                        cards: [BoundCard(id: "c", containerID: "icloud", accountKind: .iCloud, firstSeen: Date())],
                        path: "x.md")
                ]))
        let reopened = try GRDBSyncStateStore.open(directory: directory)
        #expect(try reopened.load()[id]?.cards.first?.confirmed == false)
        #expect(try reopened.loadUnapplyable().isEmpty)
    }
}
