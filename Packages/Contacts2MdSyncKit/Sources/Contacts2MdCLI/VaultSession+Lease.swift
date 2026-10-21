public import Foundation
public import SyncEngine

// Multi-device (architecture §11, M6): the vault lease as seen from this
// device, explicit take-over and release, the lease keeper the app's
// coordinator owns, and follower dry runs.

extension VaultSession {
    /// A lease manager for this device on this vault (the settle wait and
    /// sleep come from the environment).
    func leaseManager() throws -> LeaseManager {
        LeaseManager(
            fs: environment.makeVault(root), device: try environment.device(), clock: environment.clock,
            settle: environment.leaseSettle, sleep: environment.sleep)
    }

    /// `true` when another device has used this vault.
    func otherDevicesKnown() throws -> Bool {
        let device = try environment.device()
        return DeviceRecord.deviceIDs(fs: environment.makeVault(root)).contains { $0 != device.id }
    }

    /// The lease as this device sees it: leader, follower (with the holder's
    /// name, last heartbeat and staleness) or vacant. Reads one file; needs
    /// no Contacts access and writes nothing.
    public func leaseStatus() throws -> LeaseStatus {
        try leaseManager().status()
    }

    /// Takes the lease from whoever holds it (Take Over): write, wait for
    /// the settle delay when other devices use the vault, re-read. The
    /// returned status says whether this device leads now.
    @discardableResult
    public func takeOverLease() throws -> LeaseStatus {
        let manager = try leaseManager()
        _ = try manager.takeOver(otherDevicesKnown: try otherDevicesKnown())
        return manager.status()
    }

    /// Gives this device's lease up so another device can lead at once.
    /// `false` when this device did not hold it.
    @discardableResult
    public func releaseLease() throws -> Bool {
        try leaseManager().release()
    }

    /// The keeper a `SyncCoordinator` owns for this vault: heartbeats every
    /// 5 minutes while the app runs, releases on shutdown, takes over on
    /// request. Hand it to `SyncCoordinator(…, leaseKeeper:)`.
    public func makeLeaseKeeper() throws -> LeaseKeeper {
        let fs = environment.makeVault(root)
        let device = try environment.device()
        return LeaseKeeper(
            manager: try leaseManager(),
            otherDevicesKnown: { DeviceRecord.deviceIDs(fs: fs).contains { $0 != device.id } })
    }

    /// Takes the local run lock and the vault lease before an export writes
    /// (`contacts2md export --yes`, the app's first export and onboarding),
    /// exactly like `beginSync`: when another device leads and its lease is
    /// not free, nothing may be written. A vault with no lease (or a free
    /// one) gets this device's lease, which stays until it expires, as after
    /// a sync. A vault that was never configured has no state folder yet;
    /// its lock lives in the state root (`first-export.lock`).
    public func beginExport(takeOver: Bool = false) throws -> ExportGate {
        let fs = environment.makeVault(root)
        let directory =
            try VaultConfig.load(from: fs).map {
                environment.stateDirectory.appending(path: $0.config.vaultID.uuidString.lowercased())
            }
        let lockURL =
            directory?.appending(path: "sync.lock") ?? environment.stateDirectory.appending(path: "first-export.lock")
        guard let lock = try LocalLock.acquire(at: lockURL, wait: environment.lockWait, sleep: environment.sleep)
        else { return .localRunInProgress }
        do {
            switch try leaseManager().acquire(takeOver: takeOver, otherDevicesKnown: try otherDevicesKnown()) {
            case .acquired(let lease): return .ready(lock, lease)
            case .heldElsewhere(let lease):
                lock.release()
                return .leaseHeldElsewhere(lease)
            }
        } catch {
            lock.release()
            throw error
        }
    }

    /// Follower mode: scans, reads Contacts and plans exactly like a sync,
    /// then records the observations in this device's state (review queue,
    /// file cache, Contacts mirror, an Activity row `follow`), and writes
    /// nothing to the vault or to Contacts. Review decisions made from this
    /// status go to this device's decision log; the leader executes them.
    public func followerDryRun(
        _ request: SyncRequest, startedAt: Date, progress: @Sendable (SyncPhase) -> Void = { _ in }
    ) throws -> PreparedSync {
        let prepared = try prepareSync(request, progress: progress)
        try recordSyncPlan(prepared, command: "follow", startedAt: startedAt)
        return prepared
    }
}

/// Why an export may not write (`VaultSession.beginExport`).
public enum ExportGate: Sendable {
    /// Lock and lease are ours; call `release()` on the lock when done.
    case ready(LocalLock, VaultLease)
    /// Another run on this Mac holds the local lock (waited `lockWait`).
    case localRunInProgress
    /// Another device leads this vault: nothing may be written here.
    case leaseHeldElsewhere(VaultLease)
}

/// An export that could not write: another run on this Mac, or another
/// device leading the vault. The description is the user-facing message.
public struct ExportBlocked: Error, CustomStringConvertible {
    public let description: String

    /// Another run on this Mac holds the local lock.
    public static let localRunInProgress = ExportBlocked(
        description: "Another sync is running on this Mac (the command line or a scheduled run). Try again shortly.")

    /// Another device leads the vault (`lease`), as seen at `now`.
    public static func leaderElsewhere(_ lease: VaultLease, now: Date) -> ExportBlocked {
        ExportBlocked(
            description: UIBanner.leaderElsewhereMessage(
                name: lease.deviceName, expires: lease.expiresAt, stale: lease.isStale(at: now), now: now))
    }
}

extension StoredStatus {
    /// Fills the lease fields from `status`.
    mutating func apply(_ status: LeaseStatus) {
        lease = status.lease
        leaseRole = status.role
        leaseHolder = status.holder
    }
}
