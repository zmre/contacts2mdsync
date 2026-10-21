import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import SyncTriggers
import Synchronization
import Testing
import VaultIndex

extension CLIHarness {
    /// The device state of the exported vault.
    func stateStore() throws -> any SyncStateStore {
        let config = try #require(try VaultConfig.load(from: vault)?.config)
        return try CLIEnvironment.openStateStore(
            stateDirectory.appending(path: config.vaultID.uuidString.lowercased()))
    }

    /// A runner over this harness (the app's way of syncing).
    func runner(_ registry: OwnWriteRegistry? = nil) -> VaultSyncRunner {
        VaultSyncRunner(root: URL(filePath: "/vault"), environment: environment(), ownWrites: registry, lockWait: 0)
    }
}

/// Runs `body` on its own thread (the CLI blocks; keep it off the test's executor).
func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}

/// Blocks the current (non-cooperative) thread until `body` returns.
func block<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let result = Mutex<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task {
        let value = await body()
        result.withLock { $0 = value }
        done.signal()
    }
    done.wait()
    return result.withLock { $0 }!  // swiftlint:disable:this force_unwrapping
}

/// A trigger source the test fires by hand.
final class TestSource: SyncTriggerSource {
    private let emitter = Mutex<(@Sendable (SyncTrigger) -> Void)?>(nil)

    func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) { emitter.withLock { $0 = emit } }
    func stop() { emitter.withLock { $0 = nil } }
    func fire(_ trigger: SyncTrigger) { emitter.withLock { $0 }?(trigger) }
}

@Suite("contacts2md sync: history acceleration")
struct SyncAccelerationCLITests {
    @Test("first sync reads a full snapshot; the next uses the history; --full forces a full snapshot")
    func fullThenIncremental() {
        let harness = CLIHarness.exported()
        let first = harness.sync()
        #expect(first.code == 0, "\(first.out)\(first.err)")
        #expect(first.out.contains("apple    full snapshot (no cached snapshot)"))
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let second = harness.sync()
        #expect(second.out.contains("apple    incremental: 1 changed cards, 1 contacts re-read"), "\(second.out)")
        #expect(second.out.contains("updated  md     Inbox/Bob Two.md  (job_title)"))
        let forced = harness.sync(["--full"])
        #expect(forced.out.contains("apple    full snapshot (requested)"))
        let plan = harness.run(["plan", "--root", "/vault", "--full"])
        #expect(plan.out.contains("apple    full snapshot (requested)"))
    }

    @Test("sessions record per-side counts, held changes and how Apple was read")
    func sessionSides() throws {
        let harness = CLIHarness.exported()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        _ = harness.sync()
        let session = try #require(try harness.stateStore().recentSessions(limit: 1).first)
        #expect(session.command == "sync")
        let sides = try #require(session.sides)
        #expect(sides.markdownUpdated == 1 && sides.appleUpdated == 0)
        #expect(sides.held == 1 && sides.heldReason == "apple writes disabled")
        #expect(sides.appleRead == "full")
    }
}

@Suite("VaultSyncRunner")
struct VaultSyncRunnerTests {
    let request = SyncRunRequest(SyncTrigger(.live))

    @Test("a finished run: summary counts, trigger recorded, own writes registered")
    func finished() throws {
        let harness = CLIHarness.exported()
        _ = harness.sync()
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let registry = OwnWriteRegistry()
        let phases = Mutex<[SyncPhase]>([])
        let outcome = harness.runner(registry).runNow(request) { phase in phases.withLock { $0.append(phase) } }
        guard case .finished(let summary) = outcome else {
            Issue.record("expected finished, got \(outcome)")
            return
        }
        #expect(summary.kind == .live && !summary.appleFull && summary.markdownUpdated == 1)
        #expect(summary.appleRead == "incremental: 1 changed cards, 1 contacts re-read")
        #expect(phases.withLock { $0 } == [.waitingForLock, .scanning, .planning, .writing])
        #expect(registry.paths(at: harness.clock.now) == ["Inbox/Bob Two.md"])
        #expect(try harness.stateStore().recentSessions(limit: 1).first?.trigger == "Live")
    }

    @Test("another device's lease: follower dry run, nothing written, status recorded")
    func leaseHeld() throws {
        let harness = CLIHarness.exported()
        let other = DeviceIdentity(id: "other-device", name: "Other Mac")
        _ = try LeaseManager(fs: harness.vault, device: other, clock: harness.clock, settle: 0).takeOver()
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        harness.vault.resetWrites()
        let outcome = harness.runner().runNow(request) { _ in }
        guard case .following(let holder, .checked(let summary)) = outcome else {
            Issue.record("expected following, got \(outcome)")
            return
        }
        #expect(holder.deviceName == "Other Mac" && !holder.isStale)
        #expect(summary.markdownUpdated == 1 && summary.appleUpdated == 0)  // what the leader still has to do
        #expect(harness.vault.text("Inbox/Bob Two.md")?.contains("Chef") == false)
        #expect(harness.vault.writes.isEmpty)
        #expect(try harness.stateStore().recentSessions(limit: 1).first?.command == "follow")
    }

    @Test("not configured: blocked as not runnable")
    func notConfigured() {
        let harness = CLIHarness(store: smallStore())
        let outcome = harness.runner().runNow(request) { _ in }
        guard case .blocked(.notRunnable(let message)) = outcome else {
            Issue.record("expected not runnable, got \(outcome)")
            return
        }
        #expect(message.contains("not configured"))
    }

    @Test("mass vanish (full snapshot): blocked by the breaker, nothing written")
    func breaker() {
        let people = (1...14).map { number in
            Fixtures.contact("p\(number)") { $0.name = PersonName(given: "Person", family: "N\(number)") }
        }
        let harness = CLIHarness.exported(FakeContactStore(contacts: people, containers: Fixtures.containers))
        _ = harness.sync()
        for number in 1...12 { harness.store.deleteContact(withCard: "p\(number):icloud") }
        let outcome = harness.runner().runNow(request) { _ in }
        guard case .blocked(.breaker(let message)) = outcome else {
            Issue.record("expected breaker, got \(outcome)")
            return
        }
        #expect(message.contains("mass-vanish breaker"))
    }

    @Test("lastFullCompare reflects runs planned on a full snapshot")
    func lastFullCompare() async {
        let harness = CLIHarness.exported()
        #expect(await harness.runner().lastFullCompare() == nil)
        _ = harness.sync()
        #expect(await harness.runner().lastFullCompare() == harness.clock.now)
    }
}

@Suite("contacts2md watch")
struct WatchCommandTests {
    @Test("catch-up at start (full), then a live Contacts change (incremental), until interrupted")
    func watch() async {
        let harness = CLIHarness.exported()
        _ = harness.sync()
        let source = TestSource()
        let store = harness.store
        let output = CLIOutput.capturing()
        let environment = harness.environment(
            output: output, sources: { _, _ in [source] },
            waitForInterrupt: { coordinator in
                func waitFor(runs: Int) {
                    let deadline = Date().addingTimeInterval(5)
                    while Date() < deadline {
                        let (count, idle) = block { (await coordinator.runCount, await coordinator.status == .idle) }
                        if count >= runs, idle { return }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                waitFor(runs: 1)
                store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
                source.fire(SyncTrigger(.live, reason: "Contacts changed"))
                waitFor(runs: 2)
            })
        let code = await onThread {
            Contacts2MdCLI.run(
                ["watch", "--root", "/vault", "--debounce", "0", "--sweep", "off"], environment: environment)
        }
        let out = output.stdout
        #expect(code == 0, "\(out)\(output.stderr)")
        #expect(out.contains("watch    live  debounce=0.0s  sweep=off  catch-up=on  (Ctrl-C to stop)"))
        let lines = out.split(separator: "\n").map(String.init)
        let launch = lines.first { $0.hasPrefix("synced   launch") }
        #expect(launch?.contains("(full snapshot (requested))") == true, "\(out)")
        let live = lines.first { $0.hasPrefix("synced   live") }
        #expect(live?.contains("md c/u/d 0/1/0") == true, "\(out)")
        #expect(live?.contains("(incremental: 1 changed cards, 1 contacts re-read)") == true)
        #expect(lines.last?.hasPrefix("summary  2 runs") == true)
        #expect(harness.vault.text("Inbox/Bob Two.md")?.contains("job_title: Chef") == true)
    }

    @Test("watch before the first sync: exit 3")
    func notReady() {
        let run = CLIHarness(store: smallStore()).run(["watch", "--root", "/vault"])
        #expect(run.code == 3)
    }

    @Test("--sweep validates hours or off")
    func sweepValidation() {
        let run = CLIHarness.exported().run(["watch", "--root", "/vault", "--sweep", "often"])
        #expect(run.code == 64)
    }
}
