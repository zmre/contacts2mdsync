internal import Foundation
internal import Synchronization

/// Wall-clock durations of a run's phases, in the order they first ran
/// (architecture §15: `contacts2md sync --verbose`, Activity). A phase that
/// runs again (a re-plan on a full snapshot) adds to its first entry.
public struct PhaseTimings: Codable, Hashable, Sendable {
    /// One phase: `scan`, `contacts`, `contact-notes`, `plan`, `write`, …
    public struct Entry: Codable, Hashable, Sendable {
        public var phase: String
        public var seconds: Double

        /// Creates an entry.
        public init(phase: String, seconds: Double) {
            self.phase = phase
            self.seconds = seconds
        }
    }

    public var entries: [Entry]

    /// Creates timings.
    public init(entries: [Entry] = []) { self.entries = entries }

    /// Seconds of `phase` (0 when it did not run).
    public subscript(phase: String) -> Double { entries.first { $0.phase == phase }?.seconds ?? 0 }

    /// Adds `seconds` to `phase`.
    public mutating func add(_ phase: String, seconds: Double) {
        if let index = entries.firstIndex(where: { $0.phase == phase }) {
            entries[index].seconds += seconds
        } else {
            entries.append(Entry(phase: phase, seconds: seconds))
        }
    }

    /// Moves `seconds` of `phase` into `part` (a sub-phase measured inside it).
    public mutating func split(_ part: String, seconds: Double, outOf phase: String) {
        guard seconds > 0, let index = entries.firstIndex(where: { $0.phase == phase }) else { return }
        entries[index].seconds = max(0, entries[index].seconds - seconds)
        entries.insert(Entry(phase: part, seconds: seconds), at: index + 1)
    }

    /// Takes `part`'s seconds (measured inside `phase`) out of `phase`.
    public mutating func exclude(_ part: String, from phase: String) {
        guard let index = entries.firstIndex(where: { $0.phase == phase }) else { return }
        entries[index].seconds = max(0, entries[index].seconds - self[part])
    }

    public var total: Double { entries.reduce(0) { $0 + $1.seconds } }

    /// `scan 0.42s  contacts 3.10s  contact-notes 0.55s  plan 1.20s` (no
    /// phase rounds to below 0.01 s and is left out).
    public var line: String {
        entries.filter { $0.seconds >= 0.005 }.map { "\($0.phase) \(String(format: "%.2f", $0.seconds))s" }
            .joined(separator: "  ")
    }
}

/// Measures phases into `PhaseTimings` (thread-safe; one per run).
public final class PhaseTimer: Sendable {
    private let state = Mutex(PhaseTimings())

    /// Creates an empty timer.
    public init() {}

    /// Runs `work`, adding its duration to `phase`.
    public func measure<T>(_ phase: String, _ work: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        defer {
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            state.withLock { $0.add(phase, seconds: seconds) }
        }
        return try work()
    }

    /// Moves `seconds` of `phase` into `part` (measured elsewhere, e.g. the
    /// Contacts notes read inside the Contacts read).
    public func split(_ part: String, seconds: Double, outOf phase: String) {
        state.withLock { $0.split(part, seconds: seconds, outOf: phase) }
    }

    /// Takes `part`'s seconds (measured inside `phase`) out of `phase`.
    public func exclude(_ part: String, from phase: String) { state.withLock { $0.exclude(part, from: phase) } }

    /// What was measured so far.
    public var timings: PhaseTimings { state.withLock { $0 } }
}
