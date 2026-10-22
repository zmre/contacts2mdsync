import AppKit
import Contacts2MdCLI
import Foundation
import SyncEngine
import UniformTypeIdentifiers

// Settings ▸ Advanced (Rescan Everything, Reset Sync State), the Activity
// inspector's change list and File ▸ Export Log… (docs/ui.md §8, §9).

extension AppModel {
    /// Rescan Everything (confirmed in Settings): forgets this Mac's caches,
    /// then syncs (live sync hosted) or checks, which reads every note and
    /// all of Contacts again. Returns what to tell the user, or `nil` on error.
    func rescanEverything() async -> String? {
        guard let root = rootURL, phase == .idle, !live.state.isRunning else {
            errorMessage = "A sync is running. Try again when it finishes."
            return nil
        }
        do {
            let outcome = try await source.rescanEverything(root: root)
            let message =
                "Caches cleared (\(outcome.cachedFiles.formatted()) files). "
                + (live.isHosting
                    ? "Syncing now: every note and all of Contacts are read again."
                    : "The next check reads every note and all of Contacts again.")
            if live.isHosting { await live.syncNow() } else { await check() }
            return message
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    /// Reset Sync State (strongly confirmed in Settings): stops live sync,
    /// backs up and clears this Mac's state for the folder. The next Sync
    /// Now is this Mac's first sync again (binds notes like a joining device).
    func resetSyncState() async -> String? {
        guard let root = rootURL, phase == .idle, !live.state.isRunning else {
            errorMessage = "A sync is running. Try again when it finishes."
            return nil
        }
        await live.shutdown()
        do {
            let outcome = try await source.resetSyncState(root: root)
            await reload()
            await check()
            return "Sync state reset (\(outcome.records.formatted()) records forgotten). A backup was saved to "
                + "\(outcome.backup.lastPathComponent) in the backups folder. Sync Now runs this Mac's first sync "
                + "again; nothing in the notes folder was changed."
        } catch {
            errorMessage = Self.describe(error)
            await reload()
            return nil
        }
    }

    /// Shows a run and its changes in the inspector.
    func inspectActivity(_ row: UIActivityRow) async {
        var item = InspectorItem(row)
        if let root = rootURL, let session = data?.sessions.first(where: { $0.changeLogID == row.changeLogID }),
            row.changeLogID != nil
        {
            do {
                let changes = try await source.sessionChanges(of: session, root: root)
                item.changes = UIActivityChange.rows(changes, records: data?.records ?? RecordMap())
            } catch {
                errorMessage = Self.describe(error)
            }
        }
        inspect(item, open: true)
    }

    /// File ▸ Export Log…: asks where, then writes text (`.txt`) or JSON (`.json`).
    func exportLog() async {
        guard let root = rootURL else { return }
        let panel = NSSavePanel()
        panel.title = "Export Log"
        panel.nameFieldStringValue = "Contacts2MdSync Activity.txt"
        panel.allowedContentTypes = [.plainText, .json]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: UIActivityLogFormat = url.pathExtension.lowercased() == "json" ? .json : .text
        do {
            let text = try await source.activityLog(format: format, root: root)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = Self.describe(error)
        }
    }
}

// MARK: - Links to renamed contacts (Overview)

extension AppModel {
    /// Reads which other notes still link to renamed contacts' old titles
    /// (after runs and when the Overview appears; it reads those notes).
    func refreshRenamedLinks() async {
        guard let root = rootURL else { return }
        renamedLinks = (try? await source.renamedLinks(root: root)) ?? []
    }

    /// Update Links (confirmed): rewrites `[[Old…]]` to `[[New…]]` in those notes.
    func updateLinks(_ links: UIRenamedLinks) async {
        guard let root = rootURL else { return }
        do {
            let written = try await source.updateLinks(links, root: root)
            if written.count < links.paths.count {
                errorMessage =
                    "\(links.paths.count - written.count) notes changed meanwhile and were left as they are. "
                    + "Check again to see them."
            }
        } catch {
            errorMessage = Self.describe(error)
        }
        await refreshRenamedLinks()
    }

    /// Dismiss: the rename is no longer reported; the notes stay as they are.
    func dismissRename(_ links: UIRenamedLinks) async {
        guard let root = rootURL else { return }
        do {
            try await source.dismissRename(links.rename, root: root)
        } catch {
            errorMessage = Self.describe(error)
        }
        await refreshRenamedLinks()
    }
}
