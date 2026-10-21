internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

extension Session {
    /// `plan` (write: false) and `export` (write: true).
    func export(_ request: ExportRequest, write: Bool, stamp: Bool, backup: Bool) -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
            let prepared = try session.prepare(request, forWriting: write)
            let plan = prepared.plan
            for problem in prepared.decisionProblems { report.warning("decision", problem) }
            guard write else {
                report.plan(plan, stamping: stamp)
                try session.recordPlan(prepared, command: command, startedAt: startedAt)
                report.summary(plan: plan, result: nil, stamped: 0, seconds: elapsed)
                let rootHint = options.root.map { " --root \($0)" } ?? ""
                report.note("dry run: nothing written; run `contacts2md export --yes\(rootHint)` to write")
                return plan.needsReview ? .needsReview : .success
            }
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
            for request in outcome.stampedRequests { report.item("stamped", "apple", request.title) }
            for failure in outcome.stampFailures { report.warning("stamp", failure) }
            report.summary(plan: plan, result: outcome.result, stamped: outcome.stamped, seconds: elapsed)
            if !outcome.result.failures.isEmpty { return .error }
            return plan.needsReview || !outcome.stampFailures.isEmpty ? .needsReview : .success
        }
    }
}
