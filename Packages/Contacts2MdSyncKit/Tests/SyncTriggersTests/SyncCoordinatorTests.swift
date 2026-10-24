import Foundation
import SyncEngine
import SyncTestSupport
import SyncTriggers
import Synchronization
import Testing

/// A runner that records requests, can hold runs until released, and
/// returns scripted outcomes.
final class FakeRunner: SyncRunner {
    struct State {
        var requests: [SyncRunRequest] = []
        var running = 0
        var maxRunning = 0
        var outcomes: [SyncRunOutcome] = []
        var holding = false
        var held: [CheckedContinuation<Void, Never>] = []
        var lastFullCompare: Date?
    }

    let state = Mutex(State())
    let clock: any TriggerClock

    init(clock: any TriggerClock) { self.clock = clock }

    func run(_ request: SyncRunRequest, progress: @escaping @Sendable (SyncPhase) -> Void) async -> SyncRunOutcome {
        let hold = state.withLock { state -> Bool in
            state.requests.append(request)
            state.running += 1
            state.maxRunning = max(state.maxRunning, state.running)
            return state.holding
        }
        progress(.scanning)
        if hold {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.holding else { return true }
                    state.held.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let now = clock.now
        return state.withLock { state in
            state.running -= 1
            if request.appleMode == .full { state.lastFullCompare = now }
            guard state.outcomes.isEmpty else { return state.outcomes.removeFirst() }
            return .finished(
                SyncRunSummary(
                    kind: request.kind, startedAt: now, finishedAt: now, appleFull: request.appleMode == .full,
                    appleRead: request.appleMode.rawValue))
        }
    }

    func lastFullCompare() async -> Date? { state.withLock { $0.lastFullCompare } }

    var requests: [SyncRunRequest] { state.withLock { $0.requests } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }
    var running: Int { state.withLock { $0.running } }

    func hold() { state.withLock { $0.holding = true } }

    func release() {
        let held = state.withLock { state in
            state.holding = false
            defer { state.held = [] }
            return state.held
        }
        for continuation in held { continuation.resume() }
    }

    func script(_ outcomes: [SyncRunOutcome]) { state.withLock { $0.outcomes = outcomes } }
    func setLastFullCompare(_ date: Date?) { state.withLock { $0.lastFullCompare = date } }
}

/// A trigger source tests fire by hand.
final class ManualSource: SettingsAwareTriggerSource {
    private struct State {
        var emit: (@Sendable (SyncTrigger) -> Void)?
        var settings: [TriggerSettings] = []
        var stopped = false
    }

    private let state = Mutex(State())

    func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) { state.withLock { $0.emit = emit } }
    func stop() { state.withLock { $0.stopped = true } }
    func apply(_ settings: TriggerSettings) { state.withLock { $0.settings.append(settings) } }

    func fire(_ trigger: SyncTrigger) { state.withLock { $0.emit }?(trigger) }
    var stopped: Bool { state.withLock { $0.stopped } }
    var appliedSettings: [TriggerSettings] { state.withLock { $0.settings } }
}

/// Lets queued tasks run (no time passes on the manual clock).
func settle() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Collects a coordinator's status updates.
final class StatusLog: Sendable {
    private let entries = Mutex<[SyncCoordinatorStatus]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ coordinator: SyncCoordinator) async {
        let stream = await coordinator.statusUpdates()
        let task = Task { [weak self] in
            for await status in stream { self?.entries.withLock { $0.append(status) } }
        }
        self.task.withLock { $0 = task }
    }

    var all: [SyncCoordinatorStatus] { entries.withLock { $0 } }

    func contains(_ predicate: (SyncCoordinatorStatus) -> Bool) -> Bool { all.contains(where: predicate) }
}

@Suite("SyncCoordinator")
struct SyncCoordinatorTests {
    let clock = ManualTriggerClock()

    func make(
        settings: TriggerSettings = TriggerSettings(), configuration: SyncCoordinator.Configuration = .init()
    ) -> (SyncCoordinator, FakeRunner) {
        let runner = FakeRunner(clock: clock)
        return (SyncCoordinator(runner: runner, settings: settings, configuration: configuration, clock: clock), runner)
    }

    @Test("live events are debounced: each event restarts the 3 s window; one run for the burst")
    func debounce() async {
        let (coordinator, runner) = make()
        await coordinator.submit(SyncTrigger(.live, reason: "a"))
        clock.advance(by: 2)
        await settle()
        #expect(runner.requests.isEmpty)
        await coordinator.submit(SyncTrigger(.live, reason: "b"))
        clock.advance(by: 2)
        await settle()
        #expect(runner.requests.isEmpty)  // 4 s after the first, 2 s after the last
        clock.advance(by: 1.5)
        #expect(await eventually { runner.requests.count == 1 })
        let request = runner.requests[0]
        #expect(request.kind == .live && request.appleMode == .incremental && request.reasons == ["a", "b"])
        await settle()
        #expect(runner.requests.count == 1)
    }

    @Test("continuous churn: a live run starts no later than the 30 s cap")
    func debounceCap() async {
        let (coordinator, runner) = make()
        for step in 0..<20 {
            await coordinator.submit(SyncTrigger(.live, reason: "\(step)"))
            clock.advance(by: 2)
            await settle()
            if !runner.requests.isEmpty { break }
        }
        #expect(await eventually { runner.requests.count == 1 })
        #expect(runner.requests[0].reasons.count <= 16)  // fired at ~30 s, not after all 20 events
    }

    @Test("manual and catch-up requests run at once and absorb pending live events (full snapshot)")
    func coalescing() async {
        let (coordinator, runner) = make()
        await coordinator.submit(SyncTrigger(.live))
        await coordinator.submit(SyncTrigger(.rescanVault))
        await coordinator.syncNow()
        #expect(await eventually { runner.requests.count == 1 })
        let request = runner.requests[0]
        #expect(request.kind == .manual)
        #expect(request.kinds == [.live, .rescanVault, .manual])
        #expect(request.appleMode == .full && request.vaultRescan)
        clock.advance(by: 10)
        await settle()
        #expect(runner.requests.count == 1)
    }

    @Test("no overlapping runs: triggers during a run coalesce into exactly one follow-up run")
    func serialization() async {
        let (coordinator, runner) = make()
        runner.hold()
        await coordinator.syncNow()
        #expect(await eventually { runner.running == 1 })
        for _ in 0..<5 { await coordinator.submit(SyncTrigger(.live)) }
        await coordinator.submit(SyncTrigger(.wake))
        clock.advance(by: 60)
        await settle()
        #expect(runner.requests.count == 1)
        #expect(await coordinator.isRunning)
        runner.release()
        #expect(await eventually { runner.requests.count == 2 })
        let follow = runner.requests[1]
        #expect(follow.kind == .wake && follow.kinds == [.live, .wake] && follow.appleMode == .full)
        #expect(await eventually { runner.running == 0 })
        #expect(runner.maxRunning == 1)
        await coordinator.waitUntilIdle()
        #expect(await coordinator.status == .idle)
    }

    @Test("lease held by another device: blocked, nothing retried until the next trigger")
    func leaseHeld() async {
        let (coordinator, runner) = make()
        let log = await StatusLog(coordinator)
        let until = clock.now.addingTimeInterval(600)
        runner.script([.blocked(.leaseHeldElsewhere(deviceName: "Other Mac", until: until))])
        await coordinator.syncNow()
        let blocked = SyncCoordinatorStatus.blocked(.leaseHeldElsewhere(deviceName: "Other Mac", until: until))
        #expect(await eventually { log.contains { $0 == blocked } })
        clock.advance(by: 3600)
        await settle()
        #expect(runner.requests.count == 1)
        #expect(await coordinator.status == .idle)
    }

    @Test("another run on this Mac holds the lock: retried after 30 s, at most 3 times")
    func localLockRetry() async {
        let (coordinator, runner) = make()
        runner.script(Array(repeating: .blocked(.localRunInProgress), count: 5))
        await coordinator.submit(SyncTrigger(.launch))
        #expect(await eventually { runner.requests.count == 1 })
        clock.advance(by: 29)
        await settle()
        #expect(runner.requests.count == 1)
        for expected in 2...4 {
            clock.advance(by: 30)
            #expect(await eventually { runner.requests.count == expected })
        }
        #expect(runner.requests.map(\.attempt) == [0, 1, 2, 3])
        clock.advance(by: 300)
        await settle()
        #expect(runner.requests.count == 4)
    }

    @Test("status stream: scheduled → running → phase → finished → idle")
    func statusStream() async {
        let (coordinator, _) = make()
        let log = await StatusLog(coordinator)
        await coordinator.submit(SyncTrigger(.live))
        clock.advance(by: 3)
        #expect(
            await eventually {
                log.contains { if case .finished = $0 { true } else { false } } && log.all.last == .idle
            })
        let kinds = log.all.map { status -> String in
            switch status {
            case .idle: "idle"
            case .scheduled: "scheduled"
            case .running(_, nil): "running"
            case .running(_, .some(let phase)): phase.name
            case .finished: "finished"
            default: "other"
            }
        }
        #expect(kinds.first == "idle")
        #expect(kinds.contains("scheduled"))
        let running = kinds.firstIndex(of: "running") ?? .max
        #expect(running < kinds.firstIndex(of: "finished") ?? .min)
        #expect(await coordinator.lastSummary?.kind == .live)
    }

    @Test("live sync off: live, rescan, launch and wake are ignored; Sync Now still runs")
    func liveSyncOff() async {
        let (coordinator, runner) = make(settings: TriggerSettings(liveSync: false))
        for kind in [SyncRunKind.live, .rescanVault, .launch, .wake] { await coordinator.submit(SyncTrigger(kind)) }
        clock.advance(by: 60)
        await settle()
        #expect(runner.requests.isEmpty)
        await coordinator.syncNow()
        #expect(await eventually { runner.requests.count == 1 })
    }

    @Test("turning live sync off drops a pending live-only request; settings reach settings-aware sources")
    func settingsUpdate() async {
        let (coordinator, runner) = make()
        let source = ManualSource()
        await coordinator.start([source])
        source.fire(SyncTrigger(.live))
        #expect(await eventually { await coordinator.pendingRequest != nil })
        let off = TriggerSettings(liveSync: false, sweepInterval: nil)
        await coordinator.update(off)
        #expect(await coordinator.pendingRequest == nil)
        clock.advance(by: 60)
        await settle()
        #expect(runner.requests.isEmpty)
        #expect(source.appliedSettings == [TriggerSettings(), off])
        await coordinator.shutdown()
        #expect(source.stopped)
    }

    @Test("sweep: skipped while a full compare ran within the interval, else a full run")
    func sweepWindow() async {
        let (coordinator, runner) = make(settings: TriggerSettings(sweepInterval: 2 * 3600))
        let log = await StatusLog(coordinator)
        runner.setLastFullCompare(clock.now.addingTimeInterval(-30 * 60))
        await coordinator.submit(SyncTrigger(.sweep))
        #expect(await eventually { log.contains { $0 == .skipped(.sweep, reason: "full compare 30 min ago") } })
        #expect(runner.requests.isEmpty)
        runner.setLastFullCompare(clock.now.addingTimeInterval(-3 * 3600))
        await coordinator.submit(SyncTrigger(.sweep))
        #expect(await eventually { runner.requests.count == 1 })
        #expect(runner.requests[0].kind == .sweep && runner.requests[0].appleMode == .full)
    }

    @Test("sweep off: sweep triggers are skipped")
    func sweepOff() async {
        let (coordinator, runner) = make(settings: TriggerSettings(sweepInterval: nil))
        await coordinator.submit(SyncTrigger(.sweep))
        await settle()
        #expect(runner.requests.isEmpty)
        #expect(await coordinator.status == .skipped(.sweep, reason: "safety sweep is off"))
    }

    @Test("a sweep timer on the clock fires every interval; the coordinator runs it only outside the window")
    func sweepTiming() async {
        let (coordinator, runner) = make(settings: TriggerSettings(sweepInterval: 3600))
        let sweeps = ClockSweepSource(clock: clock)
        await coordinator.start([sweeps])
        runner.setLastFullCompare(clock.now)
        #expect(await eventually { clock.sleeperCount >= 1 })
        clock.advance(by: 1800)
        await settle()
        #expect(runner.requests.isEmpty)
        clock.advance(by: 1800)  // 1 h: a full compare exactly 1 h ago is outside the window
        #expect(await eventually { runner.requests.count == 1 })
        #expect(runner.requests[0].kind == .sweep)
        // Just ran (full): the next tick an hour later runs again; a tick sooner would be skipped.
        #expect(await eventually { clock.sleeperCount >= 1 })
        clock.advance(by: 3600)
        #expect(await eventually { runner.requests.count == 2 })
        await coordinator.update(TriggerSettings(sweepInterval: nil))
        clock.advance(by: 4 * 3600)
        await settle()
        #expect(runner.requests.count == 2)
        await coordinator.shutdown()
    }

    @Test("sources started by the coordinator feed it; shutdown stops them and ends status streams")
    func sourcesAndShutdown() async {
        let (coordinator, runner) = make()
        let source = ManualSource()
        await coordinator.start([LaunchCatchUp(), source])
        #expect(await eventually { runner.requests.count == 1 })
        #expect(runner.requests[0].kind == .launch && runner.requests[0].appleMode == .full)
        source.fire(SyncTrigger(.live))
        #expect(await eventually { await coordinator.pendingRequest?.kind == .live })
        clock.advance(by: 3)
        #expect(await eventually { runner.requests.count == 2 })
        #expect(runner.requests.last?.appleMode == .incremental)
        await coordinator.shutdown()
        source.fire(SyncTrigger(.live))
        await coordinator.syncNow()
        clock.advance(by: 10)
        await settle()
        #expect(runner.requests.count == 2)
    }
}

@Suite("Run kinds and settings")
struct RunKindTests {
    @Test("full vs incremental per kind (architecture §10 table)")
    func appleModes() {
        #expect(SyncRunKind.live.appleMode == .incremental)
        #expect(SyncRunKind.rescanVault.appleMode == .incremental)
        for kind in [SyncRunKind.launch, .wake, .sweep, .manual] { #expect(kind.appleMode == .full) }
        let merged = SyncRunRequest(SyncTrigger(.live)).merging(SyncTrigger(.rescanVault))
        #expect(merged.appleMode == .incremental && merged.vaultRescan && merged.kind == .rescanVault)
        #expect(merged.merging(SyncTrigger(.sweep)).appleMode == .full)
    }

    @Test("settings: defaults, clamping to 1–6 h, sweep off stored as null, round trip")
    func settings() throws {
        #expect(TriggerSettings() == TriggerSettings(liveSync: true, sweepInterval: 7200))
        #expect(TriggerSettings(sweepInterval: 60).sweepInterval == 3600)
        #expect(TriggerSettings(sweepInterval: 86_400).sweepInterval == TimeInterval(21_600))
        let directory = FileManager.default.temporaryDirectory.appending(path: "c2m-triggers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TriggerSettingsStore(directory: directory)
        #expect(store.load() == TriggerSettings())
        try store.save(TriggerSettings(liveSync: false, sweepInterval: nil))
        #expect(store.load() == TriggerSettings(liveSync: false, sweepInterval: nil))
        let text = try String(contentsOf: directory.appending(path: "triggers.json"), encoding: .utf8)
        #expect(text.contains("\"sweep_interval_seconds\" : null"))
        try Data("{\"live_sync\": false}".utf8).write(to: directory.appending(path: "triggers.json"))
        #expect(store.load() == TriggerSettings(liveSync: false))
    }

    @Test("LaunchCatchUp fires once")
    func launchOnce() {
        let source = LaunchCatchUp()
        let fired = Mutex(0)
        source.start { _ in fired.withLock { $0 += 1 } }
        source.start { _ in fired.withLock { $0 += 1 } }
        #expect(fired.withLock { $0 } == 1)
    }
}
