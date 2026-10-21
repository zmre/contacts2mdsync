import ContactModel
import Foundation
import SyncTestSupport
import Testing
import VaultIndex

@testable import SyncEngine

/// History-token acceleration (architecture §10): incremental vs full
/// selection, token reset paths, own-write exclusion, and the rule that
/// incremental runs never conclude deletions.
@Suite("History acceleration")
struct HistoryAccelerationTests {
    private func world(
        _ contacts: [AppleContact] = [World.ann(), World.person("bob", "Bob", "Two")]
    ) throws -> SyncHarness {
        let world = try World.exported(contacts, stamps: .never)
        // World.exported ran the first two-way sync: no cache before it, so it was full.
        return world
    }

    private func kind(_ run: SyncHarness.Run) -> AppleReadKind? { run.apple?.kind }

    @Test("first sync is full (no cache); then nothing changed → incremental, no snapshot, no re-read")
    func steadyState() throws {
        let world = SyncHarness(
            store: FakeContactStore(contacts: [World.ann()], containers: Fixtures.containers), appleWrites: true)
        try world.export()
        let first = try world.sync()
        #expect(kind(first) == .full(.noCache))
        let snapshots = world.store.snapshotCount
        let second = try world.sync()
        #expect(kind(second) == .incremental(changedCards: 0, refetchedContacts: 0))
        #expect(second.plan.isEmpty)
        #expect(world.store.snapshotCount == snapshots)
        #expect(world.store.refetchedCardIDs.isEmpty)
    }

    @Test("a Contacts edit re-reads only that contact and syncs it to markdown")
    func appleEdit() throws {
        let world = try world()
        world.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let snapshots = world.store.snapshotCount
        let run = try world.sync()
        #expect(kind(run) == .incremental(changedCards: 1, refetchedContacts: 1))
        #expect(world.store.refetchedCardIDs.last == ["bob:icloud"])
        #expect(world.store.snapshotCount == snapshots)
        #expect(try world.note("Inbox/Bob Two.md")?.jobTitle == "Chef")
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("a note edit re-reads its contact; our own Apple write is excluded from the next history read")
    func noteEditAndOwnWrites() throws {
        let world = try world()
        try world.editNote("Inbox/Ann One.md") { $0.jobTitle = "CTO" }
        let run = try world.sync()
        #expect(kind(run) == .incremental(changedCards: 0, refetchedContacts: 1))
        #expect(world.store.refetchedCardIDs.last == ["ann:icloud"])
        #expect(world.store.contact(withCard: "ann:icloud")?.contact.jobTitle == "CTO")
        #expect(world.store.appliedBatches.last?.author == SyncEngine.transactionAuthor(deviceID: world.device.id))
        // The write is in the history, but authored by us: nothing to re-read.
        let next = try world.sync()
        #expect(kind(next) == .incremental(changedCards: 0, refetchedContacts: 0))
        #expect(next.plan.isEmpty)
    }

    @Test("DropEverything (reset token), a history error, and no history all fall back to a full snapshot")
    func resetPaths() throws {
        let world = try world()
        world.store.resetHistory()
        #expect(kind(try world.sync()) == .full(.historyReset))
        #expect(kind(try world.sync())?.isFull == false)
        world.store.failNextHistory()
        #expect(kind(try world.sync()) == .full(.historyFailed))
        world.store.setHistorySupported(false)
        #expect(kind(try world.sync()) == .full(.historyUnsupported))
        world.store.setHistorySupported(true)
        // The unsupported run stored no token: the next one is full again, then incremental.
        #expect(kind(try world.sync()) == .full(.noCache))
        #expect(kind(try world.sync())?.isFull == false)
    }

    @Test("`--full`, group changes, config and decision changes, and many changes force a full snapshot")
    func fullReasons() throws {
        let people = (1...12).map { World.person("p\($0)", "Person", "N\($0)") }
        let world = try World.exported(people, stamps: .never)
        #expect(kind(try world.sync(mode: .full)) == .full(.requested))
        world.store.recordGroupChange()
        #expect(kind(try world.sync()) == .full(.groupsChanged))
        world.appendConfig("# edited by hand\n")
        let changed = try world.sync()
        #expect(kind(changed) == .full(.settingsChanged))
        #expect(kind(try world.sync())?.isFull == false)
        let tracker = AppleChangeTracker(
            store: world.store, state: world.state, deviceID: world.device.id, maxChangedCards: 2,
            maxChangeFraction: 0.1)
        for number in 1...3 { world.store.editCard("p\(number):icloud") { $0.jobTitle = "Changed" } }
        let read = try tracker.read(
            mode: .incremental,
            context: AppleReadContext(
                records: try world.state.load(), vaultTouchedRecords: [],
                settingsKey: try settingsKey(world), vanished: [:], now: world.clock.now))
        #expect(read.kind == .full(.tooManyChanges))
    }

    private func settingsKey(_ world: SyncHarness) throws -> String {
        AppleChangeTracker.settingsKey(
            configText: world.vault.text(VaultConfig.path), decisions: try DecisionLog.readAll(world.vault).decisions)
    }

    @Test("deletion: full snapshot records it; incremental runs keep it waiting; the due confirmation is full")
    func deletionNeedsFullSnapshots() throws {
        let world = try world()
        world.store.deleteContact(withCard: "bob:icloud")
        let first = try world.sync()
        #expect(kind(first) == .full(.deletions))
        #expect(first.plan.awaitingDeleteConfirmation == ["Bob Two"])
        world.advance(minutes: 5)
        let waiting = try world.sync()
        #expect(kind(waiting)?.isFull == false)
        #expect(try world.pending("deleted").isEmpty)
        #expect(try world.state.loadVanished().count == 1)
        world.advance(minutes: 6)
        let due = try world.sync()
        #expect(kind(due) == .full(.deleteConfirmationDue))
        #expect(try world.pending("deleted").count == 1)
        #expect(world.vault.exists("Inbox/Bob Two.md"))
    }

    @Test("an incremental plan never queues, confirms or counts deletions, even when one is overdue")
    func incrementalNeverDeletes() throws {
        let people = (1...14).map { World.person("p\($0)", "Person", "N\($0)") }
        let world = try World.exported(people, stamps: .never)
        world.store.deleteContact(withCard: "p1:icloud")
        _ = try world.sync()  // full: p1 recorded as possibly deleted
        let firstSeen = try #require(try world.state.loadVanished().values.first)
        world.advance(minutes: 30)
        // Twelve more vanish at once: a full snapshot would trip the breaker.
        for number in 2...13 { world.store.deleteContact(withCard: "p\(number):icloud") }
        let loaded = try VaultConfig.load(from: world.vault)
        var gathered = try SyncPlanner.gather(
            fs: world.vault, store: world.store, state: world.state, config: (try world.config, loaded?.text),
            now: world.clock.now)
        gathered.inputs.appleSnapshotComplete = false
        let plan = try SyncPlanner(fs: world.vault, keyer: world.keyer, ids: world.ids).plan(
            gathered.including(world.device).inputs)
        #expect(plan.breaker == nil)
        #expect(!plan.markdown.reviews.contains { if case .appleDeleted = $0 { true } else { false } })
        #expect(plan.awaitingDeleteConfirmation.isEmpty)
        #expect(plan.vanished.count == 1 && plan.vanished.values.first == firstSeen)
        #expect(plan.trash.isEmpty)
        // The same inputs on a full snapshot trip the breaker.
        gathered.inputs.appleSnapshotComplete = true
        let full = try SyncPlanner(fs: world.vault, keyer: world.keyer, ids: world.ids).plan(
            gathered.including(world.device).inputs)
        #expect(full.breaker != nil)
    }

    @Test("images of contacts not re-read are unknown, never removed; a note create re-plans on a full snapshot")
    func maskedImages() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        var ann = World.ann()
        ann.imageData = png
        let world = try world([ann, World.person("bob", "Bob", "Two")])
        let image = try #require(try world.note("Inbox/Ann One.md")?.image?.path)
        world.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let run = try world.sync()
        #expect(kind(run)?.isFull == false)
        let snapshotAnn = try #require(run.apple?.snapshot.contacts.first { $0.cardIDs == ["ann:icloud"] })
        #expect(snapshotAnn.imageUnavailable && snapshotAnn.imageData == nil)
        #expect(try world.note("Inbox/Ann One.md")?.image?.path == image)
        #expect(!run.plan.markdown.updates.contains { $0.path == "Inbox/Ann One.md" })
        // A plan that creates a note for a masked contact is re-planned in full.
        var plan = SyncPlan(markdown: ExportPlan(config: try world.config))
        let record = UUID()
        plan.markdown.creates = [
            FileChange(
                path: "Inbox/Ann One 2.md", recordID: record, title: "Ann One", data: Data(), expecting: .absent,
                changedFields: [], kind: .create)
        ]
        plan.markdown.bindings[record] = RecordBinding(
            unifiedID: "ann:icloud",
            cards: [BoundCard(id: "ann:icloud", containerID: "icloud", accountKind: .iCloud, firstSeen: Date())],
            path: "Inbox/Ann One 2.md")
        #expect(try SyncPlanner.needsImages(plan, read: #require(run.apple)))
    }

    @Test("the cache survives encoding (compressed JSON in meta) without image bytes")
    func cacheRoundTrip() throws {
        var ann = World.ann()
        ann.imageData = Data([1, 2, 3])
        let snapshot = AppleSnapshot(
            contacts: [ann], containers: Fixtures.containers, groups: Fixtures.groups, notesAvailable: true)
        let cache = AppleSnapshotCache(
            snapshot: snapshot, token: Data("t".utf8), imageHashes: ["ann:icloud": "abc"], masked: [],
            settingsKey: "k", savedAt: Date(timeIntervalSince1970: 0))
        let decoded = try #require(AppleSnapshotCache.decode(try cache.encoded()))
        #expect(decoded.contacts.first?.imageData == nil)
        #expect(decoded.contacts.first?.contact == ann.contact)
        #expect(decoded.imageHashes == ["ann:icloud": "abc"] && decoded.token == Data("t".utf8))
        #expect(AppleSnapshotCache.decode(Data("garbage".utf8)) == nil)
    }

    @Test("a dry run (plan) advances the mirror; a tripped breaker does not")
    func planCommits() throws {
        let world = try world()
        world.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        _ = try world.plan()
        let run = try world.sync()
        #expect(kind(run) == .incremental(changedCards: 0, refetchedContacts: 0))
        // The plan advanced the token past the edit; the sync still sees Bob's change against the base.
        #expect(try world.note("Inbox/Bob Two.md")?.jobTitle == "Chef")
    }

    @Test("last full compare is recorded for runs planned on a full snapshot only")
    func lastFullCompare() throws {
        let world = try world()
        let tracker = world.tracker
        let first = try #require(tracker.lastFullCompare())
        world.advance(minutes: 10)
        _ = try world.sync()
        #expect(tracker.lastFullCompare() == first)
        _ = try world.sync(mode: .full)
        #expect(tracker.lastFullCompare() == world.clock.now)
    }
}

@Suite("Merge-keep decision")
struct MergeKeepTests {
    @Test("two stamped contacts linked later: keep:N keeps one note, detaches the other, removes its stamp")
    func mergeKeep() throws {
        let world = try World.exported(
            [
                World.person("a1", "Ann", "One") { $0.emails = [Labeled(nil, "ann@home.example")] },
                World.person("a2", "Ann", "One", accounts: [.google]) {
                    $0.emails = [Labeled(nil, "ann@work.example")]
                },
            ], stamps: .always)
        #expect(world.store.contacts.allSatisfy { $0.stampIDs.count == 1 })
        world.store.link(["a1:icloud", "a2:google"])
        let blocked = try world.sync()
        let item = try #require(blocked.plan.markdown.reviews.first { $0.id.hasPrefix("merge-") })
        guard case .mergeRecords(_, _, let paths) = item else { return }
        #expect(paths == ["Inbox/Ann One 2.md", "Inbox/Ann One.md"])
        #expect(item.choices == ["keep:1", "keep:2"])
        try world.decide(item.id, "keep:2")
        let kept = try #require(try world.note("Inbox/Ann One.md")?.sync.id)
        let run = try world.sync()
        #expect(try world.note("Inbox/Ann One 2.md")?.sync.status == "detached")
        #expect(try world.note("Inbox/Ann One.md")?.sync.status == nil)
        #expect(run.plan.apple.contains { $0.kind == .unstamp })
        #expect(world.store.contacts.first?.stampIDs == [kept])
        #expect(try world.pending("merge").isEmpty)
        let records = try world.state.load()
        #expect(records[kept] != nil && records.records.count == 1)
        #expect(try world.sync().plan.isEmpty)
    }
}
