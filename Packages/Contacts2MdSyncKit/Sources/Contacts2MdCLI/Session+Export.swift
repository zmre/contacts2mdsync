internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

extension Session {
    /// `plan` (write: false) and `export` (write: true). Before writing it
    /// takes the local lock and the vault lease, like `sync`: while another
    /// device leads, it prints a note and exits 0 without writing.
    func export(
        _ request: ExportRequest, write: Bool, stamp: Bool, backup: Bool, takeOver: Bool = false
    ) -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
            // Plan first (reads Contacts; nothing is written to the vault), so a
            // run that cannot read Contacts leaves no lease behind either.
            let prepared = try session.prepare(request, forWriting: write)
            let plan = prepared.plan
            guard write else {
                json?.reviews(plan.reviews)
                for problem in prepared.decisionProblems { report.warning("decision", problem) }
                report.plan(plan, stamping: stamp)
                try session.recordPlan(prepared, command: command, startedAt: startedAt)
                report.summary(plan: plan, result: nil, stamped: 0, seconds: elapsed)
                let rootHint = options.root.map { " --root \($0)" } ?? ""
                report.note("dry run: nothing written; run `contacts2md export --yes\(rootHint)` to write")
                return plan.needsReview ? .needsReview : .success
            }
            let lock: LocalLock
            switch try session.beginExport(takeOver: takeOver) {
            case .localRunInProgress:
                report.note("another sync is running on this Mac; skipped (nothing written)")
                return .success
            case .leaseHeldElsewhere(let lease):
                leaderElsewhere(lease)
                return .success
            case .ready(let acquired, _):
                lock = acquired
            }
            defer { lock.release() }
            json?.reviews(plan.reviews)
            for problem in prepared.decisionProblems { report.warning("decision", problem) }
            let outcome = try session.execute(
                prepared, backupContacts: backup, stamp: stamp, command: command, startedAt: startedAt
            ) { receipt in
                report.item(
                    "backup", "apple", "\(receipt.url.path(percentEncoded: false))  (\(receipt.byteCount) bytes)")
            }
            if let folder = outcome.result.noteBackup {
                report.item("backup", "md", "\(folder.path(percentEncoded: false))  (notes before rewrite)")
            }
            report.result(outcome.result, of: plan)
            report.stamps(outcome)
            report.summary(plan: plan, result: outcome.result, stamped: outcome.stamped, seconds: elapsed)
            if !outcome.result.failures.isEmpty { return .error }
            return plan.needsReview || !outcome.stampFailures.isEmpty ? .needsReview : .success
        }
    }

    /// Another device leads: the export writes nothing (exit 0).
    private func leaderElsewhere(_ lease: VaultLease) {
        let holder = LeaseHolder(lease, now: environment.clock.now)
        json?.setting("lease_role", LeaseRole.follower.rawValue)
        let stale = holder.isStale ? " (stale: no heartbeat since \(report.timestamp(holder.lastHeartbeat)))" : ""
        report.note(
            "following \(holder.deviceName): it leads syncing for this vault until "
                + "\(report.timestamp(holder.expiresAt))\(stale); export skipped (nothing written). "
                + "Run it again once \(holder.deviceName) stops leading, or take the lease with "
                + "`contacts2md lease take-over` (or --take-over)")
    }
}
