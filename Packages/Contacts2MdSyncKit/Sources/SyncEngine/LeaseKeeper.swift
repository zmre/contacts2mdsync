public import Foundation
internal import Synchronization

/// This device's part in syncing a vault.
public enum LeaseRole: String, Hashable, Sendable, Codable {
    /// This device holds the lease: it writes the vault and Contacts.
    case leader
    /// Another device holds an unexpired lease: this device only computes
    /// dry-run status; its review decisions go to its own decision log and
    /// the leader executes them.
    case follower
    /// Nobody holds the lease (none, expired or released): the next sync on
    /// any device takes it.
    case vacant
}

/// The device holding a vault lease, for status displays (`following`).
public struct LeaseHolder: Hashable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var acquiredAt: Date
    /// When the holder last refreshed the lease (as delivered by iCloud).
    public var lastHeartbeat: Date
    public var expiresAt: Date
    /// No heartbeat for `LeaseManager.staleAfter`: the holder is probably gone.
    public var isStale: Bool

    /// The holder of `lease` as seen at `now`.
    public init(_ lease: VaultLease, now: Date, staleAfter: TimeInterval = LeaseManager.staleAfter) {
        deviceID = lease.deviceID
        deviceName = lease.deviceName
        acquiredAt = lease.acquiredAt
        lastHeartbeat = lease.heartbeatAt
        expiresAt = lease.expiresAt
        isStale = lease.isStale(at: now, staleAfter: staleAfter)
    }
}

/// The lease as this device sees it.
public struct LeaseStatus: Hashable, Sendable {
    public var role: LeaseRole
    /// The lease file's contents (also when expired or released).
    public var lease: VaultLease?
    /// When this was observed.
    public var observedAt: Date
    /// The other device leading (`role == .follower`), with staleness.
    public var holder: LeaseHolder?

    /// The status of `lease` for `deviceID` at `now`.
    public init(lease: VaultLease?, deviceID: String, now: Date, staleAfter: TimeInterval = LeaseManager.staleAfter) {
        self.lease = lease
        self.observedAt = now
        guard let lease, !lease.isFree(at: now) else {
            role = .vacant
            holder = nil
            return
        }
        role = lease.deviceID == deviceID ? .leader : .follower
        holder = role == .follower ? LeaseHolder(lease, now: now, staleAfter: staleAfter) : nil
    }

    /// `leader`, `following Mac B (last heartbeat …)`, `vacant`.
    public var summary: String {
        switch role {
        case .leader: "leader"
        case .vacant: "vacant"
        case .follower:
            "following \(holder?.deviceName ?? "another device")" + (holder?.isStale == true ? " (stale)" : "")
        }
    }
}

/// Keeps this device's lease alive while it leads (architecture §11): the
/// `SyncCoordinator` owns one and calls `heartbeat()` every
/// `heartbeatInterval` (also while a run is in progress), `release()` on
/// shutdown, and `takeOver()` for an explicit Take Over. Every call does
/// blocking file I/O; call it off the main thread.
public final class LeaseKeeper: Sendable {
    public let manager: LeaseManager
    /// How often `heartbeat()` should be called (5 min).
    public let heartbeatInterval: TimeInterval
    /// `true` when other devices have used the vault (take-over waits for the settle delay).
    private let otherDevicesKnown: @Sendable () -> Bool
    private let last = Mutex<LeaseStatus?>(nil)

    /// Creates a keeper around `manager`.
    public init(
        manager: LeaseManager, heartbeatInterval: TimeInterval = LeaseManager.heartbeatInterval,
        otherDevicesKnown: @escaping @Sendable () -> Bool = { true }
    ) {
        self.manager = manager
        self.heartbeatInterval = heartbeatInterval
        self.otherDevicesKnown = otherDevicesKnown
    }

    /// The last status observed (`nil` before the first call).
    public var lastStatus: LeaseStatus? { last.withLock { $0 } }

    /// Reads the lease without writing.
    @discardableResult
    public func status() -> LeaseStatus { remember(manager.status()) }

    /// Refreshes our lease if we hold it; otherwise only reads it.
    @discardableResult
    public func heartbeat() -> LeaseStatus {
        _ = try? manager.heartbeat()
        return status()
    }

    /// Takes the lease from whoever holds it (write, settle, re-read).
    @discardableResult
    public func takeOver() throws -> LeaseStatus {
        _ = try manager.takeOver(otherDevicesKnown: otherDevicesKnown())
        return status()
    }

    /// Gives our lease up (no-op when another device holds it).
    @discardableResult
    public func release() -> LeaseStatus {
        _ = try? manager.release()
        return status()
    }

    private func remember(_ status: LeaseStatus) -> LeaseStatus {
        last.withLock { $0 = status }
        return status
    }
}
