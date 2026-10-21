public import Foundation
internal import Synchronization
public import VaultIndex

/// `.c2mdsync/lease.json`: which device leads syncing this vault
/// (architecture §11). Advisory: an accidental double leader converges,
/// because merges are idempotent and identical writes are skipped.
public struct VaultLease: Codable, Hashable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var acquiredAt: Date
    public var heartbeatAt: Date
    public var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case acquiredAt = "acquired_at"
        case heartbeatAt = "heartbeat_at"
        case expiresAt = "expires_at"
    }
}

/// Acquires and refreshes the vault lease.
///
/// Acquire: when the lease is absent, expired, ours, or `takeOver` is set,
/// write it, wait `settle` (≈ 60 s, so a concurrent writer on another
/// device can land through iCloud), re-read, and proceed only if it is still
/// ours. A device renewing its own unexpired lease does not wait, and the
/// wait is skipped while no other device has ever used the vault.
public struct LeaseManager: Sendable {
    public static let path = ".c2mdsync/lease.json"
    /// Heartbeat interval for long-running leaders (the app).
    public static let heartbeatInterval: TimeInterval = 5 * 60

    public let fs: any VaultFS
    public let device: DeviceIdentity
    public let clock: any SyncClock
    /// Lease lifetime without a heartbeat.
    public var ttl: TimeInterval
    /// Write-wait-reread delay on a fresh acquisition.
    public var settle: TimeInterval
    /// Sleeps (injectable so tests do not wait).
    public let sleep: @Sendable (TimeInterval) -> Void

    /// Creates a manager (TTL 20 min, settle 60 s).
    public init(
        fs: any VaultFS, device: DeviceIdentity, clock: any SyncClock, ttl: TimeInterval = 20 * 60,
        settle: TimeInterval = 60,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.fs = fs
        self.device = device
        self.clock = clock
        self.ttl = ttl
        self.settle = settle
        self.sleep = sleep
    }

    /// The result of trying to lead.
    public enum Outcome: Hashable, Sendable {
        case acquired(VaultLease)
        /// Another device holds an unexpired lease: do nothing this run.
        case heldElsewhere(VaultLease)
    }

    /// The current lease, if readable.
    public func read() -> VaultLease? {
        guard fs.exists(Self.path), let (data, _) = try? fs.read(Self.path) else { return nil }
        return try? Self.decoder.decode(VaultLease.self, from: data)
    }

    /// Tries to become (or stay) the leader.
    public func acquire(takeOver: Bool = false, otherDevicesKnown: Bool) throws -> Outcome {
        let now = clock.now
        let current = read()
        if let current, current.deviceID != device.id, current.expiresAt > now, !takeOver {
            return .heldElsewhere(current)
        }
        let renewing = current.map { $0.deviceID == device.id && $0.expiresAt > now } ?? false
        let lease = VaultLease(
            deviceID: device.id, deviceName: device.name, acquiredAt: renewing ? (current?.acquiredAt ?? now) : now,
            heartbeatAt: now, expiresAt: now.addingTimeInterval(ttl))
        try write(lease)
        let contested = otherDevicesKnown || (current.map { $0.deviceID != device.id } ?? false)
        guard !renewing, contested, settle > 0 else { return .acquired(lease) }
        sleep(settle)
        guard let reread = read(), reread.deviceID == device.id else {
            return read().map(Outcome.heldElsewhere) ?? .acquired(lease)
        }
        return .acquired(reread)
    }

    /// Refreshes the heartbeat of our lease (no-op if another device took it).
    public func heartbeat() throws {
        guard var lease = read(), lease.deviceID == device.id else { return }
        let now = clock.now
        lease.heartbeatAt = now
        lease.expiresAt = now.addingTimeInterval(ttl)
        try write(lease)
    }

    private func write(_ lease: VaultLease) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        _ = try fs.write(try encoder.encode(lease), to: Self.path, expecting: .any)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A local run lock (`flock`) that serializes GUI, CLI and launchd runs on
/// one Mac (architecture §15). Released on `release()` or deinit.
public final class LocalLock: Sendable {
    private let descriptor: Mutex<Int32>

    private init(descriptor: Int32) { self.descriptor = Mutex(descriptor) }

    deinit { release() }

    /// Errors opening the lock file.
    public struct LockError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Takes the lock at `url`, waiting up to `wait` seconds; `nil` when
    /// another run still holds it.
    public static func acquire(
        at url: URL, wait: TimeInterval, poll: TimeInterval = 0.2,
        sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> LocalLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw LockError(description: "cannot open lock file \(url.path)") }
        var waited: TimeInterval = 0
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard waited < wait else {
                close(descriptor)
                return nil
            }
            sleep(poll)
            waited += poll
        }
        return LocalLock(descriptor: descriptor)
    }

    /// Releases the lock (idempotent).
    public func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}

/// `.c2mdsync/devices/<id>.json`: a device's last sync, for the other
/// devices and the identity warning.
public struct DeviceRecord: Codable, Hashable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var lastSync: Date
    public var summary: String

    /// Creates a record.
    public init(deviceID: String, deviceName: String, lastSync: Date, summary: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastSync = lastSync
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case lastSync = "last_sync"
        case summary
    }

    /// Writes this device's record.
    public static func write(_ record: DeviceRecord, fs: any VaultFS) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        _ = try fs.write(
            try encoder.encode(record), to: "\(DecisionLog.devicesFolder)/\(record.deviceID).json", expecting: .any)
    }

    /// Ids of every device that ever used the vault (`<id>.json` or `<id>/`).
    public static func deviceIDs(fs: any VaultFS) -> [String] {
        let names = (try? fs.list(DecisionLog.devicesFolder)) ?? []
        let ids = names.filter { !$0.hasPrefix(".") }.map { $0.hasSuffix(".json") ? String($0.dropLast(5)) : $0 }
        return Array(Set(ids)).sorted()
    }
}
