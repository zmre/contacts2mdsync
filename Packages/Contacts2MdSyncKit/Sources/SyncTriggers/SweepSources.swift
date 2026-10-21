internal import Foundation
internal import Synchronization

#if os(macOS)
    /// The periodic safety sweep (architecture §10) on `NSBackgroundActivityScheduler`,
    /// so macOS can coalesce it with other work for battery life. Fires a
    /// `.sweep` trigger about every `sweepInterval`; the coordinator skips it
    /// when a full compare already ran within the interval. Follows the
    /// settings (`apply`): `nil` interval stops it.
    public final class SweepScheduler: SettingsAwareTriggerSource {
        private struct State {
            var emit: (@Sendable (SyncTrigger) -> Void)?
            var interval: TimeInterval? = TriggerSettings.defaultSweepInterval
            var scheduler: Box?
        }

        /// `NSBackgroundActivityScheduler` is thread-safe; it is only touched under the lock.
        private final class Box: @unchecked Sendable {
            let scheduler: NSBackgroundActivityScheduler
            init(_ scheduler: NSBackgroundActivityScheduler) { self.scheduler = scheduler }
        }

        private let identifier: String
        private let state = Mutex(State())

        /// Creates the scheduler (`identifier` names the activity for the system).
        public init(identifier: String = "com.zmre.contacts2mdsync.sweep") { self.identifier = identifier }

        public func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) {
            state.withLock { $0.emit = emit }
            reschedule()
        }

        public func stop() {
            state.withLock { state in
                state.scheduler?.scheduler.invalidate()
                state.scheduler = nil
                state.emit = nil
            }
        }

        public func apply(_ settings: TriggerSettings) {
            let changed = state.withLock { state -> Bool in
                defer { state.interval = settings.sweepInterval }
                return state.interval != settings.sweepInterval
            }
            if changed { reschedule() }
        }

        private func reschedule() {
            let identifier = identifier
            state.withLock { state in
                state.scheduler?.scheduler.invalidate()
                state.scheduler = nil
                guard let emit = state.emit, let interval = state.interval else { return }
                let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
                scheduler.repeats = true
                scheduler.interval = interval
                scheduler.tolerance = interval / 4
                scheduler.qualityOfService = .utility
                scheduler.schedule { completion in
                    emit(SyncTrigger(.sweep, reason: "safety sweep"))
                    completion(.finished)
                }
                state.scheduler = Box(scheduler)
            }
        }
    }
#endif

/// A sweep timer on a `TriggerClock`: fires `.sweep` every `sweepInterval`.
/// For `contacts2md watch` (no app activity scheduling needed) and tests.
public final class ClockSweepSource: SettingsAwareTriggerSource {
    private struct State {
        var emit: (@Sendable (SyncTrigger) -> Void)?
        var interval: TimeInterval? = TriggerSettings.defaultSweepInterval
        var task: Task<Void, Never>?
    }

    private let clock: any TriggerClock
    private let state = Mutex(State())

    /// Creates the source.
    public init(clock: any TriggerClock = SystemTriggerClock()) { self.clock = clock }

    public func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) {
        state.withLock { $0.emit = emit }
        restart()
    }

    public func stop() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            state.emit = nil
        }
    }

    public func apply(_ settings: TriggerSettings) {
        let changed = state.withLock { state -> Bool in
            defer { state.interval = settings.sweepInterval }
            return state.interval != settings.sweepInterval
        }
        if changed { restart() }
    }

    private func restart() {
        let clock = clock
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            guard let emit = state.emit, let interval = state.interval else { return }
            state.task = Task {
                var next = clock.now.addingTimeInterval(interval)
                while !Task.isCancelled {
                    do { try await clock.sleep(until: next) } catch { return }
                    emit(SyncTrigger(.sweep, reason: "safety sweep"))
                    next = clock.now.addingTimeInterval(interval)
                }
            }
        }
    }
}
