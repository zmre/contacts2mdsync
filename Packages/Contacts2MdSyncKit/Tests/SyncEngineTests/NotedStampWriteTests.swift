import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Stamp writes and stamp removals of cards with notes (architecture §6
/// "Write routing", spike S15): `Stamper` (`export --stamp`) and the
/// merge-keep and unlink stamp removals all go through `CardWriteRouter`,
/// so the framework's 134092 never fails them.
@Suite("Write routing: stamps and stamp removals of cards with notes")
struct NotedStampWriteTests {
    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "c2m-tests-\(UUID().uuidString)")
    }

    /// Ann's card has a note, Bob's none; exported, no stamps; the framework refuses noted cards.
    private static func exportedPair() throws -> (ExportHarness, ExportPlan) {
        let ann = World.person("ann", "Ann", "One") { $0.body = "Met at the conference.\n" }
        let bob = World.person("bob", "Bob", "Two")
        let store = FakeContactStore(
            contacts: [ann, bob], containers: Fixtures.containers, groups: Fixtures.groups, notesEntitled: false)
        let harness = ExportHarness(store: store)
        let (plan, _) = try harness.export()
        store.setModelsFrameworkWithoutNotesEntitlement(true)
        return (harness, plan)
    }

    private static func stamp(
        _ harness: ExportHarness, _ plan: ExportPlan, scripting: FakeCardScripting?, cardNotes: [String: Bool] = [:]
    ) throws -> (AppleWriteResult, CardWriteRouter) {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = try VCardBackup(directory: directory).backup(harness.store)
        let router = CardWriteRouter(inner: harness.store, scripting: scripting)
        let result = try Stamper.stamp(
            plan.stamps, in: router, cardNotes: cardNotes, backup: receipt, author: "com.zmre.contacts2mdsync.test")
        return (result, router)
    }

    private static func stamped(_ store: FakeContactStore) -> Set<String> {
        Set(store.contacts.flatMap(\.cards).filter { $0.stampID != nil }.map(\.id))
    }

    @Test("Stamper: a card known to have a note is stamped through Contacts.app; the other through the framework")
    func stamperKnownNotes() throws {
        let (harness, plan) = try Self.exportedPair()
        let scripting = FakeCardScripting(store: harness.store)
        let (result, router) = try Self.stamp(
            harness, plan, scripting: scripting, cardNotes: ["ann:icloud": true, "bob:icloud": false])
        #expect(result.failed.isEmpty && result.held.isEmpty)
        #expect(Self.stamped(harness.store) == ["ann:icloud", "bob:icloud"])
        #expect(harness.store.rejectedForNote.isEmpty)
        #expect(harness.store.scriptedOperations.map(\.cardID) == ["ann:icloud"])
        #expect(router.log.scriptedApplied == 1 && router.log.retriedAfterRejection == 0)
        #expect(scripting.availabilityChecks == 0, "every note known: permission never asked")
    }

    @Test("Stamper: note unknown and not permitted → framework first; 134092 → held, not failed")
    func stamperUnknownHeld() throws {
        let (harness, plan) = try Self.exportedPair()
        let scripting = FakeCardScripting(store: harness.store, permission: .notDetermined)
        let (result, router) = try Self.stamp(harness, plan, scripting: scripting)
        #expect(result.failed.isEmpty)
        #expect(result.held.map(\.operation.cardID) == ["ann:icloud"])
        #expect(result.held.first?.reason == CardWriteRouter.permissionReason)
        #expect(harness.store.rejectedForNote.map(\.cardID) == ["ann:icloud"])
        #expect(router.log.retriedAfterRejection == 1)
        #expect(Self.stamped(harness.store) == ["bob:icloud"])
    }

    @Test("Stamper: note unknown, no stale 'no note' trap: a refused card is retried through Contacts.app")
    func stamperStaleHintRetried() throws {
        let (harness, plan) = try Self.exportedPair()
        let scripting = FakeCardScripting(store: harness.store)
        // A stale mirror said Ann had no note.
        let (result, router) = try Self.stamp(
            harness, plan, scripting: scripting, cardNotes: ["ann:icloud": false, "bob:icloud": false])
        #expect(result.failed.isEmpty && result.held.isEmpty)
        #expect(router.log.retriedAfterRejection == 1)
        #expect(Self.stamped(harness.store) == ["ann:icloud", "bob:icloud"])
        #expect(harness.store.scriptedNotes()["ann:icloud"] == .some("Met at the conference.\n"), "note intact")
    }

    @Test("Stamper: no scripting in this build: noted cards are held")
    func stamperNoScripting() throws {
        let (harness, plan) = try Self.exportedPair()
        let (result, _) = try Self.stamp(harness, plan, scripting: nil, cardNotes: ["ann:icloud": true])
        #expect(result.failed.isEmpty)
        #expect(result.held.map(\.reason) == [CardWriteRouter.permissionReason])
        #expect(harness.store.rejectedForNote.isEmpty, "known noted: not even tried through the framework")
        #expect(Self.stamped(harness.store) == ["bob:icloud"])
    }

    @Test("CardNoteHints: unknown notes are left out, never read as 'no note'")
    func hints() {
        #expect(CardNoteHints.from(read: ["a": "text", "b": nil, "c": ""]) == ["a": true, "b": false, "c": false])
        var unknown = World.person("ann", "Ann", "One") { $0.body = "x" }
        unknown.notesUnknown = true
        #expect(CardNoteHints.from([unknown], cardIDs: ["ann:icloud"]).isEmpty)
        let snapshot = AppleSnapshot(
            contacts: [World.person("ann", "Ann", "One") { $0.body = "x" }], containers: [], groups: [],
            notesAvailable: false)
        #expect(CardNoteHints.from(snapshot, cardIDs: ["ann:icloud"]).isEmpty, "read without notes: unknown")
        #expect(CardNoteHints.fromMirror(in: InMemorySyncStateStore(), cardIDs: ["ann:icloud"]).isEmpty)
    }

    // MARK: Stamp removals in a sync

    @Test("merge-keep: removing the merged record's stamp from a card with a note goes through Contacts.app")
    func mergeKeepRemoveStamp() throws {
        let world = try World.exported(
            [
                World.person("a1", "Ann", "One") {
                    $0.emails = [Labeled(nil, "ann@home.example")]
                    $0.body = "Home note.\n"
                },
                World.person("a2", "Ann", "One", accounts: [.google]) {
                    $0.emails = [Labeled(nil, "ann@work.example")]
                    $0.body = "Work note.\n"
                },
            ], stamps: .always, distinct: ["a1:icloud", "a2:google"])
        world.store.setModelsFrameworkWithoutNotesEntitlement(true)
        let scripting = FakeCardScripting(store: world.store, permission: .notDetermined)
        world.enableCardWriteRouting(scripting)
        world.store.link(["a1:icloud", "a2:google"])
        let blocked = try world.sync()
        let item = try #require(blocked.plan.markdown.reviews.first { $0.id.hasPrefix("merge-") })
        try world.decide(item.id, "keep:2")
        let kept = try #require(try world.note("Inbox/Ann One.md")?.sync.id)

        // Headless, never asked: the removal is refused (134092), then held — not failed.
        let held = try world.sync()
        #expect(held.result?.appleFailures == [])
        #expect(held.result?.appleHeld.first?.reason == CardWriteRouter.permissionReason)
        #expect(world.store.contacts.first?.stampIDs.count == 2)

        scripting.setPermission(.granted)
        let run = try world.sync()
        #expect(run.result?.appleFailures == [] && run.result?.appleHeld == [])
        #expect(world.store.scriptedOperations.contains { if case .removeStamp = $0 { true } else { false } })
        #expect(world.store.contacts.first?.stampIDs == [kept])
        #expect(world.store.scriptedNotes()["a2:google"] == .some("Work note.\n"), "note intact")
        #expect(try world.sync().plan.apple.isEmpty)
    }

    @Test("unlink: removing the stamp of a card with a note goes through Contacts.app")
    func unlinkRemoveStamp() throws {
        let world = try World.exported(
            [World.person("bob", "Bob", "Two") { $0.body = "Bob's note.\n" }], stamps: .always)
        world.store.setModelsFrameworkWithoutNotesEntitlement(true)
        world.enableCardWriteRouting(FakeCardScripting(store: world.store))
        world.vault.remove("Inbox/Bob Two.md")
        let queued = try world.sync(SyncOptions(allowMassVanish: true))
        let item = try #require(queued.plan.markdown.reviews.first)
        try world.decide(item.id, "unlink")
        let run = try world.sync()
        #expect(run.result?.appleFailures == [] && run.result?.appleHeld == [])
        #expect(run.result?.apple.map(\.kind) == [.unstamp])
        #expect(world.store.rejectedForNote.isEmpty, "note unknown and permitted: straight to Contacts.app")
        #expect(world.store.contact(withCard: "bob:icloud")?.stampIDs.isEmpty == true)
        #expect(world.store.scriptedNotes()["bob:icloud"] == .some("Bob's note.\n"))
    }
}
