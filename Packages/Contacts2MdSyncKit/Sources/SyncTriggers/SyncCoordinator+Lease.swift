public import SyncEngine

// The vault lease (architecture §11, M6): the coordinator owns a
// `LeaseKeeper`, heartbeats while it is alive, notices another leader (and
// when that leader stops), takes over on request and releases on shutdown.

extension SyncCoordinator {
    /// Starts the heartbeat loop (once; no-op without a keeper).
    func startHeartbeats() {
        guard let leaseKeeper, heartbeatTask == nil else { return }
        let clock = clock
        let interval = leaseKeeper.heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(until: clock.now.addingTimeInterval(interval)) } catch { return }
                await self?.leaseTick()
            }
        }
    }

    /// One heartbeat: refresh our lease, or notice another leader (or that
    /// the other leader's lease lapsed, then take over with a catch-up run).
    public func leaseTick() async {
        guard let leaseKeeper, !stopped else { return }
        let previous = leaseStatus
        let status = await Task.detached { leaseKeeper.heartbeat() }.value
        guard !stopped else { return }
        leaseStatus = status
        switch status.role {
        case .follower:
            if let holder = status.holder, previous?.role != .follower, current == nil {
                emit(.following(device: holder))
            }
        case .vacant where previous?.role == .follower:
            let name = previous?.holder?.deviceName ?? "the other device"
            submit(SyncTrigger(.launch, reason: "\(name) stopped leading; taking over"))
        case .vacant, .leader:
            break
        }
    }

    /// Take Over: makes this device the leader (write, settle, re-read),
    /// then syncs at once. Throws when the lease file cannot be written.
    @discardableResult
    public func takeOver() async throws -> LeaseStatus? {
        guard let leaseKeeper else {
            syncNow()
            return nil
        }
        let status = try await Task.detached { try leaseKeeper.takeOver() }.value
        leaseStatus = status
        if status.role == .leader { syncNow() }
        return status
    }

    /// Gives the lease up (no runs are stopped; the next run takes it again
    /// unless another device does first).
    @discardableResult
    public func releaseLease() async -> LeaseStatus? {
        guard let leaseKeeper else { return nil }
        let status = await Task.detached { leaseKeeper.release() }.value
        leaseStatus = status
        return status
    }
}
