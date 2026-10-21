import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("Lease robustness (architecture §11, M6)")
struct LeaseRobustnessTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let macA = DeviceIdentity(id: "a", name: "Mac A")
    static let macB = DeviceIdentity(id: "b", name: "Mac B")

    func manager(_ vault: any VaultFS, _ device: DeviceIdentity, _ clock: TestClock) -> LeaseManager {
        LeaseManager(fs: vault, device: device, clock: clock, settle: 0)
    }

    @Test("roles and stale detection: leader, follower with name and last heartbeat, stale, then vacant")
    func roles() throws {
        let vault = InMemoryVault()
        let clock = TestClock(start: Self.start)
        let leaseA = manager(vault, Self.macA, clock)
        let leaseB = manager(vault, Self.macB, clock)
        #expect(leaseA.status().role == .vacant)
        _ = try leaseB.acquire(otherDevicesKnown: true)
        #expect(leaseB.status().role == .leader)
        let following = leaseA.status()
        #expect(following.role == .follower && following.summary == "following Mac B")
        #expect(following.holder?.deviceName == "Mac B" && following.holder?.lastHeartbeat == Self.start)
        #expect(following.holder?.isStale == false)
        clock.advance(11 * 60)  // two heartbeats missed
        #expect(leaseA.status().holder?.isStale == true)
        #expect(leaseA.status().summary == "following Mac B (stale)")
        clock.advance(10 * 60)  // past the 20 min TTL
        #expect(leaseA.status().role == .vacant)
    }

    @Test("heartbeat renews only our own lease and never overwrites a take-over")
    func heartbeat() throws {
        let vault = InMemoryVault()
        let clock = TestClock(start: Self.start)
        let leaseA = manager(vault, Self.macA, clock)
        let leaseB = manager(vault, Self.macB, clock)
        _ = try leaseA.acquire(otherDevicesKnown: true)
        clock.advance(5 * 60)
        guard case .renewed(let renewed) = try leaseA.heartbeat() else {
            Issue.record("A leads and should renew")
            return
        }
        #expect(renewed.heartbeatAt == clock.now && renewed.expiresAt == clock.now.addingTimeInterval(20 * 60))
        #expect(renewed.acquiredAt == Self.start)
        _ = try leaseB.takeOver()
        guard case .notHeld(let current) = try leaseA.heartbeat() else {
            Issue.record("A lost the lease")
            return
        }
        #expect(current?.deviceID == "b")
        #expect(leaseA.read()?.deviceID == "b")
    }

    @Test("release frees the lease at once; a released lease is never renewed by its old holder")
    func release() throws {
        let vault = InMemoryVault()
        let clock = TestClock(start: Self.start)
        let leaseA = manager(vault, Self.macA, clock)
        let leaseB = manager(vault, Self.macB, clock)
        _ = try leaseA.acquire(otherDevicesKnown: true)
        #expect(try leaseB.release() == false)  // not B's
        #expect(try leaseA.release())
        #expect(leaseA.read()?.releasedAt == clock.now)
        #expect(leaseB.status().role == .vacant)
        guard case .notHeld = try leaseA.heartbeat() else {
            Issue.record("a released lease must stay released")
            return
        }
        guard case .acquired = try leaseB.acquire(otherDevicesKnown: true) else {
            Issue.record("B takes a released lease without --take-over")
            return
        }
    }

    @Test("lease.json conflict versions are resolved by keeping the current contents")
    func conflictVersions() throws {
        let vault = InMemoryVault()
        let clock = TestClock(start: Self.start)
        _ = try manager(vault, Self.macA, clock).acquire(otherDevicesKnown: true)
        let losing = try #require(vault.data(LeaseManager.path))
        _ = try manager(vault, Self.macB, clock).takeOver()
        vault.addConflictVersion(LeaseManager.path, losing)
        #expect(
            try manager(vault, Self.macA, clock).acquire(otherDevicesKnown: true)
                == .heldElsewhere(
                    try #require(manager(vault, Self.macB, clock).read())))
        #expect(vault.conflictVersions.paths.isEmpty)
        #expect(vault.conflictVersions.resolved.map(\.kept) == [nil])
    }

    @Test("write-wait-reread over iCloud with delay: two devices acquiring at once agree on one leader")
    func contentionOverICloud() throws {
        let clock = TestClock(start: Self.start)
        let cloud = SimulatedICloud(clock: clock, delay: 30)
        let settle: @Sendable (TimeInterval) -> Void = { seconds in
            clock.advance(seconds)
            cloud.propagate()
        }
        let leaseB = LeaseManager(fs: cloud.vault(1), device: Self.macB, clock: clock, settle: 60, sleep: settle)
        // A writes, and while A waits for iCloud, B (not seeing A's lease yet) writes too.
        let leaseA = LeaseManager(
            fs: cloud.vault(0), device: Self.macA, clock: clock, settle: 60,
            sleep: { _ in _ = try? leaseB.acquire(otherDevicesKnown: true) })
        let outcomeA = try leaseA.acquire(otherDevicesKnown: true)
        cloud.flush()
        let roleA = LeaseManager(fs: cloud.vault(0), device: Self.macA, clock: clock).status().role
        let roleB = LeaseManager(fs: cloud.vault(1), device: Self.macB, clock: clock).status().role
        #expect([roleA, roleB].sorted { $0.rawValue < $1.rawValue } == [.follower, .leader])
        if case .acquired = outcomeA { #expect(roleA == .leader) } else { #expect(roleA == .follower) }
        // iCloud kept one write and the other as a conflict version; reading resolved it.
        #expect(cloud.conflicts.map(\.path) == [LeaseManager.path])
        #expect(cloud.vault(0).conflictVersions.paths.isEmpty)
    }

    @Test("LeaseKeeper: heartbeat, take-over, release report the role")
    func keeper() throws {
        let vault = InMemoryVault()
        let clock = TestClock(start: Self.start)
        let keeper = LeaseKeeper(manager: manager(vault, Self.macA, clock))
        _ = try manager(vault, Self.macB, clock).acquire(otherDevicesKnown: true)
        #expect(keeper.heartbeat().role == .follower)
        #expect(try keeper.takeOver().role == .leader)
        clock.advance(5 * 60)
        #expect(keeper.heartbeat().lease?.heartbeatAt == clock.now)
        #expect(keeper.release().role == .vacant)
        #expect(keeper.lastStatus?.role == .vacant)
    }
}
