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
                    report.note(
                        "\(lease.deviceName) leads syncing for this vault until \(report.timestamp(lease.expiresAt)); "
                            + "skipped (--take-over to take the lease)")
                    return .success
                case .ready(let acquired, _):
                    lock = acquired
                }
            }
            let prepared = try session.prepareSync(request)
            let plan = prepared.plan
            report.info("apple    \(prepared.apple.kind.summary)")
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
            report.syncSummary(plan: plan, result: result, seconds: elapsed)
            return Self.exitCode(plan, failures: result.markdown.failures.count + result.appleFailures.count)
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

    func config(appleWrites: Switch?, stampContacts: Switch?) -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
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
            return .success
        }
    }
}
