internal import ContactModel
internal import Foundation
internal import SyncEngine

/// Formats CLI output (architecture §15): one line per item with stable,
/// column-aligned prefixes so `grep` works and cron mail is readable.
/// `WARNING` lines always print (stdout); everything else is suppressed by
/// `--quiet`. Errors go to stderr.
struct Reporter {
    let output: CLIOutput
    let quiet: Bool
    let verbose: Bool
    let timeZone: TimeZone

    func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func info(_ text: String) {
        if !quiet { output.line(text) }
    }

    func note(_ text: String) { info("note     " + text) }

    func error(_ text: String) { output.error("error    " + text) }

    /// `verb side text`, e.g. `created  md     Inbox/Jane Doe.md`.
    func item(_ verb: String, _ side: String, _ text: String) {
        info(pad(verb, 8) + " " + pad(side, 6) + " " + text)
    }

    func warning(_ kind: String, _ text: String) {
        output.line("WARNING  " + pad(kind, 10) + " " + text)
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
    }

    // MARK: - Plans and results

    func plan(_ plan: ExportPlan, stamping: Bool) {
        for change in plan.creates { item("create", "md", change.path) }
        for change in plan.updates { item("update", "md", Self.describe(change)) }
        for image in plan.images { item("write", "image", image.path) }
        if plan.configText != nil { item("write", "config", VaultConfig.path) }
        if stamping {
            for request in plan.stamps { item("stamp", "apple", request.title) }
        }
        reviews(plan)
    }

    func result(_ result: ExportResult, of plan: ExportPlan) {
        for change in result.created { item("created", "md", change.path) }
        for change in result.updated { item("updated", "md", Self.describe(change)) }
        for image in result.imagesWritten { item("wrote", "image", image.path) }
        if result.configWritten { item("wrote", "config", VaultConfig.path) }
        for failure in result.failures { error("\(failure.path): \(failure.message)") }
        reviews(plan)
    }

    private static func describe(_ change: FileChange) -> String {
        "\(change.path)  (\(change.changedFields.joined(separator: ", ")))"
    }

    func reviews(_ plan: ExportPlan) {
        if verbose { item("unchanged", "md", "\(plan.unchanged) notes already up to date") }
        for review in plan.reviews { self.review(review) }
        for text in plan.warnings { warning("title", text) }
        if plan.markdownOnly > 0 {
            warning("pending", "\(plan.markdownOnly) markdown-only contact notes are not linked to Contacts (M2)")
        }
    }

    private func review(_ review: ReviewItem) {
        switch review {
        case .duplicateCluster(let members, let reasons):
            let names = members.map { member in
                "\"\(member.title)\" (\(member.accounts.map(\.displayName).joined(separator: "+")))"
            }
            warning(
                "duplicate",
                "\(names.joined(separator: ", ")) look like one person (\(reasons.joined(separator: ", ")))"
                    + " — one note only; link them in Contacts or review in app")
        case .possibleMatch(let title, let path, let reason):
            warning("match", "\"\(title)\" may already exist as \(path) (\(reason)) — not created, review in app")
        case .duplicateSyncID(let id, let paths):
            warning(
                "copied",
                "\(paths.count) notes share mdsync id \(id.uuidString.lowercased()): "
                    + "\(paths.joined(separator: ", ")) — skipped")
        case .multipleStamps(let title, let ids):
            warning("stamps", "\"\(title)\" carries \(ids.count) different sync stamps — skipped")
        case .missingFile(let title, _, let lastPath):
            warning(
                "missing", "\"\(title)\": note \(lastPath ?? "") was deleted — not re-created (use --restore-missing)")
        case .unreadableFile(let path, let problem):
            warning("invalid", "\(path): \(problem) — never written")
        }
    }

    /// `summary  apple c/u/d …  md c/u/d …  unchanged …  skipped …  pending-review …  0.4s`
    func summary(plan: ExportPlan, result: ExportResult?, stamped: Int, seconds: TimeInterval) {
        let created = result?.created.count ?? plan.creates.count
        let updated = result?.updated.count ?? plan.updates.count
        info(
            "summary  apple c/u/d 0/\(stamped)/0  md c/u/d \(created)/\(updated)/0"
                + "  unchanged \(plan.unchanged)  skipped \(plan.skipped.count)"
                + "  pending-review \(plan.reviews.count)  \(String(format: "%.1fs", seconds))")
    }
}
