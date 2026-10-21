internal import Foundation
internal import SyncEngine
internal import SyncTriggers
internal import Synchronization

/// Options of `contacts2md watch`.
struct WatchSettings {
    var debounce: TimeInterval
    /// `nil`: no sweep.
    var sweepInterval: TimeInterval?
    var catchUp: Bool
    var lockWait: TimeInterval
}

extension Session {
    /// `watch`: runs the sync coordinator with every trigger source until
    /// Ctrl-C, printing one line per status change (architecture §10, §15).
    func watch(_ settings: WatchSettings) -> CLIExitCode {
        run { root in
            guard hasSynced(root.url) else {
                throw VaultNotReady(
                    description: "first sync not done on this Mac: run it in Contacts2MdSync "
                        + "(or `contacts2md export --yes`) once")
            }
            let ownWrites = OwnWriteRegistry()
            let runner = VaultSyncRunner(
                root: root.url, environment: environment, ownWrites: ownWrites,
                options: SyncRequest(policy: .headless), lockWait: settings.lockWait)
            let coordinator = SyncCoordinator(
                runner: runner,
                settings: TriggerSettings(liveSync: true, sweepInterval: settings.sweepInterval),
                configuration: SyncCoordinator.Configuration(debounce: settings.debounce),
                clock: environment.triggerClock)
            let printer = WatchPrinter(
                output: environment.output, timeZone: environment.timeZone, quiet: options.quiet,
                verbose: options.verbose)
            let printing = Self.blocking {
                let updates = await coordinator.statusUpdates()
                return Task { for await status in updates { printer.print(status) } }
            }
            let sources =
                (settings.catchUp ? [LaunchCatchUp()] : []) + environment.makeTriggerSources(root.url, ownWrites)
            let sweep = settings.sweepInterval.map { "\(Int($0 / 60)) min" } ?? "off"
            let catchUp = settings.catchUp ? "on" : "off"
            report.info(
                "watch    live  debounce=\(settings.debounce)s  sweep=\(sweep)  catch-up=\(catchUp)  (Ctrl-C to stop)")
            Self.blocking { await coordinator.start(sources) }
            environment.waitForInterrupt(coordinator)
            report.info("watch    stopping (waiting for a run in progress)")
            Self.blocking { await coordinator.shutdown() }
            Self.blocking { await printing.value }
            let runs = Self.blocking { await coordinator.runCount }
            report.info("summary  \(runs) runs  \(String(format: "%.1fs", elapsed))")
            return .success
        }
    }

    /// Runs `body` to completion from synchronous code (never call on a
    /// cooperative-pool thread).
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.set(await body())
            done.signal()
        }
        done.wait()
        return box.take()
    }
}

/// A value handed from a task to a waiting thread.
private final class ResultBox<T: Sendable>: Sendable {
    private let value = Mutex<T?>(nil)

    func set(_ new: T) { value.withLock { $0 = new } }

    func take() -> T {
        // The semaphore guarantees `set` ran first.
        value.withLock { $0 }!  // swiftlint:disable:this force_unwrapping
    }
}

/// Prints coordinator status changes as CLI lines.
struct WatchPrinter: Sendable {
    let output: CLIOutput
    let timeZone: TimeZone
    let quiet: Bool
    let verbose: Bool

    func print(_ status: SyncCoordinatorStatus) {
        if let line = verboseLine(status) {
            if verbose { output.line(line) }
            return
        }
        switch status {
        case .running(let kind, _):
            if !quiet { output.line("running  \(kind.rawValue)") }
        case .finished(let summary):
            print(summary)
        case .blocked(.breaker(let message)):
            output.error("ERROR    \(message)")
        case .blocked(let reason):
            if !quiet { output.line("note     blocked: \(reason.message)") }
        case .failed(let message):
            output.error("ERROR    sync failed: \(message)")
        default:
            break
        }
    }

    /// Lines shown only with `--verbose`.
    private func verboseLine(_ status: SyncCoordinatorStatus) -> String? {
        switch status {
        case .idle: "idle"
        case .scheduled(let kind, let startsAt): "scheduled \(kind.rawValue) at \(time(startsAt))"
        case .running(let kind, .some(let phase)): "running  \(kind.rawValue)  (\(phase.rawValue))"
        case .skipped(let kind, let reason): "skipped  \(kind.rawValue): \(reason)"
        default: nil
        }
    }

    private func print(_ summary: SyncRunSummary) {
        let seconds = String(format: "%.1fs", summary.finishedAt.timeIntervalSince(summary.startedAt))
        if !quiet || summary.changedSomething || summary.pendingReview > 0 {
            output.line(
                "synced   \(summary.kind.rawValue)  \(time(summary.finishedAt))  \(summary.line)  "
                    + "(\(summary.appleRead))  \(seconds)")
        }
        if let reason = summary.appleHoldReason, summary.appleHeld > 0 {
            output.line("WARNING  held       \(summary.appleHeld) Apple changes — \(reason)")
        }
        if summary.pendingReview > 0 {
            output.line("WARNING  pending    \(summary.pendingReview) items need review (`contacts2md review list`)")
        }
        for failure in summary.failures { output.error("ERROR    \(failure)") }
    }

    private func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
