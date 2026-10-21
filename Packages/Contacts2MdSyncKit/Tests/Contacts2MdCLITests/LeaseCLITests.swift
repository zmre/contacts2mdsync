import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("contacts2md lease / status: multi-device (M6)")
struct LeaseCLITests {
    static let macB = DeviceIdentity(id: "device-b", name: "Mac B")

    func other(_ harness: CLIHarness) -> LeaseManager {
        LeaseManager(fs: harness.vault, device: Self.macB, clock: harness.clock, settle: 0)
    }

    @Test("status shows the role, the holder's heartbeat, staleness and the other devices")
    func status() throws {
        let harness = CLIHarness.exported()
        #expect(harness.sync().code == 0)
        let mine = harness.run(["status", "--root", "/vault"])
        #expect(mine.out.contains("role=leader  heartbeat="))
        _ = try other(harness).takeOver()
        try DeviceRecord.write(
            DeviceRecord(deviceID: Self.macB.id, deviceName: "Mac B", lastSync: harness.clock.now, summary: "x"),
            fs: harness.vault)
        harness.clock.advance(11 * 60)
        let following = harness.run(["status", "--root", "/vault"])
        #expect(following.out.contains("lease    Mac B until"))
        #expect(following.out.contains("role=follower"))
        #expect(following.out.contains("STALE (no heartbeat for over 10 min)"))
        #expect(following.out.contains("device   Mac B  last sync"))
        let json = harness.run(["status", "--root", "/vault", "--json"])
        #expect(json.out.contains("\"lease_role\""))
    }

    @Test("lease take-over and release")
    func takeOverAndRelease() throws {
        let harness = CLIHarness.exported()
        _ = try other(harness).acquire(otherDevicesKnown: true)
        let shown = harness.run(["lease", "--root", "/vault"])
        #expect(shown.code == 0 && shown.out.contains("role=follower"))
        let taken = harness.run(["lease", "take-over", "--root", "/vault"])
        #expect(taken.code == 0, "\(taken.out)\(taken.err)")
        #expect(taken.out.contains("took     lease  this Mac now leads syncing for this vault"))
        #expect(other(harness).read()?.deviceName == "Test Mac")
        let released = harness.run(["lease", "release", "--root", "/vault"])
        #expect(released.out.contains("released lease  another device may lead now"))
        #expect(released.out.contains("(released)  role=vacant"))
        #expect(harness.run(["lease", "release", "--root", "/vault"]).out.contains("does not hold the lease"))
        guard case .acquired = try other(harness).acquire(otherDevicesKnown: true) else {
            Issue.record("a released lease is free for any device")
            return
        }
        #expect(harness.run(["lease", "bogus", "--root", "/vault"]).code == 64)
        #expect(Contacts2MdCLI.isCLIInvocation(["lease", "take-over"]))
    }

    @Test("sync as a follower: exit 0, an info line, a dry run recorded for review, nothing written")
    func followerSync() throws {
        let harness = CLIHarness.exported()
        _ = try other(harness).acquire(otherDevicesKnown: true)
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        harness.vault.resetWrites()
        let run = harness.sync()
        #expect(run.code == 0)
        #expect(run.out.contains("note     following Mac B"))
        #expect(run.out.contains("this Mac only checks (dry run, nothing written)"))
        #expect(harness.vault.writes.isEmpty)
        #expect(harness.store.appliedOperations.isEmpty)
        #expect(try harness.stateStore().recentSessions(limit: 1).first?.command == "follow")
    }
}
