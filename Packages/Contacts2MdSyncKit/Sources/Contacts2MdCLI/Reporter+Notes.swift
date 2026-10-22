internal import ContactModel
internal import Foundation
internal import SyncEngine

/// Contacts notes lines (architecture §8, §15).
extension Reporter {
    /// `notes …` lines before the plan or result: the source, a skip
    /// warning, and the baseline summary (the enablement migration).
    func notesPlan(_ plan: SyncPlan) {
        let notes = plan.notes
        json?.setting("notes", notes.source?.rawValue ?? (notes.skipped == nil ? "off" : "skipped"))
        if let skipped = notes.skipped {
            warning("notes", skipped)
            return
        }
        guard let source = notes.source else { return }
        let baseline = plan.notesBaseline
        if notes.freshStart {
            info(
                "notes    \(source.displayName): first notes sync on this Mac; every body is merged without a base")
            info("notes    \(baseline.summary)")
        } else if verbose || baseline.hasChanges {
            info(
                "notes    \(source.displayName)"
                    + (baseline.hasChanges ? "; no notes base yet: \(baseline.summary)" : ""))
        }
        for entry in baseline.toContacts {
            item(
                "notes", "apple",
                "\(entry.title)  (markdown body → Contacts: \(NotesBaseline.format(entry.characters)) chars, "
                    + "\(entry.lines) lines)  \(entry.path)")
        }
        if verbose {
            for entry in baseline.toMarkdown {
                item(
                    "notes", "md",
                    "\(entry.path)  (Contacts note → markdown: \(NotesBaseline.format(entry.characters)) chars)")
            }
        }
        if !baseline.toContacts.isEmpty, !plan.appleWritesAllowed, let hold = plan.appleHold {
            note("\(baseline.toContacts.count) markdown bodies held for Contacts — \(hold.reason)")
        }
    }

    /// Warnings from note writes after a run.
    func notesResult(_ log: NotesRunLog?) {
        guard let log else { return }
        for text in log.writeWarnings { warning("notes", text) }
        if verbose {
            info(
                "notes    read \(log.bulkReads) bulk + \(log.cardReads) cards, own echoes \(log.ownWritesSeen), "
                    + "written \(log.written)")
        }
    }

    /// `body 1,234 chars` / `body cleared` for an Apple update carrying a note.
    static func bodyDetail(_ change: AppleRecordChange) -> String? {
        for operation in change.operations {
            guard case .update(_, let edits) = operation else { continue }
            for edit in edits {
                guard case .note(let text) = edit else { continue }
                let key = ComparisonKeys.body(text)
                return key.isEmpty ? "body cleared" : "body \(NotesBaseline.format(key.count)) chars"
            }
        }
        return nil
    }
}

extension Session {
    /// `notes    notes_sync=on  source=…  permission=…` and what to do next.
    func reportNotesSetting(_ status: NotesSourceStatus, changed: Bool) {
        json?.setting("notes_sync", status.settings.notesSync ? "on" : "off")
        json?.setting("notes_source", status.source?.rawValue ?? "off")
        let source = status.source?.displayName ?? "off (bodies are markdown-only)"
        report.info(
            "notes    notes_sync=\(status.settings.notesSync ? "on" : "off")  source=\(source)"
                + (status.entitled ? "" : "  permission=\(status.permission.rawValue)")
                + (status.settings.notesSync && !status.entitled
                    ? "  quit_contacts_after_sync=\(status.settings.quitContactsAfterSync)" : ""))
        guard changed, status.settings.notesSync, !status.entitled else { return }
        switch status.permission {
        case .granted:
            break
        case .denied:
            report.note(
                "Automation permission for Contacts is denied: allow it in System Settings ▸ Privacy & Security ▸ "
                    + "Automation ▸ Contacts2MdSync ▸ Contacts. Until then syncs skip notes with a warning.")
        case .notDetermined, .unknown:
            report.note(
                "this Mac must allow Contacts2MdSync to control Contacts: open the app ▸ Settings ▸ Advanced ▸ "
                    + "Contact notes (the command line never asks). Until then syncs skip notes with a warning.")
        }
        report.note(
            "the first sync with notes merges every body without a base (Contacts note into empty markdown, "
                + "markdown body into empty Contacts note, different texts → conflict): preview it with "
                + "`contacts2md plan`")
    }
}
