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
    /// Set when the holder gave the lease up (app quit, `contacts2md lease
    /// release`): free for any device at once.
    public var releasedAt: Date?

    /// Creates a lease.
    public init(
        deviceID: String, deviceName: String, acquiredAt: Date, heartbeatAt: Date, expiresAt: Date,
        releasedAt: Date? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.acquiredAt = acquiredAt
        self.heartbeatAt = heartbeatAt
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
    }

    /// Released, or past its expiry: any device may take it.
    public func isFree(at now: Date) -> Bool { releasedAt != nil || expiresAt <= now }

    /// Held, but the holder has not refreshed it for `staleAfter`: the
    /// holder is probably asleep, offline or gone (or iCloud is slow to
    /// deliver its heartbeats). The UI offers Take Over.
    public func isStale(at now: Date, staleAfter: TimeInterval = LeaseManager.staleAfter) -> Bool {
        !isFree(at: now) && now.timeIntervalSince(heartbeatAt) > staleAfter
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case acquiredAt = "acquired_at"
        case heartbeatAt = "heartbeat_at"
        case expiresAt = "expires_at"
        case releasedAt = "released_at"
    }
}

/// Acquires, refreshes and releases the vault lease (architecture §11).
///
/// Acquire: when the lease is absent, expired, released, ours, or
/// `takeOver` is set, write it, wait `settle` (≈ 60 s, so a concurrent
/// writer on another device can land through iCloud), re-read, and proceed
/// only if it is still ours (same device and acquisition time). A device
/// renewing its own unexpired lease does not wait, and the wait is skipped
/// while no other device has ever used the vault.
///
/// Every write goes through `VaultFS.write` (coordinated, atomic temp file
/// + replace on disk). Heartbeats and releases are compare-and-swap on the
/// bytes just read, so a take-over that landed in between is never
/// overwritten. iCloud conflict versions of `lease.json` (two devices
/// writing at once) are resolved by keeping the current contents: every
/// device then sees the same winner after the settle wait.
public struct LeaseManager: Sendable {
    public static let path = ".c2mdsync/lease.json"
    /// Heartbeat interval for long-running leaders (the app, `watch`).
    public static let heartbeatInterval: TimeInterval = 5 * 60
    /// Lease lifetime without a heartbeat.
    public static let defaultTTL: TimeInterval = 20 * 60
    /// A lease whose heartbeat is older than this is shown as stale (two
    /// missed heartbeats; iCloud may also be slow to deliver them).
    public static let staleAfter: TimeInterval = 2 * heartbeatInterval

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
        fs: any VaultFS, device: DeviceIdentity, clock: any SyncClock, ttl: TimeInterval = LeaseManager.defaultTTL,
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

    /// The result of a heartbeat.
    public enum HeartbeatOutcome: Hashable, Sendable {
        /// Our lease, refreshed.
        case renewed(VaultLease)
        /// Not ours (another device took over, or we released it); the
        /// current lease, if any.
        case notHeld(VaultLease?)
    }

    /// The current lease, if readable.
    public func read() -> VaultLease? { readStamped()?.lease }

    /// The lease as this device sees it now.
    public func status() -> LeaseStatus {
        LeaseStatus(lease: read(), deviceID: device.id, now: clock.now)
    }

    /// Tries to become (or stay) the leader.
    public func acquire(takeOver: Bool = false, otherDevicesKnown: Bool) throws -> Outcome {
        resolveConflictVersions()
        let now = clock.now
        let current = read()
        if let current, current.deviceID != device.id, !current.isFree(at: now), !takeOver {
            return .heldElsewhere(current)
        }
        let renewing = current.map { $0.deviceID == device.id && !$0.isFree(at: now) } ?? false
        let lease = VaultLease(
            deviceID: device.id, deviceName: device.name, acquiredAt: renewing ? (current?.acquiredAt ?? now) : now,
            heartbeatAt: now, expiresAt: now.addingTimeInterval(ttl))
        try write(lease, expecting: .any)
        let contested = otherDevicesKnown || (current.map { $0.deviceID != device.id } ?? false)
        guard !renewing, contested, settle > 0 else { return .acquired(lease) }
        sleep(settle)
        resolveConflictVersions()
        guard let reread = read() else { return .acquired(lease) }
        guard reread.deviceID == device.id, reread.acquiredAt == lease.acquiredAt, reread.releasedAt == nil else {
            return .heldElsewhere(reread)
        }
        return .acquired(reread)
    }

    /// Takes the lease from whoever holds it (explicit Take Over).
    public func takeOver(otherDevicesKnown: Bool = true) throws -> Outcome {
        try acquire(takeOver: true, otherDevicesKnown: otherDevicesKnown)
    }

    /// Refreshes the heartbeat of our lease. A no-op when another device
    /// took it over or we released it (compare-and-swap on the bytes read).
    @discardableResult
    public func heartbeat() throws -> HeartbeatOutcome {
        resolveConflictVersions()
        guard let (current, stamp) = readStamped() else { return .notHeld(nil) }
        guard current.deviceID == device.id, current.releasedAt == nil else { return .notHeld(current) }
        var lease = current
        let now = clock.now
        lease.heartbeatAt = now
        lease.expiresAt = now.addingTimeInterval(ttl)
        do {
            try write(lease, expecting: .unchanged(stamp))
        } catch VaultFSError.conflict {
            return .notHeld(read())  // someone wrote it in between
        }
        return .renewed(lease)
    }

    /// Gives our lease up so another device can lead at once (app quit,
    /// folder change, `contacts2md lease release`). Returns `false` when
    /// the lease was not ours.
    @discardableResult
    public func release() throws -> Bool {
        guard let (current, stamp) = readStamped(), current.deviceID == device.id, current.releasedAt == nil else {
            return false
        }
        var lease = current
        let now = clock.now
        lease.heartbeatAt = now
        lease.expiresAt = now
        lease.releasedAt = now
        do {
            try write(lease, expecting: .unchanged(stamp))
        } catch VaultFSError.conflict {
            return false
        }
        return true
    }

    private func readStamped() -> (lease: VaultLease, stamp: FileStamp)? {
        guard fs.exists(Self.path), let (data, stamp) = try? fs.read(Self.path),
            let lease = try? Self.decoder.decode(VaultLease.self, from: data)
        else { return nil }
        return (lease, stamp)
    }

    /// iCloud kept one of two concurrent writes as the current contents and
    /// the other as a conflict version: keep the current one everywhere.
    private func resolveConflictVersions() {
        guard let versions = try? fs.unresolvedConflictVersions(Self.path), !versions.isEmpty else { return }
        try? fs.resolveConflictVersions(Self.path, keeping: nil)
    }

    private func write(_ lease: VaultLease, expecting: WriteExpectation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        _ = try fs.write(try encoder.encode(lease), to: Self.path, expecting: expecting)
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
        let path = "\(DecisionLog.devicesFolder)/\(record.deviceID).json"
        _ = try fs.write(try encoder.encode(record), to: path, expecting: .any)
        // Only this device writes its record: any conflict version is an older copy.
        if let versions = try? fs.unresolvedConflictVersions(path), !versions.isEmpty {
            try? fs.resolveConflictVersions(path, keeping: nil)
        }
    }

    /// Every device record in the vault (unreadable ones skipped).
    public static func all(fs: any VaultFS) -> [DeviceRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? fs.list(DecisionLog.devicesFolder)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { name in
                guard let (data, _) = try? fs.read("\(DecisionLog.devicesFolder)/\(name)") else { return nil }
                return try? decoder.decode(DeviceRecord.self, from: data)
            }
    }

    /// Ids of every device that ever used the vault (`<id>.json` or `<id>/`).
    public static func deviceIDs(fs: any VaultFS) -> [String] {
        let names = (try? fs.list(DecisionLog.devicesFolder)) ?? []
        let ids = names.filter { !$0.hasPrefix(".") }.map { $0.hasSuffix(".json") ? String($0.dropLast(5)) : $0 }
        return Array(Set(ids)).sorted()
    }
}
