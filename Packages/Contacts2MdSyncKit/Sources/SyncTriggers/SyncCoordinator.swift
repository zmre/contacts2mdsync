public import Foundation
public import SyncEngine

/// What the coordinator is doing, as published on `statusUpdates()`.
public enum SyncCoordinatorStatus: Hashable, Sendable {
    /// Nothing pending.
    case idle
    /// A run of `kind` will start at `startsAt` (debounce, lock retry).
    case scheduled(SyncRunKind, startsAt: Date)
    /// A run of `kind` is in progress (`nil` phase: just started).
    case running(SyncRunKind, SyncPhase?)
    /// A run finished (written or not; see the summary).
    case finished(SyncRunSummary)
    /// A run could not happen or stopped before writing.
    case blocked(SyncBlockReason)
    /// A run failed unexpectedly.
    case failed(String)
    /// A trigger was ignored (sweep within its window, live sync off).
    case skipped(SyncRunKind, reason: String)
}

/// A source that wants to hear about settings changes (sweep interval).
public protocol SettingsAwareTriggerSource: SyncTriggerSource {
    func apply(_ settings: TriggerSettings)
}

/// Serializes, debounces and coalesces sync runs (architecture §10).
///
/// - **One run at a time.** Triggers that arrive while a run is in
///   progress are coalesced into one pending request that starts after it.
/// - **Debounce.** Live events (Contacts / FSEvents) and vault rescans wait
///   for `debounce` (3 s) of quiet, but never longer than
///   `maxDebounceDelay` after the first pending event. Launch, wake, sweep
///   and manual requests start at once and absorb pending live events.
/// - **Full vs incremental.** A coalesced request reads Apple with a full
///   snapshot when any of its triggers needs one (`SyncRunKind.appleMode`).
/// - **Lock and lease.** The runner takes the local lock and the vault
///   lease. Another run on this Mac → retried after `lockRetryDelay` (up to
///   `maxLockRetries` times); another device's lease, a breaker, or an
///   unconfigured vault → `blocked`, no retry (the next trigger or the sweep
///   tries again).
/// - **Settings.** With `liveSync` off, live, rescan, launch and wake
///   triggers are ignored; Sync Now always runs; the sweep runs only when
///   `sweepInterval` is set and no full compare happened within it.
public actor SyncCoordinator {
    /// Timing knobs.
    public struct Configuration: Hashable, Sendable {
        /// Quiet period after the last live event.
        public var debounce: TimeInterval
        /// Longest a live event waits under continuous churn.
        public var maxDebounceDelay: TimeInterval
        /// Wait before retrying when another run on this Mac holds the lock.
        public var lockRetryDelay: TimeInterval
        public var maxLockRetries: Int

        /// Creates a configuration (3 s debounce, 30 s cap, 30 s lock retry × 3).
        public init(
            debounce: TimeInterval = 3, maxDebounceDelay: TimeInterval = 30, lockRetryDelay: TimeInterval = 30,
            maxLockRetries: Int = 3
        ) {
            self.debounce = debounce
            self.maxDebounceDelay = maxDebounceDelay
            self.lockRetryDelay = lockRetryDelay
            self.maxLockRetries = maxLockRetries
        }
    }

    private let runner: any SyncRunner
    private let clock: any TriggerClock
    public let configuration: Configuration
    public private(set) var settings: TriggerSettings

    /// The latest status.
    public private(set) var status: SyncCoordinatorStatus = .idle
    /// The last finished run.
    public private(set) var lastSummary: SyncRunSummary?
    /// Runs started so far.
    public private(set) var runCount = 0

    private var pending: SyncRunRequest?
    /// First and latest debounced event of the pending request.
    private var firstEventAt: Date?
    private var lastEventAt: Date?
    /// Earliest start of the pending request's non-debounced part.
    private var immediateAt: Date?
    private var current: SyncRunKind?
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private var sources: [any SyncTriggerSource] = []
    private var subscribers: [UUID: AsyncStream<SyncCoordinatorStatus>.Continuation] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a coordinator around `runner`.
    public init(
        runner: any SyncRunner, settings: TriggerSettings = TriggerSettings(),
        configuration: Configuration = Configuration(), clock: any TriggerClock = SystemTriggerClock()
    ) {
        self.runner = runner
        self.settings = settings
        self.configuration = configuration
        self.clock = clock
    }

    // MARK: - Sources and settings

    /// Starts `sources`; their triggers are submitted to this coordinator.
    public func start(_ sources: [any SyncTriggerSource]) {
        guard !stopped else { return }
        self.sources += sources
        for source in sources {
            if let aware = source as? any SettingsAwareTriggerSource { aware.apply(settings) }
            source.start { [weak self] trigger in
                guard let self else { return }
                Task { await self.submit(trigger) }
            }
        }
    }

    /// Applies new settings (also to settings-aware sources). Turning live
    /// sync off drops a pending request made only of live-sync triggers.
    public func update(_ settings: TriggerSettings) {
        self.settings = settings
        for case let aware as any SettingsAwareTriggerSource in sources { aware.apply(settings) }
        if !settings.liveSync, let pending, pending.kinds.allSatisfy(isGatedByLiveSync) {
            self.pending = nil
            resetPendingTimes()
            if current == nil { becomeIdle() }
        }
    }

    /// Stops every source and drops anything pending. A run in progress
    /// finishes; use `shutdown()` to wait for it.
    public func stop() {
        stopped = true
        for source in sources { source.stop() }
        sources = []
        timer?.cancel()
        timer = nil
        pending = nil
        resetPendingTimes()
        if current == nil { becomeIdle() }
    }

    /// `stop()`, then waits for a run in progress to finish.
    public func shutdown() async {
        stop()
        await waitUntilIdle()
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    // MARK: - Requests

    /// Sync Now.
    public func syncNow() { submit(SyncTrigger(.manual, reason: "Sync Now")) }

    /// Submits a trigger (what sources do).
    public func submit(_ trigger: SyncTrigger) {
        guard !stopped else { return }
        if isGatedByLiveSync(trigger.kind), !settings.liveSync {
            if !trigger.kind.isDebounced { emit(.skipped(trigger.kind, reason: "live sync is off")) }
            return
        }
        guard trigger.kind == .sweep else {
            enqueue(SyncRunRequest(trigger))
            return
        }
        guard let interval = settings.sweepInterval else {
            emit(.skipped(.sweep, reason: "safety sweep is off"))
            return
        }
        Task { await self.submitSweep(trigger, interval: interval) }
    }

    /// The sweep runs only when no full compare happened within its interval.
    private func submitSweep(_ trigger: SyncTrigger, interval: TimeInterval) async {
        let last = await runner.lastFullCompare()
        guard !stopped else { return }
        if let last, clock.now.timeIntervalSince(last) < interval {
            let minutes = Int(clock.now.timeIntervalSince(last) / 60)
            emit(.skipped(.sweep, reason: "full compare \(minutes) min ago"))
            return
        }
        enqueue(SyncRunRequest(trigger))
    }

    private func isGatedByLiveSync(_ kind: SyncRunKind) -> Bool {
        kind == .live || kind == .rescanVault || kind == .launch || kind == .wake
    }

    private func enqueue(_ request: SyncRunRequest, notBefore: Date? = nil) {
        let now = clock.now
        pending = pending?.merging(request) ?? request
        if let notBefore {
            immediateAt = min(immediateAt ?? notBefore, notBefore)
        } else if request.kind.isDebounced && request.kinds.allSatisfy(\.isDebounced) {
            if firstEventAt == nil { firstEventAt = now }
            lastEventAt = now
        } else {
            immediateAt = min(immediateAt ?? now, now)
        }
        guard current == nil else { return }  // picked up when the run finishes
        schedule()
    }

    /// When the pending request should start.
    private var dueAt: Date {
        if let immediateAt { return immediateAt }
        let now = clock.now
        let last = lastEventAt ?? now
        let first = firstEventAt ?? now
        let debounced = last.addingTimeInterval(configuration.debounce)
        return min(debounced, first.addingTimeInterval(configuration.maxDebounceDelay))
    }

    private func schedule() {
        guard let pending, !stopped else { return }
        generation += 1
        let ticket = generation
        let due = dueAt
        timer?.cancel()
        emit(.scheduled(pending.kind, startsAt: due))
        let clock = clock
        timer = Task { [weak self] in
            do { try await clock.sleep(until: due) } catch { return }
            await self?.fire(ticket)
        }
    }

    private func fire(_ ticket: Int) async {
        guard ticket == generation, current == nil, !stopped, let request = pending else { return }
        guard clock.now >= dueAt else {  // the debounce moved on while we slept
            schedule()
            return
        }
        pending = nil
        resetPendingTimes()
        current = request.kind
        runCount += 1
        emit(.running(request.kind, nil))
        let outcome = await runner.run(request) { [weak self] phase in
            guard let self else { return }
            Task { await self.progress(request.kind, phase) }
        }
        current = nil
        switch outcome {
        case .finished(let summary):
            lastSummary = summary
            emit(.finished(summary))
        case .blocked(.localRunInProgress) where request.attempt < configuration.maxLockRetries && !stopped:
            emit(.blocked(.localRunInProgress))
            var retry = request
            retry.attempt += 1
            enqueue(retry, notBefore: clock.now.addingTimeInterval(configuration.lockRetryDelay))
            return
        case .blocked(let reason):
            emit(.blocked(reason))
        case .failed(let message):
            emit(.failed(message))
        }
        if pending != nil, !stopped {
            schedule()
        } else {
            becomeIdle()
        }
    }

    private func progress(_ kind: SyncRunKind, _ phase: SyncPhase) {
        guard current == kind else { return }
        emit(.running(kind, phase))
    }

    private func resetPendingTimes() {
        firstEventAt = nil
        lastEventAt = nil
        immediateAt = nil
    }

    private func becomeIdle() {
        if status != .idle { emit(.idle) }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Observing

    /// Status changes, starting with the current status. Each call returns
    /// an independent stream; it ends after `shutdown()`.
    public func statusUpdates() -> AsyncStream<SyncCoordinatorStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: SyncCoordinatorStatus.self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Returns when no run is in progress and nothing is pending.
    public func waitUntilIdle() async {
        guard current != nil || pending != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// `true` while a run is in progress.
    public var isRunning: Bool { current != nil }

    /// The pending request, if any (tests, diagnostics).
    public var pendingRequest: SyncRunRequest? { pending }

    private func emit(_ status: SyncCoordinatorStatus) {
        self.status = status
        for continuation in subscribers.values { continuation.yield(status) }
    }
}
