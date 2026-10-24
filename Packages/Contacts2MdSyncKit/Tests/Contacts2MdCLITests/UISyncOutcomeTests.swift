import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Synchronization
import Testing
import VaultIndex

/// Sync Now outcomes, the Overview and Activity, and banners.
extension UISyncTests {
    @Test("before the first sync on this Mac, Sync Now runs the first export")
    func firstExport() throws {
        let harness = CLIHarness(store: smallStore())
        let reader = reader(harness)
        let summary = try #require(try reader.sync().summary)
        #expect(summary.wasExport)
        #expect(summary.markdown.created == 3)
        #expect(try data(reader).hasSynced)
    }

    @Test("apple writes off: markdown synced, changes held, banner points to Settings; Overview counts")
    func heldBanner() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let plan = try reader.plan()
        let sync = try #require(plan.sync)
        #expect(sync.hold == .appleWritesDisabled)
        #expect(sync.changedInMarkdown == 1)
        #expect(sync.held == 1)
        #expect(sync.appleWrites == 0)
        let data = try data(reader)
        let banners = UIBanner.banners(
            status: data.status, plan: sync, outcome: nil, deviceID: data.device.id, now: harness.clock.now)
        #expect(banners == [.appleWritesDisabled(held: 1, kinds: "1 update")])
        #expect(
            banners.first?.message
                == "1 change for Apple Contacts (1 update) is waiting because writing to Contacts is turned off.")
        let overview = UIOverview(data: data, plan: plan, counts: UIReviewCounts(), sessionStart: .distantPast)
        #expect(overview.changedInContacts == 1)
        #expect(overview.changedInMarkdown == 1)
        #expect(overview.appleHeld == 1)
        #expect(overview.health == .changesWaiting(1))

        let summary = try #require(try reader.sync().summary)
        #expect(summary.markdown == UIChangeCounts(updated: 1))
        #expect(summary.apple.isZero)
        #expect(summary.held == 1)
        #expect(summary.hold == .appleWritesDisabled)
        #expect(harness.store.appliedBatches.isEmpty)
    }

    @Test("blast radius: banner offers Apply Anyway; approving the count writes them")
    func blastRadius() throws {
        let people = (1...27).map { number in
            Fixtures.contact("p\(number)") { $0.name = PersonName(given: "Person", family: "N\(number)") }
        }
        let harness = CLIHarness.exported(FakeContactStore(contacts: people, containers: Fixtures.containers))
        let reader = reader(harness)
        try enableWrites(reader)
        for number in 1...27 {
            let lastName = "last_name: N\(number)\n"
            harness.editNote("Inbox/Person N\(number).md", lastName, with: lastName + "job_title: Staff\n")
        }
        let held = try #require(try reader.sync().summary)
        #expect(held.hold == .blastRadius(count: 27, limit: 25))
        #expect(held.held == 27)
        let sync = try #require(try reader.plan().sync)
        let data = try data(reader)
        let banners = UIBanner.banners(
            status: data.status, plan: sync, outcome: nil, deviceID: data.device.id, now: harness.clock.now)
        #expect(banners == [.blastRadius(count: 27, limit: 25)])
        #expect(banners.first?.severity == .warning)
        let approved = try #require(try reader.sync(UISyncRequest(maxAppleChanges: 27)).summary)
        #expect(approved.apple == UIChangeCounts(updated: 27))
        #expect(approved.hold == nil)
        #expect(harness.store.appliedOperations.count == 27)
    }

    @Test("mass-vanish breaker: Sync Now reports it, nothing written; Resume Anyway queues deletions")
    func breaker() throws {
        let people = (1...12).map { number in
            Fixtures.contact("p\(number)") { $0.name = PersonName(given: "Person", family: "N\(number)") }
        }
        let harness = CLIHarness.exported(FakeContactStore(contacts: people, containers: Fixtures.containers))
        let reader = reader(harness)
        harness.store.replaceContacts([])
        let outcome = try reader.sync()
        guard case .breaker(let trip) = outcome else {
            Issue.record("expected the breaker, got \(outcome)")
            return
        }
        #expect(trip.side == "apple" && trip.vanished == 12)
        let data = try data(reader)
        let banners = UIBanner.banners(
            status: data.status, plan: nil, outcome: outcome, deviceID: data.device.id, now: harness.clock.now)
        #expect(banners == [.breaker(trip)])
        #expect(banners.first?.severity == .error)
        #expect(
            banners.first?.message
                == "Sync paused: 12 contacts disappeared from Contacts since the last sync "
                + "(e.g. Person N1, Person N10, …). Is iCloud signed in? Nothing was written.")
        #expect(trip.paths.count == 12 && trip.paths.first == "Inbox/Person N1.md")
        #expect(harness.vault.exists("Inbox/Person N1.md"))
        #expect(try reader.sync(UISyncRequest(allowMassVanish: true)).summary != nil)
    }

    @Test("banner wording: breaker names the missing notes; held changes say writing is off, by kind")
    func bannerWording() {
        let paths = ["People/Jane Doe.md", "People/John Roe.md", "People/Max Moe.md"]
        let markdown = UIBanner.breaker(BreakerTrip(side: "markdown", vanished: 22, total: 2447, paths: paths))
        #expect(
            markdown.message
                == "Sync paused: 22 notes disappeared from the notes folder since the last sync "
                + "(e.g. Jane Doe.md, John Roe.md, …). Is the folder available? Nothing was written.")
        let one = UIBanner.breaker(BreakerTrip(side: "markdown", vanished: 1, total: 4, paths: ["Jane Doe.md"]))
        #expect(
            one.message
                == "Sync paused: 1 note disappeared from the notes folder since the last sync (e.g. Jane Doe.md). "
                + "Is the folder available? Nothing was written.")
        let held = UIBanner.appleWritesDisabled(held: 24, kinds: "15 deletions, 9 updates")
        #expect(
            held.message
                == "24 changes for Apple Contacts (15 deletions, 9 updates) are waiting because writing to "
                + "Contacts is turned off.")
        #expect(!held.message.contains("Settings"))
    }

    @Test("Sync Now and checks report their phases with last run's counts as they start")
    func progressPhases() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        let phases = Mutex<[SyncPhase]>([])
        _ = try reader.sync { phase in phases.withLock { $0.append(phase) } }
        let names = phases.withLock { $0 }.map(\.name)
        #expect(
            names == ["waiting-for-lock", "scanning", "scanning-notes", "reading-contacts", "planning", "writing"])
        let checked = Mutex<[SyncPhase]>([])
        _ = try reader.plan { phase in checked.withLock { $0.append(phase) } }
        let counted = checked.withLock { $0 }
        #expect(counted.contains(.scanningNotes(count: 3)))
        #expect(counted.contains { if case .readingContacts(let cards?) = $0 { cards > 0 } else { false } })
        #expect(!counted.contains(.writing))
    }

    @Test("another device holds the lease: Waiting banner; Take Over syncs")
    func lease() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        let other = LeaseManager(
            fs: harness.vault, device: DeviceIdentity(id: "device-b", name: "Mac B"), clock: harness.clock, settle: 0)
        _ = try other.takeOver()  // the export made this Mac the leader
        let outcome = try reader.sync()
        guard case .leaseHeldElsewhere(let lease) = outcome else {
            Issue.record("expected the lease outcome, got \(outcome)")
            return
        }
        #expect(lease.deviceName == "Mac B")
        let data = try data(reader)
        let expected = UIBanner.waitingForDevice(name: "Mac B", since: lease.acquiredAt, expires: lease.expiresAt)
        // From the outcome right away, and from the stored lease after a relaunch.
        #expect(
            UIBanner.banners(status: nil, plan: nil, outcome: outcome, deviceID: data.device.id, now: harness.clock.now)
                == [expected])
        #expect(
            UIBanner.banners(
                status: data.status, plan: nil, outcome: nil, deviceID: data.device.id, now: harness.clock.now)
                == [expected])
        // An expired lease is no reason to wait.
        #expect(
            UIBanner.banners(
                status: data.status, plan: nil, outcome: nil, deviceID: data.device.id,
                now: lease.expiresAt.addingTimeInterval(1)
            ).isEmpty)
        #expect(try reader.sync(UISyncRequest(takeOver: true)).summary != nil)
        let mine = try #require(try self.data(reader).status.lease)
        #expect(mine.deviceID == data.device.id)
        #expect(
            UIBanner.banners(
                status: try self.data(reader).status, plan: nil, outcome: nil, deviceID: data.device.id,
                now: harness.clock.now
            ).isEmpty)
    }

    @Test("a run already in progress on this Mac: banner, nothing done")
    func localLock() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        let vaultID = try #require(try VaultConfig.load(from: harness.vault)?.config.vaultID.uuidString.lowercased())
        let lock = try #require(
            try LocalLock.acquire(at: harness.stateDirectory.appending(path: "\(vaultID)/sync.lock"), wait: 0))
        defer { lock.release() }
        let outcome = try reader.sync()
        #expect(outcome == .localRunInProgress)
        #expect(
            UIBanner.banners(status: nil, plan: nil, outcome: outcome, deviceID: "x", now: harness.clock.now)
                == [.localRunInProgress])
    }

    @Test("identity: several devices without stamps → banner, until stamping is on")
    func identity() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        _ = try reader.sync()
        try DeviceRecord.write(
            DeviceRecord(deviceID: "device-b", deviceName: "Mac B", lastSync: harness.clock.now, summary: ""),
            fs: harness.vault)
        let plan = try reader.plan()
        var data = try data(reader)
        #expect(data.status.deviceCount == 2)
        let banners = UIBanner.banners(
            status: data.status, plan: plan.sync, outcome: nil, deviceID: data.device.id, now: harness.clock.now)
        #expect(banners.map(\.id) == ["identity"])
        try enableWrites(reader, stamp: true)
        data = try self.data(reader)
        #expect(
            UIBanner.banners(
                status: data.status, plan: try reader.plan().sync, outcome: nil, deviceID: data.device.id,
                now: harness.clock.now
            ).isEmpty)
    }

    @Test("Activity and This Session: app and CLI syncs split Apple / markdown with held counts")
    func activity() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        _ = try reader.sync()
        harness.clock.advance(60)
        harness.store.editCard("cy:icloud") { $0.jobTitle = "Chef" }
        _ = harness.sync()
        let data = try data(reader)
        let rows = UIActivityRow.rows(data.sessions, device: data.device, details: data.sessionDetails)
        let syncs = rows.filter { $0.command == "sync" }
        #expect(syncs.count == 2)
        let cli = try #require(syncs.first)
        #expect(cli.trigger == "CLI")
        // M5 sessions record the split (`SessionRecord.sides`), whoever ran them.
        #expect(cli.contacts == UIChangeCounts())
        #expect(cli.markdown == UIChangeCounts(updated: 1))
        #expect(cli.combined == nil)
        #expect(cli.held == 1)
        let app = try #require(syncs.last)
        #expect(app.trigger == "Manual")
        #expect(app.markdown == UIChangeCounts(updated: 1))
        #expect(app.contacts == UIChangeCounts())
        #expect(app.held == 1)
        #expect(app.holdReason == "Apple writes off")
        let overview = UIOverview(data: data, plan: nil, counts: UIReviewCounts(), sessionStart: .distantPast)
        #expect(overview.session?.held == 2)
        #expect(overview.session?.markdown.updated ?? 0 >= 1)
        let last = UIOverview(data: data, plan: nil, counts: UIReviewCounts(), sessionStart: .distantFuture)
        #expect(last.session?.heading == "Last Sync")
    }
}
