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
        for change in plan.updates { item(Self.verb(change.kind, done: false), "md", Self.describe(change)) }
        for image in plan.images { item("write", "image", image.path) }
        if plan.configText != nil { item("write", "config", VaultConfig.path) }
        if stamping {
            for request in plan.stamps { item("stamp", "apple", request.title) }
        }
        reviews(plan)
    }

    func result(_ result: ExportResult, of plan: ExportPlan) {
        for change in result.created { item("created", "md", change.path) }
        for change in result.updated { item(Self.verb(change.kind, done: true), "md", Self.describe(change)) }
        for image in result.imagesWritten { item("wrote", "image", image.path) }
        if result.configWritten { item("wrote", "config", VaultConfig.path) }
        for failure in result.failures { error("\(failure.path): \(failure.message)") }
        reviews(plan)
    }

    private static func verb(_ kind: FileChangeKind, done: Bool) -> String {
        switch kind {
        case .create: done ? "created" : "create"
        case .update: done ? "updated" : "update"
        case .adopt: done ? "adopted" : "adopt"
        case .pathFixup: done ? "fixed" : "fixup"
        }
    }

    private static func describe(_ change: FileChange) -> String {
        switch change.kind {
        case .adopt:
            return "\(change.path)  ← \"\(change.title)\" \(change.detail ?? "")"
        case .pathFixup:
            return "\(change.path)  (image path after move)"
        case .create, .update:
            return "\(change.path)  (\(change.changedFields.joined(separator: ", ")))"
        }
    }

    func reviews(_ plan: ExportPlan) {
        if verbose {
            item("unchanged", "md", "\(plan.unchanged) notes already up to date")
            for line in plan.notes { note(line) }
        } else if !plan.moves.isEmpty {
            note("\(plan.moves.count) notes moved since the last export; updated in place (--verbose lists them)")
        }
        for review in plan.reviews { self.review(review) }
        for text in plan.warnings { warning("title", text) }
        for problem in plan.newProblems {
            warning("yaml", "\(problem.path): \(problem.problem) — not a contact note; reported once, never written")
        }
        if verbose, plan.knownProblemCount > 0 {
            note("\(plan.knownProblemCount) non-contact notes with invalid frontmatter (reported before)")
        }
        if plan.markdownOnly > 0 {
            warning("pending", "\(plan.markdownOnly) markdown-only contact notes are not linked to Contacts")
        }
        if plan.excludedByDecision > 0 || plan.ignoredCandidates > 0 {
            note(
                "decisions: \(plan.excludedByDecision) contacts excluded (sync only), "
                    + "\(plan.ignoredCandidates) notes ignored")
        }
    }

    private func review(_ review: ReviewItem) {
        let id = "[\(review.id)]"
        switch review {
        case .duplicateCluster:
            warning(
                "duplicate", "\(review.summary) — one note only; link them in Contacts or `review decide` \(id)")
        case .possibleMatch:
            warning("match", "\(review.summary) — not created; `review decide` \(id)")
        case .duplicateSyncID:
            warning("copied", "\(review.summary) — skipped; `review decide` \(id)")
        case .mergeRecords:
            warning("duplicate", "\(review.summary) — both notes left alone; resolve in the app (M4) \(id)")
        case .missingFile:
            warning("missing", "\(review.summary) — not re-created (use --restore-missing) \(id)")
        case .unreadableFile:
            warning("invalid", "\(review.summary) — never written \(id)")
        case .undownloaded(let paths):
            warning(
                "icloud",
                "\(review.summary) (\(paths.prefix(3).joined(separator: ", "))\(paths.count > 3 ? ", …" : "")); "
                    + "download requested; new notes held back until a later run (or --allow-undownloaded) \(id)")
        }
    }

    /// `summary  apple c/u/d …  md c/u/d …  adopted …  unchanged …  skipped …  pending-review …  0.4s`
    func summary(plan: ExportPlan, result: ExportResult?, stamped: Int, seconds: TimeInterval) {
        let created = result?.created.count ?? plan.creates.count
        let changes = result?.updated ?? plan.updates
        let adopted = changes.filter { $0.kind == .adopt }.count
        info(
            "summary  apple c/u/d 0/\(stamped)/0  md c/u/d \(created)/\(changes.count - adopted)/0"
                + "  adopted \(adopted)  unchanged \(plan.unchanged)"
                + "  skipped \(plan.skipped.filter(\.needsReview).count)"
                + "  pending-review \(plan.reviews.count)  \(String(format: "%.1fs", seconds))")
    }
}
