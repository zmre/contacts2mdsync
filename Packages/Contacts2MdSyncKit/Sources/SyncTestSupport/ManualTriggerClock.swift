public import Foundation
public import SyncTriggers
internal import Synchronization

/// A `TriggerClock` that only moves when told to (`advance`), for testing
/// debounce, wake delays and sweeps without waiting.
public final class ManualTriggerClock: TriggerClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
    }

    private let state: Mutex<State>

    /// Starts at `start`.
    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { state = Mutex(State(now: start)) }

    public var now: Date { state.withLock { $0.now } }

    /// Tasks currently sleeping.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume: (any Error)?? = state.withLock { state in
                    if Task.isCancelled { return .some(CancellationError()) }
                    if deadline <= state.now { return .some(nil) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .none
                }
                switch resume {
                case .some(.some(let error)): continuation.resume(throwing: error)
                case .some(.none): continuation.resume()
                case .none: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    public func advance(by seconds: TimeInterval) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += seconds
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Polls `condition` until it holds or `timeout` (real) seconds pass.
public func eventually(
    timeout: TimeInterval = 3, _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
