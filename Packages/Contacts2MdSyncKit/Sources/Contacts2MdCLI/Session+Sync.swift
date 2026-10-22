internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

extension Session {
    /// `sync` (write: true) and the two-way `plan` (write: false), architecture §15.
    func sync(_ request: SyncRequest, write: Bool) -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
            var lock: LocalLock?
            defer { lock?.release() }
            if write {
                switch try session.beginSync(takeOver: request.takeOverLease) {
                case .localRunInProgress:
                    report.note("another sync is running on this Mac; skipped (nothing to do)")
                    return .success
                case .leaseHeldElsewhere(let lease):
                    follow(lease, request: request, session: session)
                    return .success
                case .ready(let acquired, _):
                    lock = acquired
                }
            }
            let prepared = try session.prepareSync(request)
            let plan = prepared.plan
            report.info("apple    \(prepared.apple.kind.summary)")
            report.notesPlan(plan)
            json?.setting("apple_read", prepared.apple.isComplete ? "full" : "incremental")
            json?.reviews(plan.markdown.reviews)
            json?.setting("apple_writes", plan.appleWritesEnabled ? "enabled" : "disabled")
            json?.setting("stamp_contacts", plan.stampContacts ? "true" : "false")
            for problem in prepared.decisionProblems { report.warning("decision", problem) }
            if let trip = plan.breaker {
                try session.recordSyncPlan(prepared, command: command, startedAt: startedAt)
                report.error(trip.message)
                return .breaker
            }
            guard write else {
                report.syncPlan(plan)
                try session.recordSyncPlan(prepared, command: command, startedAt: startedAt)
                report.syncSummary(plan: plan, result: nil, seconds: elapsed)
                let rootHint = options.root.map { " --root \($0)" } ?? ""
                report.note("dry run: nothing written; run `contacts2md sync\(rootHint)` to sync")
                return Self.exitCode(plan, failures: 0)
            }
            let result = try session.executeSync(prepared, command: command, startedAt: startedAt) { receipt in
                report.item(
                    "backup", "apple", "\(receipt.url.path(percentEncoded: false))  (\(receipt.byteCount) bytes)")
            }
            if let folder = result.markdown.noteBackup {
                report.item("backup", "md", "\(folder.path(percentEncoded: false))  (notes before rewrite)")
            }
            report.syncResult(result, of: plan)
            report.notesResult(prepared.notes.bridge?.log)
            report.syncSummary(plan: plan, result: result, seconds: elapsed)
            return Self.exitCode(plan, failures: result.markdown.failures.count + result.appleFailures.count)
        }
    }

    /// Another device leads: a read-only dry run so `review list` and the app
    /// show current status here; nothing is written. Always exit 0.
    private func follow(_ lease: VaultLease, request: SyncRequest, session: VaultSession) {
        let holder = LeaseHolder(lease, now: environment.clock.now)
        json?.setting("lease_role", LeaseRole.follower.rawValue)
        let stale = holder.isStale ? " (stale: no heartbeat since \(report.timestamp(holder.lastHeartbeat)))" : ""
        report.note(
            "following \(holder.deviceName): it leads syncing for this vault until "
                + "\(report.timestamp(holder.expiresAt))\(stale); this Mac only checks (dry run, nothing written). "
                + "Decisions recorded here are carried out by \(holder.deviceName). "
                + "`contacts2md lease take-over` (or --take-over) makes this Mac the leader")
        guard hasSynced(session.root), let prepared = try? session.followerDryRun(request, startedAt: startedAt)
        else { return }
        let plan = prepared.plan
        report.info(
            "follow   leader still to do: apple \(plan.apple.count) changes  md \(plan.markdown.creates.count) new, "
                + "\(plan.markdown.updates.count) updates  "
                + "review \(plan.markdown.reviews.filter(\.needsDecision).count)")
    }

    // MARK: - lease

    /// `lease status | take-over | release`.
    func lease(_ action: LeaseAction) -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
            guard try VaultConfig.load(from: environment.makeVault(root.url)) != nil else {
                throw VaultNotReady(description: "not configured: run the first export or sync once")
            }
            switch action {
            case .status:
                break
            case .takeOver:
                let status = try session.takeOverLease()
                guard status.role == .leader else {
                    report.error(
                        "take-over lost: \(status.holder?.deviceName ?? "another device") wrote the lease at the "
                            + "same time and kept it")
                    return .error
                }
                report.item("took", "lease", "this Mac now leads syncing for this vault")
            case .release:
                if try session.releaseLease() {
                    report.item("released", "lease", "another device may lead now")
                } else {
                    report.note("this Mac does not hold the lease; nothing to release")
                }
            }
            var stored = StoredStatus(lastExport: nil, records: 0, pendingReview: 0, pendingAsOf: nil)
            stored.apply(try session.leaseStatus())
            stored.devices = DeviceRecord.all(fs: environment.makeVault(root.url))
            reportLease(stored)
            return .success
        }
    }

    /// 5 failures, 2 blast radius, 1 review, else 0 (architecture §15).
    static func exitCode(_ plan: SyncPlan, failures: Int) -> CLIExitCode {
        if failures > 0 { return .error }
        if case .blastRadius? = plan.appleHold { return .partial }
        return plan.needsReview ? .needsReview : .success
    }

    /// Whether this vault has been exported/synced on this device (then
    /// `plan` shows the two-way plan; otherwise the first-import plan).
    func hasSynced(_ root: URL) -> Bool {
        let fs = environment.makeVault(root)
        guard let config = try? VaultConfig.load(from: fs)?.config else { return false }
        let directory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)),
            let state = try? environment.makeStateStore(directory)
        else { return false }
        return (try? state.load().lastExport) != nil
    }

    // MARK: - config

    func config(
        appleWrites: Switch?, stampContacts: Switch?, notes: Switch? = nil, quitContacts: Switch? = nil
    ) -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
            if notes != nil || quitContacts != nil {
                var settings = session.notesSettingsStore.load()
                if let notes { settings.notesSync = notes.value }
                if let quitContacts { settings.quitContactsAfterSync = quitContacts.value }
                try session.notesSettingsStore.save(settings)
                report.item(
                    "wrote", "settings",
                    "notes_sync=\(settings.notesSync ? "on" : "off")  "
                        + "quit_contacts_after_sync=\(settings.quitContactsAfterSync) (this Mac)")
            }
            let config: VaultConfig
            if appleWrites != nil || stampContacts != nil {
                config = try session.updateSettings { config in
                    if let appleWrites { config.appleWrites = appleWrites.value }
                    if let stampContacts { config.stampContacts = stampContacts.value }
                }
                report.item("wrote", "config", VaultConfig.path)
            } else {
                guard let loaded = try VaultConfig.load(from: environment.makeVault(root.url))?.config else {
                    throw VaultNotReady(description: "not configured: run the first export or sync once")
                }
                config = loaded
            }
            json?.setting("apple_writes", config.appleWrites ? "enabled" : "disabled")
            json?.setting("stamp_contacts", config.stampContacts ? "true" : "false")
            report.info(
                "config   apple_writes=\(config.appleWrites ? "enabled" : "disabled")"
                    + "  stamp_contacts=\(config.stampContacts)"
                    + "  max_apple_changes=\(config.limits.maxAppleChanges)")
            if appleWrites?.value == true {
                report.note(
                    "Apple writes enabled: every sync that changes Contacts first saves a vCard backup of all "
                        + "contacts; more than \(config.limits.maxAppleChanges) changes in one run are held for "
                        + "approval. Run `contacts2md plan` to preview.")
            }
            if stampContacts?.value == true, !config.appleWrites {
                report.note("stamp_contacts needs apple_writes enabled before stamps are written")
            }
            reportNotesSetting(session.notesSourceStatus(), changed: notes != nil)
            return .success
        }
    }
}
