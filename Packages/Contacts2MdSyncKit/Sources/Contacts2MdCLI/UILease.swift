public import Foundation
public import SyncEngine

// Settings ▸ Advanced ▸ Sync lease (architecture §11, M6; docs/ui.md §9):
// who leads syncing this folder, the leader's last heartbeat, staleness, and
// the other devices that sync it.

/// The vault lease and the devices sharing the folder, for Settings.
public struct UILeaseInfo: Hashable, Sendable {
    /// This Mac's role (from the coordinator's last check when live sync
    /// runs, else from the stored status).
    public var role: LeaseRole
    /// `This Mac leads syncing`, `Following Mac B`, `No device leads`.
    public var roleText: String
    /// `This Mac`, `Mac B`, or `nil` when nobody holds the lease.
    public var holder: String?
    /// The holder's last heartbeat (`Today 10:42 AM`).
    public var heartbeat: String?
    /// When the lease ends without another heartbeat.
    public var expires: String?
    /// The other device has not refreshed its lease for over 10 minutes.
    public var isStale: Bool
    /// Release Lease is offered (this Mac leads).
    public var canRelease: Bool
    /// Take Over is offered (another device leads).
    public var canTakeOver: Bool
    /// Every other device that synced this folder, most recent first.
    public var otherDevices: [UIDeviceRow]

    /// Builds the info. `live` is the coordinator's last lease check;
    /// `status` is read with the folder. The later heartbeat wins.
    public init(status: StoredStatus?, live: LeaseStatus?, deviceID: String, now: Date = Date()) {
        // The newer view wins: the coordinator's after a run, Take Over or
        // Release; the stored one after a reload that saw a later heartbeat.
        let lease: VaultLease? =
            if let live, let stored = status?.lease, let seen = live.lease, stored.heartbeatAt > seen.heartbeatAt {
                stored
            } else {
                live.map(\.lease) ?? status?.lease
            }
        let current = LeaseStatus(lease: lease, deviceID: deviceID, now: now)
        role = current.role
        isStale = current.holder?.isStale ?? false
        switch current.role {
        case .leader:
            roleText = "This Mac leads syncing"
            holder = "This Mac"
        case .follower:
            let name = current.holder?.deviceName ?? "another device"
            roleText = "Following \(name)" + (isStale ? " (no heartbeat for over 10 minutes)" : "")
            holder = name
        case .vacant:
            roleText = "No device leads"
            holder = nil
        }
        if current.role != .vacant, let lease {
            heartbeat = UIFormat.relativeDay(lease.heartbeatAt, now: now)
            expires = UIFormat.relativeDay(lease.expiresAt, now: now)
        }
        canRelease = current.role == .leader
        canTakeOver = current.role == .follower
        let leaderID = current.role == .vacant ? nil : lease?.deviceID
        otherDevices = (status?.devices ?? []).filter { $0.deviceID != deviceID }
            .sorted { $0.lastSync > $1.lastSync }
            .map { device in
                UIDeviceRow(
                    id: device.deviceID, name: device.deviceName,
                    lastSync: UIFormat.relativeDay(device.lastSync, now: now), summary: device.summary,
                    isLeader: device.deviceID == leaderID)
            }
    }
}

/// Another device that syncs this folder (`.c2mdsync/devices/<id>.json`).
public struct UIDeviceRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// `Today 10:42 AM`.
    public var lastSync: String
    /// What its last sync did (`apple 0 changes, md 2 writes, …`).
    public var summary: String
    /// It holds the lease now.
    public var isLeader: Bool

    /// Creates a row.
    public init(id: String, name: String, lastSync: String, summary: String, isLeader: Bool) {
        self.id = id
        self.name = name
        self.lastSync = lastSync
        self.summary = summary
        self.isLeader = isLeader
    }
}
