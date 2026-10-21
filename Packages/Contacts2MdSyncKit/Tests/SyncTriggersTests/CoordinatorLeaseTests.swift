import Foundation
import SyncEngine
import SyncTestSupport
import SyncTriggers
import Testing
import VaultIndex

/// The coordinator's trigger clock, as the lease's `SyncClock`.
struct ManualSyncClock: SyncClock {
    let clock: ManualTriggerClock
    var now: Date { clock.now }
}

@Suite("SyncCoordinator: vault lease (architecture §11, M6)")
struct CoordinatorLeaseTests {
    static let macA = DeviceIdentity(id: "a", name: "Mac A")
    static let macB = DeviceIdentity(id: "b", name: "Mac B")

    func manager(_ vault: InMemoryVault, _ device: DeviceIdentity, _ clock: ManualTriggerClock) -> LeaseManager {
        LeaseManager(fs: vault, device: device, clock: ManualSyncClock(clock: clock), settle: 0)
    }

    /// Advances one heartbeat interval once the heartbeat loop is waiting.
    func nextHeartbeat(_ clock: ManualTriggerClock) async {
        _ = await eventually { clock.sleeperCount > 0 }
        clock.advance(by: LeaseManager.heartbeatInterval)
    }

    @Test("heartbeats every 5 minutes while alive, also during a long run; shutdown releases the lease")
    func heartbeats() async throws {
        let vault = InMemoryVault()
        let clock = ManualTriggerClock()
        let lease = manager(vault, Self.macA, clock)
        _ = try lease.acquire(otherDevicesKnown: false)
        let runner = FakeRunner(clock: clock)
        let coordinator = SyncCoordinator(runner: runner, clock: clock, leaseKeeper: LeaseKeeper(manager: lease))
        await coordinator.start([])
        await nextHeartbeat(clock)
        #expect(await eventually { lease.read()?.heartbeatAt == clock.now })
        // A run that takes longer than the heartbeat interval keeps the lease fresh.
        runner.hold()
        await coordinator.syncNow()
        #expect(await eventually { runner.running == 1 })
        await nextHeartbeat(clock)
        #expect(await eventually { lease.read()?.heartbeatAt == clock.now })
        #expect(await coordinator.leaseStatus?.role == .leader)
        runner.release()
        await coordinator.shutdown()
        #expect(lease.read()?.releasedAt == clock.now)
        #expect(await coordinator.leaseStatus?.role == .vacant)
    }

    @Test("a run while another device leads is reported as following, with the dry-run summary")
    func following() async {
        let clock = ManualTriggerClock()
        let runner = FakeRunner(clock: clock)
        let coordinator = SyncCoordinator(runner: runner, clock: clock)
        let log = await StatusLog(coordinator)
        let lease = VaultLease(
            deviceID: "b", deviceName: "Mac B", acquiredAt: clock.now, heartbeatAt: clock.now,
            expiresAt: clock.now.addingTimeInterval(1200))
        let holder = LeaseHolder(lease, now: clock.now)
        var summary = SyncRunSummary(
            kind: .manual, startedAt: clock.now, finishedAt: clock.now, appleFull: true, appleRead: "full")
        summary.markdownUpdated = 2
        runner.script([.following(holder, summary)])
        await coordinator.syncNow()
        await coordinator.waitUntilIdle()
        #expect(await eventually { log.contains { $0 == .following(device: holder) } })
        #expect(await coordinator.lastFollowerSummary == summary)
        #expect(await coordinator.lastSummary == nil)
        #expect(runner.requests.count == 1)  // no retry: the next trigger checks again
        await coordinator.shutdown()
    }

    @Test("the leader's lease lapses: the follower notices on its heartbeat and takes over with a catch-up run")
    func takeOverWhenLeaderStops() async throws {
        let vault = InMemoryVault()
        let clock = ManualTriggerClock()
        let leaseB = manager(vault, Self.macB, clock)
        _ = try leaseB.acquire(otherDevicesKnown: true)
        let runner = FakeRunner(clock: clock)
        let coordinator = SyncCoordinator(
            runner: runner, clock: clock, leaseKeeper: LeaseKeeper(manager: manager(vault, Self.macA, clock)))
        let log = await StatusLog(coordinator)
        await coordinator.start([])
        await nextHeartbeat(clock)
        #expect(await eventually { await coordinator.leaseStatus?.role == .follower })
        #expect(
            await eventually {
                log.contains { if case .following(let holder) = $0 { holder.deviceName == "Mac B" } else { false } }
            })
        #expect(runner.requests.isEmpty)
        _ = try leaseB.release()
        await nextHeartbeat(clock)
        #expect(await eventually { runner.requests.contains { $0.kind == .launch } })
        #expect(runner.requests.first?.reasons == ["Mac B stopped leading; taking over"])
        await coordinator.shutdown()
    }

    @Test("Take Over makes this device the leader and syncs at once")
    func explicitTakeOver() async throws {
        let vault = InMemoryVault()
        let clock = ManualTriggerClock()
        _ = try manager(vault, Self.macB, clock).acquire(otherDevicesKnown: true)
        let runner = FakeRunner(clock: clock)
        let coordinator = SyncCoordinator(
            runner: runner, clock: clock, leaseKeeper: LeaseKeeper(manager: manager(vault, Self.macA, clock)))
        let status = try await coordinator.takeOver()
        #expect(status?.role == .leader)
        #expect(await eventually { runner.requests.map(\.kind) == [.manual] })
        #expect(manager(vault, Self.macA, clock).read()?.deviceID == "a")
        #expect(await coordinator.releaseLease()?.role == .vacant)
        await coordinator.shutdown()
    }
}
