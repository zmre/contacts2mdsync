import ContactModel
import Foundation
import SyncTestSupport
import Testing
import VaultIndex

@testable import SyncEngine

/// What the mass-vanish breaker counts (architecture §9): only records that
/// are newly gone. Deliberate deletions the user already decided about,
/// records missing in an earlier run, and a forgotten account's contacts
/// never trip it; a folder or account that suddenly disappears still does.
@Suite("Mass-vanish breaker: what counts")
struct BreakerAccountingTests {
    static func people(_ count: Int) -> [AppleContact] {
        (1...count).map { World.person("p\($0)", "Person", "Number\($0)") }
    }

    static func path(_ number: Int) -> String { "Inbox/Person Number\(number).md" }

    /// Deletes `numbers` from the folder two at a time (never enough to trip
    /// the breaker), syncing after each pair so each is queued in Deletions.
    static func deleteOverTime(_ world: SyncHarness, _ numbers: ClosedRange<Int>) throws {
        for pair in stride(from: numbers.lowerBound, through: numbers.upperBound, by: 2) {
            for number in pair...min(pair + 1, numbers.upperBound) { world.vault.remove(path(number)) }
            let run = try world.sync()
            #expect(run.plan.breaker == nil, "pair \(pair)")
        }
    }

    /// Decides `choice` for every pending "note deleted" item (Set All).
    static func decideAllMissing(_ world: SyncHarness, _ choice: String = "delete-contact") throws -> Int {
        let items = try world.pending("missing")
        for item in items { try world.decide(item.id, choice) }
        return items.count
    }

    @Test(
        "deliberate deletes decided Delete Contact, apple_writes off: no breaker later; held, applied once on",
        arguments: [false, true])
    func decidedDeletesHeld(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported(Self.people(30), appleWrites: false)
            try Self.deleteOverTime(world, 1...18)
            #expect(try Self.decideAllMissing(world) == 18)
            for attempt in 1...4 {
                let run = try world.sync()
                #expect(run.plan.breaker == nil, "run \(attempt)")
                #expect(run.result != nil)
                #expect(run.plan.appleHold == .appleWritesDisabled)
                #expect(run.plan.apple.filter { $0.kind == .delete }.count == 18)
                #expect(world.store.appliedBatches.isEmpty)
                world.advance(minutes: 15)
            }
            #expect(try world.pending("missing").isEmpty)
            #expect(try world.state.loadKnownMissingNotes().count == 18)
            #expect(world.store.contact(withCard: "p1:icloud") != nil)

            try world.setConfig { $0.appleWrites = true }
            // With stamps the 12 remaining contacts' sync IDs join the deletes (over the limit).
            let applied = try world.sync(SyncOptions(maxAppleChanges: 30))
            #expect(applied.plan.breaker == nil)
            #expect(applied.result?.apple.filter { $0.kind == .delete }.count == 18)
            #expect(world.store.contact(withCard: "p1:icloud") == nil)
            #expect(world.store.contact(withCard: "p18:icloud") == nil)
            #expect(world.store.contact(withCard: "p19:icloud") != nil)
            #expect(try world.state.load().records.count == 12)
            #expect(try MergeTableTests.syncToFixpoint(world).plan.breaker == nil)
            #expect(try world.state.loadKnownMissingNotes().isEmpty)
        }
    }

    @Test("a sudden vanish of 22 undecided notes still trips, also next to decided held deletes")
    func suddenVanishTrips() throws {
        let world = try World.exported(Self.people(60), appleWrites: false)
        try Self.deleteOverTime(world, 1...6)
        #expect(try Self.decideAllMissing(world) == 6)
        #expect(try world.sync().plan.breaker == nil)
        let gone = (7...28).map(Self.path)
        for path in gone { world.vault.remove(path) }
        let run = try world.sync()
        let trip = try #require(run.plan.breaker)
        #expect(trip.side == "markdown" && trip.vanished == 22)
        #expect(trip.paths == gone.sorted())
        let listed = gone.sorted().prefix(10).joined(separator: ", ")
        #expect(trip.message.contains("Missing notes: \(listed), … (+12 more)"))
        #expect(run.result == nil)
        // Still tripped next run: a stopped run neither queues them nor remembers them.
        let again = try world.sync()
        #expect(again.plan.breaker?.vanished == 22)
        #expect(try world.pending("missing").isEmpty)
    }

    @Test("breaker-stopped run, then the folder comes back: no residue (no queue, nothing remembered)")
    func folderRestored() throws {
        let world = try World.exported(Self.people(30))
        let texts = Dictionary(uniqueKeysWithValues: world.notePaths.map { ($0, world.vault.text($0) ?? "") })
        for path in world.notePaths { world.vault.remove(path) }
        let planned = try world.plan().plan
        #expect(planned.breaker?.vanished == 30)
        #expect(try world.sync().plan.breaker?.vanished == 30)
        #expect(try world.pending("missing").isEmpty)
        #expect(try world.state.loadKnownMissingNotes().isEmpty)
        for (path, text) in texts { world.writeNote(path, text) }
        let back = try world.sync()
        #expect(back.plan.breaker == nil)
        #expect(back.plan.markdown.reviews.filter(\.needsDecision).isEmpty)
        #expect(back.plan.apple.isEmpty)
        #expect(try world.pending("missing").isEmpty)
        #expect(try world.state.loadKnownMissingNotes().isEmpty)
        #expect(world.store.appliedBatches.isEmpty)
    }

    @Test("notes missing in an earlier run (undecided) are not counted again")
    func earlierMissingNotCounted() throws {
        let world = try World.exported(Self.people(30))
        try Self.deleteOverTime(world, 1...14)
        #expect(try world.pending("missing").count == 14)
        let run = try world.sync()
        #expect(run.plan.breaker == nil)
        // Even when the queue is cleared, the remembered set keeps them known.
        try world.state.savePending(PendingReviews())
        #expect(try world.sync().plan.breaker == nil)
        #expect(try world.state.loadKnownMissingNotes().count == 14)
    }

    @Test("Forget Google + decided markdown deletes + apple_writes off: no breaker; forget applies")
    func forgetWithDecidedDeletes() throws {
        let world = try World.exported(
            [AccountWorld.sam(), World.ann()] + AccountWorld.ginas(12) + Self.people(20), appleWrites: false)
        try Self.deleteOverTime(world, 1...12)
        #expect(try Self.decideAllMissing(world) == 12)
        #expect(try world.sync().plan.breaker == nil)
        world.store.removeContainer("google")
        let away = try world.sync()
        #expect(away.plan.breaker == nil)
        try world.decide("account-missing:google", "forget")
        let run = try world.sync()
        #expect(run.plan.breaker == nil)
        #expect(run.result != nil)
        #expect(run.plan.accounts.isEmpty)
        #expect(try world.pending("deleted").count == 12)
        #expect(try world.note("Inbox/Sam Lee.md")?.phones.isEmpty == true)
        #expect(AccountGuard.load(from: world.state)?.unavailable.isEmpty == true)
        #expect(run.plan.apple.filter { $0.kind == .delete }.count == 12)
        world.advance(minutes: 15)
        let next = try world.sync(mode: .full)
        #expect(next.plan.breaker == nil)
        #expect(next.plan.accounts.isEmpty)
    }

    @Test("decided deletes held by the blast radius: no breaker on later runs; approving applies them")
    func blastRadiusHeldDeletes() throws {
        let world = try World.exported(Self.people(40), stamps: .never)
        try Self.deleteOverTime(world, 1...30)
        #expect(try Self.decideAllMissing(world) == 30)
        for attempt in 1...3 {
            let run = try world.sync()
            #expect(run.plan.breaker == nil, "run \(attempt)")
            #expect(run.plan.appleHold == .blastRadius(count: 30, limit: 25))
        }
        let approved = try world.sync(SyncOptions(maxAppleChanges: 30))
        #expect(approved.result?.apple.filter { $0.kind == .delete }.count == 30)
        #expect(try world.state.load().records.count == 10)
    }

    @Test("contacts deleted in Contacts over time, decided Restore with apple_writes off: no Apple breaker")
    func appleDecidedRestoreHeld() throws {
        let world = try World.exported(Self.people(30), appleWrites: false, stamps: .never)
        for pair in stride(from: 1, through: 13, by: 2) {
            world.store.deleteContact(withCard: "p\(pair):icloud")
            world.store.deleteContact(withCard: "p\(pair + 1):icloud")
            #expect(try world.sync().plan.breaker == nil)
            world.advance(minutes: 11)
            #expect(try world.sync().plan.breaker == nil)
        }
        let items = try world.pending("deleted")
        #expect(items.count == 14)
        for item in items { try world.decide(item.id, "restore") }
        for attempt in 1...3 {
            let run = try world.sync()
            #expect(run.plan.breaker == nil, "run \(attempt)")
            #expect(run.plan.apple.filter { $0.kind == .create }.count == 14)
            #expect(run.plan.appleHold == .appleWritesDisabled)
            world.advance(minutes: 11)
        }
        // A sudden Apple vanish still trips.
        for number in 15...30 { world.store.deleteContact(withCard: "p\(number):icloud") }
        let trip = try #require(try world.sync().plan.breaker)
        #expect(trip.side == "apple" && trip.vanished == 16)
        #expect(trip.paths.first == Self.path(15))
    }
}

@Suite("Apple change kinds summary")
struct AppleKindSummaryTests {
    static func change(_ kind: AppleChangeKind) -> AppleRecordChange {
        AppleRecordChange(recordID: UUID(), title: "x", kind: kind, operations: [], fields: [])
    }

    @Test("\"15 deletions, 9 updates\": fixed order, singular, empty kinds left out")
    func summary() {
        let changes =
            Array(repeating: Self.change(.update), count: 9) + Array(repeating: Self.change(.delete), count: 15)
        #expect(AppleRecordChange.kindSummary(changes) == "15 deletions, 9 updates")
        let mixed = [Self.change(.create), Self.change(.stamp)]
        #expect(AppleRecordChange.kindSummary(mixed) == "1 new contact, 1 sync ID")
        #expect(AppleRecordChange.kindSummary([]).isEmpty)
    }

    @Test("breaker message lists up to 10 paths")
    func breakerMessage() {
        let paths = (1...12).map { "Inbox/N\($0).md" }.sorted()
        let trip = BreakerTrip(side: "markdown", vanished: 12, total: 100, paths: paths)
        #expect(trip.message.hasSuffix("Missing notes: \(paths.prefix(10).joined(separator: ", ")), … (+2 more)"))
        #expect(!BreakerTrip(side: "markdown", vanished: 12, total: 100).message.contains("Missing notes"))
    }
}
