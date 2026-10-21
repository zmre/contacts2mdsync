public import Foundation
internal import Synchronization

/// Source of new record ids (`mdsync.id`). Injected so tests are deterministic.
public protocol IDGenerator: Sendable {
    /// A new, unused id.
    func next() -> UUID
}

/// Random UUID v4 ids (production).
public struct RandomIDGenerator: IDGenerator {
    /// Creates the generator.
    public init() {}

    public func next() -> UUID { UUID() }
}

/// Predictable ids `00000000-0000-4000-8000-<counter>` for tests and goldens.
public final class SequentialIDGenerator: IDGenerator {
    private let counter: Mutex<UInt64>

    /// Starts at `start`.
    public init(start: UInt64 = 1) { counter = Mutex(start) }

    public func next() -> UUID {
        let value = counter.withLock { value in
            defer { value += 1 }
            return value
        }
        let hex = String(value, radix: 16)
        let tail = String(repeating: "0", count: max(0, 12 - hex.count)) + hex
        // Force-unwrap is safe: the string is a well-formed UUID by construction.
        return UUID(uuidString: "00000000-0000-4000-8000-\(tail)")!  // swiftlint:disable:this force_unwrapping
    }
}

/// The current time. Not named `Clock` to avoid clashing with the stdlib protocol.
public protocol SyncClock: Sendable {
    var now: Date { get }
}

/// Wall-clock time.
public struct SystemClock: SyncClock {
    /// Creates the clock.
    public init() {}

    public var now: Date { Date() }
}

/// A clock that always reports the same instant.
public struct FixedClock: SyncClock {
    public let now: Date

    /// Creates the clock.
    public init(_ now: Date) { self.now = now }
}
