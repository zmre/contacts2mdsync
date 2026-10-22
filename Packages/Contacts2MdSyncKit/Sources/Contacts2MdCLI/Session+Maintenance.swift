internal import Foundation
internal import SyncEngine

/// `contacts2md rescan` and `contacts2md reset-state` (this Mac's device state only).
extension Session {
    func rescan() -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
            do {
                let outcome = try session.rescanEverything()
                report.item(
                    "cleared", "cache",
                    "file cache (\(outcome.cachedFiles) files)"
                        + (outcome.appleMirror ? ", Contacts mirror and history token" : "") + ", image hashes")
                report.note("the next sync re-reads every note and takes a full Contacts snapshot")
                return .success
            } catch let blocked as MaintenanceBlocked {
                report.note(blocked.description)
                return .success
            }
        }
    }

    func resetState(confirmed: Bool) -> CLIExitCode {
        run { root in
            let session = VaultSession(root: root.url, environment: environment)
            guard confirmed else {
                guard let status = try session.storedStatus(), status.lastExport != nil || status.records > 0 else {
                    report.note("this Mac has no sync state for this folder; nothing to reset")
                    return .success
                }
                report.item(
                    "reset", "state",
                    "\(status.records) records, merge bases, caches and \(status.pendingReview) review items "
                        + "(this Mac only; a backup is saved first)")
                report.note("nothing changed; run `contacts2md reset-state --yes` to reset")
                return .success
            }
            do {
                let outcome = try session.resetSyncState()
                report.item("backup", "state", outcome.backup.path(percentEncoded: false))
                report.item(
                    "reset", "state",
                    "\(outcome.records) records, merge bases, caches and \(outcome.pendingReview) review items "
                        + "forgotten")
                report.note(
                    "the next run is this Mac's first export again: `contacts2md export --yes` (or Sync Now in the "
                        + "app) binds notes like a device joining the vault; nothing in the folder was changed")
                return .success
            } catch let blocked as MaintenanceBlocked {
                report.note(blocked.description)
                return .success
            }
        }
    }
}
