import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// One Mac in a multi-device test: its vault (or replica), its Contacts
/// (or replica), its own device state, and its view of the lease.
struct SimMac {
    let harness: SyncHarness
    let lease: LeaseManager

    init(
        store: FakeContactStore, vault: InMemoryVault, device: DeviceIdentity, clock: TestClock, stamps: Bool,
        idStart: UInt64
    ) {
        harness = SyncHarness(
            store: store, vault: vault, appleWrites: true, stampContacts: stamps, device: device, clock: clock,
            ids: SequentialIDGenerator(start: idStart))
        lease = LeaseManager(fs: vault, device: device, clock: clock, settle: 0)
    }

    /// Takes (or keeps) the lease and syncs; a follower only plans (dry run).
    @discardableResult
    func run() throws -> (role: LeaseRole, plan: SyncPlan) {
        switch try lease.acquire(otherDevicesKnown: true) {
        case .acquired: (.leader, try harness.sync().plan)
        case .heldElsewhere: (.follower, try harness.plan().plan)
        }
    }

    /// Notes (not `.c2mdsync/`) this Mac wrote.
    var noteWrites: [String] { harness.vault.writes.filter { !$0.hasPrefix(".") } }
}

@Suite("Multi-device: joining, handover, followers (M6)")
struct MultiDeviceSimulationTests {
    static let macA = DeviceIdentity(id: "device-a", name: "Mac A")
    static let macB = DeviceIdentity(id: "device-b", name: "Mac B")

    static func people() -> [AppleContact] {
        [
            World.ann(),
            World.person("bob", "Bob", "Two") { $0.emails = [Labeled(nil, "bob@two.example")] },
            World.person("cy", "Cy", "Three") { $0.phones = [Labeled("mobile", "+1 415 555 0133")] },
        ]
    }

    // MARK: Identity when a device joins (item 6)

    @Test("stamps on: a joining device binds every contact by stamp; first import creates and writes nothing")
    func joinWithStamps() throws {
        let first = try World.exported(Self.people(), stamps: .always)
        #expect(first.store.contacts.allSatisfy { !$0.stampIDs.isEmpty })
        let operations = first.store.appliedOperations.count
        let paths = first.notePaths
        first.vault.resetWrites()
        // Contacts renamed Ann since: only the stamp can still tell who she is.
        first.store.editCard("ann:icloud") { $0.name = PersonName(given: "Annie", family: "Uno") }
        let second = SimMac(
            store: first.store, vault: first.vault, device: Self.macB, clock: first.clock, stamps: true, idStart: 9000)
        let joined = try second.harness.export()
        #expect(joined.creates.isEmpty && joined.reviews.isEmpty, "\(joined.reviews.map(\.summary))")
        #expect(try second.harness.state.load().records.count == 3)
        let synced = try second.harness.sync()
        #expect(synced.plan.markdown.creates.isEmpty && synced.plan.apple.isEmpty)
        #expect(synced.plan.identityWarning == nil)
        #expect(first.store.appliedOperations.count == operations)
        #expect(first.notePaths == paths)
        #expect(try first.note("Inbox/Ann One.md")?.name.given == "Annie")
    }

    @Test("stamps off: a joining device re-finds notes by strong keys and titles; zero creates, identity warning")
    func joinWithoutStamps() throws {
        let first = try World.exported(Self.people(), stamps: .never)
        let paths = first.notePaths
        first.vault.resetWrites()
        let second = SimMac(
            store: first.store, vault: first.vault, device: Self.macB, clock: first.clock, stamps: false, idStart: 9000)
        let joined = try second.harness.export()
        #expect(joined.creates.isEmpty, "\(joined.creates.map(\.path))")
        let synced = try second.harness.sync()
        #expect(synced.plan.markdown.creates.isEmpty && synced.plan.apple.isEmpty)
        #expect(synced.plan.identityWarning?.contains("2 devices share this vault") == true)
        #expect(try second.harness.state.load().records.count == 3)
        #expect(first.notePaths == paths)
        #expect(try second.harness.sync().plan.isEmpty)
    }

    @Test("stamps off, ambiguous: two same-name contacts never get duplicate notes on the joining device")
    func joinAmbiguous() throws {
        let twins = [
            World.person("sam1", "Sam", "Lee") { $0.jobTitle = "Baker" },
            World.person("sam2", "Sam", "Lee") { $0.jobTitle = "Pilot" },
        ]
        // Same-name contacts cluster: declared different people first.
        let first = try World.exported(twins, stamps: .never, distinct: ["sam1:icloud", "sam2:icloud"])
        let paths = first.notePaths
        #expect(paths.count == 2)
        let second = SimMac(
            store: first.store, vault: first.vault, device: Self.macB, clock: first.clock, stamps: false, idStart: 9000)
        let joined = try second.harness.export()
        #expect(joined.creates.isEmpty)
        #expect(!joined.reviews.isEmpty)
        let synced = try second.harness.sync()
        #expect(synced.plan.markdown.creates.isEmpty && synced.plan.apple.isEmpty)
        #expect(synced.plan.markdown.needsReview)
        #expect(first.notePaths == paths)
        #expect(first.store.contacts.count == 2)
    }

    // MARK: Handover and followers (items 2, 5)

    @Test("handover with a stale per-device base writes nothing: both sides changed the same way")
    func handoverWithStaleBase() throws {
        let first = try World.exported(Self.people(), stamps: .never)
        let macA = SimMac(
            store: first.store, vault: first.vault, device: Self.macA, clock: first.clock, stamps: false, idStart: 1)
        let macB = SimMac(
            store: first.store, vault: first.vault, device: Self.macB, clock: first.clock, stamps: false, idStart: 9000)
        try macB.harness.export()
        try macB.harness.sync()
        #expect(try macA.run().role == .leader)
        // Several rounds led by A while B only follows (B's base goes stale).
        for round in 1...3 {
            first.store.editCard("ann:icloud") { $0.jobTitle = "Title \(round)" }
            try first.editNote("Inbox/Bob Two.md") { $0.emails.append(Labeled("work", "bob\(round)@work.example")) }
            first.advance(minutes: 6)
            #expect(try macA.run().role == .leader)
            let follower = try macB.run()
            #expect(follower.role == .follower)
        }
        #expect(World.apple(first, "ann:icloud")?.jobTitle == "Title 3")
        #expect(try macA.lease.release())
        first.vault.resetWrites()
        let operations = first.store.appliedOperations.count
        let taken = try macB.run()
        #expect(taken.role == .leader)
        #expect(taken.plan.apple.isEmpty && taken.plan.markdown.creates.isEmpty && taken.plan.markdown.updates.isEmpty)
        #expect(taken.plan.conflicts.isEmpty)
        #expect(first.store.appliedOperations.count == operations)
        #expect(macB.noteWrites.isEmpty)
    }

    @Test("a follower's review decision is carried out by the leader")
    func followerDecision() throws {
        let first = try World.exported(Self.people(), stamps: .never)
        let macA = SimMac(
            store: first.store, vault: first.vault, device: Self.macA, clock: first.clock, stamps: false, idStart: 1)
        let macB = SimMac(
            store: first.store, vault: first.vault, device: Self.macB, clock: first.clock, stamps: false, idStart: 9000)
        try macB.harness.export()
        try macB.harness.sync()
        #expect(try macA.run().role == .leader)
        try first.editNote("Inbox/Ann One.md") { $0.jobTitle = "Architect" }
        first.store.editCard("ann:icloud") { $0.jobTitle = "Director" }
        #expect(try macA.run().plan.conflicts.count == 1)
        let follower = try macB.run()
        #expect(follower.role == .follower)
        let conflict = try #require(try macB.harness.pending("conflict").first)
        first.vault.resetWrites()
        try macB.harness.decide(conflict.id, "markdown")  // B's own decision log only
        #expect(first.vault.writes == [DecisionLog.path(deviceID: Self.macB.id)])
        #expect(World.apple(first, "ann:icloud")?.jobTitle == "Director")
        let led = try macA.run()
        #expect(led.role == .leader && led.plan.conflicts.isEmpty)
        #expect(World.apple(first, "ann:icloud")?.jobTitle == "Architect")
        #expect(try first.note("Inbox/Ann One.md")?.jobTitle == "Architect")
    }

}

@Suite("Multi-device simulation: replicated iCloud Drive and Contacts with delay (M6)")
struct MultiDeviceReplicationTests {
    static let macA = MultiDeviceSimulationTests.macA
    static let macB = MultiDeviceSimulationTests.macB

    /// Two Macs, each with its own vault replica (iCloud Drive, 30 s) and
    /// Contacts replica (iCloud contacts, 60 s).
    struct TwoMacs {
        let clock: TestClock
        let drive: SimulatedICloud
        let contacts: SimulatedContactsCloud
        let macs: [SimMac]

        init(stamps: Bool, style: SimulatedICloud.ConflictStyle = .versions) throws {
            clock = TestClock(start: SyncHarness.start)
            drive = SimulatedICloud(clock: clock, delay: 30, style: style)
            contacts = SimulatedContactsCloud(contacts: MultiDeviceSimulationTests.people(), clock: clock, delay: 60)
            let macA = SimMac(
                store: contacts.store(0), vault: drive.vault(0), device: MultiDeviceSimulationTests.macA,
                clock: clock, stamps: stamps, idStart: 1)
            try macA.harness.export()
            #expect(try macA.run().role == .leader)
            #expect(try macA.lease.release())
            drive.flush()
            contacts.flush()
            let macB = SimMac(
                store: contacts.store(1), vault: drive.vault(1), device: MultiDeviceSimulationTests.macB,
                clock: clock, stamps: stamps, idStart: 9000)
            try macB.harness.export()
            macs = [macA, macB]
            settle()
        }

        /// Lets iCloud deliver everything pending (both delays pass).
        func settle(minutes: Double = 2) {
            contacts.propagate()  // notice local Contacts edits now; they arrive after the delay
            clock.advance(minutes * 60)
            contacts.propagate()
            drive.propagate()
        }

        /// Contact notes on a replica, by path, with their text.
        func notes(_ mac: Int) -> [String: String] {
            Dictionary(
                uniqueKeysWithValues: macs[mac].harness.notePaths.map { ($0, drive.vault(mac).text($0) ?? "") })
        }
    }

    @Test(
        "alternating leaders converge: no duplicate notes or contacts, no conflicted copies", arguments: [false, true])
    func alternatingLeaders(stamps: Bool) throws {
        let world = try TwoMacs(stamps: stamps)
        for round in 0..<6 {
            let leader = round % 2
            let follower = 1 - leader
            // The user edits on the follower Mac, so the change has to travel.
            if round % 2 == 0 {
                world.contacts.store(follower).editCard("ann:icloud") { $0.jobTitle = "Title \(round)" }
            } else {
                try world.macs[follower].harness.editNote("Inbox/Bob Two.md") {
                    $0.jobTitle = "Role \(round)"
                }
            }
            world.settle()
            let led = try world.macs[leader].run()
            #expect(led.role == .leader, "round \(round)")
            #expect(led.plan.conflicts.isEmpty, "round \(round): \(led.plan.conflicts.map(\.summary))")
            #expect(led.plan.markdown.creates.isEmpty && !led.plan.apple.contains { $0.kind == .create })
            world.settle()
            #expect(try world.macs[follower].run().role == .follower)
            #expect(try world.macs[leader].lease.release())
            world.settle()
        }
        // Converged: the last leader reaches a fixpoint, the other takes over and finds nothing to do.
        let last = world.macs[1]
        #expect(try last.run().role == .leader)
        world.settle()
        #expect(try last.run().plan.isEmpty)
        #expect(try last.lease.release())
        world.settle()
        world.macs[0].harness.vault.resetWrites()
        let final = try world.macs[0].run()
        #expect(
            final.role == .leader && final.plan.isEmpty,
            "\(final.plan.apple) \(final.plan.markdown.updates.map(\.path))")
        world.settle(minutes: 5)

        #expect(world.notes(0) == world.notes(1))
        #expect(world.notes(0).count == 3)  // one note per contact
        for store in world.contacts.stores { #expect(store.contacts.count == 3) }  // no duplicate contacts
        #expect(World.apple(world.macs[0].harness, "ann:icloud")?.jobTitle == "Title 4")
        #expect(World.apple(world.macs[1].harness, "ann:icloud")?.jobTitle == "Title 4")
        #expect(World.apple(world.macs[1].harness, "bob:icloud")?.jobTitle == "Role 5")
        #expect(try world.macs[0].harness.note("Inbox/Ann One.md")?.jobTitle == "Title 4")
        #expect(try world.macs[1].harness.note("Inbox/Bob Two.md")?.jobTitle == "Role 5")
        #expect(world.drive.conflicts.isEmpty, "\(world.drive.conflicts)")
        #expect(world.drive.vault(0).conflictVersions.paths.isEmpty)
    }

    @Test("lease contention over iCloud: one leader syncs, the follower writes nothing but the lease attempt")
    func contention() throws {
        let world = try TwoMacs(stamps: true)
        world.contacts.store(0).editCard("cy:icloud") { $0.jobTitle = "Pilot" }
        world.settle()
        let macA = world.macs[0]
        let macB = world.macs[1]
        let settleWait: @Sendable (TimeInterval) -> Void = { seconds in
            world.clock.advance(seconds)
            world.drive.propagate()
        }
        let leaseB = LeaseManager(
            fs: world.drive.vault(1), device: Self.macB, clock: world.clock, settle: 60, sleep: settleWait)
        let leaseA = LeaseManager(
            fs: world.drive.vault(0), device: Self.macA, clock: world.clock, settle: 60,
            sleep: { _ in _ = try? leaseB.acquire(otherDevicesKnown: true) })
        for mac in world.macs { mac.harness.vault.resetWrites() }
        _ = try leaseA.acquire(otherDevicesKnown: true)
        world.drive.flush()
        let roles = world.macs.map { $0.lease.status().role }
        #expect(roles.sorted { $0.rawValue < $1.rawValue } == [.follower, .leader])
        let leader = roles[0] == .leader ? macA : macB
        let follower = roles[0] == .leader ? macB : macA
        follower.harness.vault.resetWrites()
        let led = try leader.run()
        #expect(led.role == .leader)
        #expect(led.plan.markdown.updates.map(\.path) == ["Inbox/Cy Three.md"])
        #expect(try follower.run().role == .follower)
        #expect(follower.harness.vault.writes.isEmpty)
        world.settle()
        #expect(try follower.harness.note("Inbox/Cy Three.md")?.jobTitle == "Pilot")
        // Only the two simultaneous lease writes collided, and that was resolved.
        #expect(world.drive.conflicts.map(\.path) == [LeaseManager.path])
        #expect(world.drive.vault(0).conflictVersions.paths.isEmpty)
    }

    @Test("a user edit racing the leader's write is a real conflict: kept as a version and asked, never lost")
    func racingEdit() throws {
        let world = try TwoMacs(stamps: true)
        let macA = world.macs[0]
        let macB = world.macs[1]
        #expect(try macA.run().role == .leader)
        world.settle()
        // A rewrites Ann's note (Contacts change) while the user edits it on B before iCloud delivers.
        world.contacts.store(0).editCard("ann:icloud") { $0.jobTitle = "Director" }
        try macA.run()
        try macB.harness.editNote("Inbox/Ann One.md") { $0.department = "Research" }
        world.settle()
        #expect(world.drive.conflicts.map(\.path) == ["Inbox/Ann One.md"])
        let asked = try macA.run()
        let item = try #require(asked.plan.markdown.reviews.first { $0.id.hasPrefix("version-") })
        #expect(try macB.run().role == .follower)
        try macB.harness.decide(item.id, "keep-current")  // decided on the follower…
        world.settle()
        try macA.run()  // …carried out by the leader
        world.settle()
        #expect(world.drive.vault(0).conflictVersions.paths.isEmpty)
        #expect(try macA.run().plan.markdown.reviews.allSatisfy { !$0.id.hasPrefix("version-") })
    }

    @Test(
        "iCloud making a conflicted copy (`Ann One 2.md`) instead of a version: paused as a copied note, named as such")
    func racingEditAsConflictedCopy() throws {
        let world = try TwoMacs(stamps: true, style: .duplicateFiles)
        let macA = world.macs[0]
        let macB = world.macs[1]
        #expect(try macA.run().role == .leader)
        world.settle()
        world.contacts.store(0).editCard("ann:icloud") { $0.jobTitle = "Director" }
        try macA.run()
        try macB.harness.editNote("Inbox/Ann One.md") { $0.department = "Research" }
        world.settle()
        #expect(world.drive.conflicts.map(\.loserPath) == ["Inbox/Ann One 2.md"])
        let asked = try macA.run()
        let item = try #require(asked.plan.markdown.reviews.first { $0.id.hasPrefix("copy-") })
        #expect(item.conflictedCopyPaths == ["Inbox/Ann One 2.md"])
        #expect(asked.plan.markdown.creates.isEmpty && !asked.plan.apple.contains { $0.kind == .create })
        // Keep the original path; the copy is ignored from then on and nothing is duplicated.
        #expect(try macB.run().role == .follower)
        guard case .duplicateSyncID(_, let paths) = item, let original = paths.firstIndex(of: "Inbox/Ann One.md") else {
            Issue.record("expected a copied-note item")
            return
        }
        try macB.harness.decide(item.id, "keep:\(original + 1)")
        world.settle()
        let kept = try macA.run()
        #expect(!kept.plan.markdown.reviews.contains { $0.id == item.id })
        // The kept note (the user's edit, which iCloud made current) syncs; the other side is not lost.
        #expect(World.apple(macA.harness, "ann:icloud")?.department == "Research")
        #expect(macA.harness.vault.text("Inbox/Ann One 2.md")?.contains("job_title: Director") == true)
        #expect(world.contacts.store(0).contacts.count == 3)
    }
}
