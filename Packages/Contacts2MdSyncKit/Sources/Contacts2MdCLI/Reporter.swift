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
    /// `--json`: lines are collected into one document instead of printed.
    var json: JSONReport?

    func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func info(_ text: String) {
        if json != nil { return }
        if !quiet { output.line(text) }
    }

    func note(_ text: String) {
        json?.note(text)
        info("note     " + text)
    }

    func error(_ text: String) {
        json?.error(text)
        output.error("error    " + text)
    }

    /// `verb side text`, e.g. `created  md     Inbox/Jane Doe.md`.
    func item(_ verb: String, _ side: String, _ text: String) {
        json?.item(verb: verb, side: side, text: text)
        info(pad(verb, 8) + " " + pad(side, 6) + " " + text)
    }

    func warning(_ kind: String, _ text: String) {
        if let json {
            json.warning(kind: kind, text: text)
            return
        }
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
        versionPlan(plan)
        if stamping {
            for request in plan.stamps { item("stamp", "apple", request.title) }
        }
        reviews(plan)
    }

    func result(_ result: ExportResult, of plan: ExportPlan) {
        markdownResult(result)
        reviews(plan)
    }

    func markdownResult(_ result: ExportResult) {
        for change in result.created { item("created", "md", change.path) }
        for change in result.updated { item(Self.verb(change.kind, done: true), "md", Self.describe(change)) }
        for image in result.imagesWritten { item("wrote", "image", image.path) }
        if result.configWritten { item("wrote", "config", VaultConfig.path) }
        for resolution in result.versionsResolved { item("resolved", "md", Self.describe(resolution)) }
        for failure in result.failures { error("\(failure.path): \(failure.message)") }
    }

    /// `resolve md <path>  (iCloud versions: …)` lines of a plan.
    func versionPlan(_ plan: ExportPlan) {
        for resolution in plan.versionResolutions { item("resolve", "md", Self.describe(resolution)) }
    }

    private static func describe(_ resolution: FileVersionResolution) -> String {
        let what =
            resolution.keep == nil
            ? (resolution.reason == "identical" ? "identical iCloud versions; current kept" : "current kept (decision)")
            : "iCloud version kept (decision)"
        return "\(resolution.path)  (\(what))"
    }

    private static func verb(_ kind: FileChangeKind, done: Bool) -> String {
        switch kind {
        case .create: done ? "created" : "create"
        case .update: done ? "updated" : "update"
        case .adopt: done ? "adopted" : "adopt"
        case .pathFixup: done ? "fixed" : "fixup"
        case .detach: done ? "detached" : "detach"
        case .link: done ? "linked" : "link"
        }
    }

    private static func describe(_ change: FileChange) -> String {
        switch change.kind {
        case .adopt:
            return "\(change.path)  ← \"\(change.title)\" \(change.detail ?? "")"
        case .pathFixup:
            return "\(change.path)  (image path after move)"
        case .detach:
            return "\(change.path)  (\(change.detail ?? "no longer synced"))"
        case .create, .update, .link:
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
        groupChanges(plan.groupChanges)
        for text in plan.warnings { warning("title", text) }
        for problem in plan.newProblems {
            warning("yaml", "\(problem.path): \(problem.problem) — not a contact note; reported once, never written")
        }
        if verbose, plan.knownProblemCount > 0 {
            note("\(plan.knownProblemCount) non-contact notes with invalid frontmatter (reported before)")
        }
        if plan.markdownOnly > 0 {
            warning("pending", "\(plan.markdownOnly) markdown-only files await review")
        }
        if plan.excludedByDecision > 0 || plan.ignoredCandidates > 0 {
            note(
                "decisions: \(plan.excludedByDecision) contacts excluded (sync only), "
                    + "\(plan.ignoredCandidates) notes ignored")
        }
    }

    /// Apple groups renamed (a note line) or deleted (a warning) since the last run.
    private func groupChanges(_ changes: [GroupChange]) {
        for change in changes {
            if change.kind == .deleted { warning("group", change.summary) } else { note(change.summary) }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
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
        case .conflict:
            warning("conflict", "\(review.summary) — skipped, resolve in app or `review decide` \(id)")
        case .appleDeleted:
            warning("delete", "\(review.summary), confirm in app or `review decide` \(id)")
        case .markdownDeleted:
            warning("delete", "\(review.summary), confirm in app or `review decide` \(id)")
        case .markdownOnly:
            break  // summarized in one `pending` line
        case .fileVersionConflict:
            warning("version", "\(review.summary) — record paused; keep one in the app or `review decide` \(id)")
        case .accountMissing:
            break  // one `account` line per account (syncWarnings)
        }
    }

    /// `summary  apple c/u/d …  md c/u/d …  adopted …  unchanged …  skipped …  pending-review …  0.4s`
    /// The stamp lines of `export --stamp`: stamped, failed, and held (a
    /// card with a note waiting for permission to control Contacts.app).
    func stamps(_ outcome: ExportOutcome) {
        for request in outcome.stampedRequests { item("stamped", "apple", request.title) }
        for failure in outcome.stampFailures { warning("stamp", failure) }
        for held in outcome.stampsHeld { item("held", "apple", "\(held.request.title) — \(held.reason)") }
        contactsControlWarning(reasons: outcome.stampsHeld.map(\.reason))
    }

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

// MARK: - Two-way sync

extension Reporter {
    private static func appleVerb(_ kind: AppleChangeKind, done: Bool) -> String {
        switch kind {
        case .update: done ? "updated" : "update"
        case .create: done ? "created" : "create"
        case .delete: done ? "deleted" : "delete"
        case .stamp: done ? "stamped" : "stamp"
        case .unstamp: done ? "unstamped" : "unstamp"
        }
    }

    private static func describe(_ change: AppleRecordChange) -> String {
        let detail = bodyDetail(change)
        let fields = change.fields.filter { $0 != "stamp" }.map { $0 == "body" ? detail ?? $0 : $0 }
        return fields.isEmpty || change.kind != .update
            ? change.title : "\(change.title)  (\(fields.joined(separator: ", ")))"
    }

    /// The dry-run lines of a two-way plan.
    func syncPlan(_ plan: SyncPlan) {
        let markdown = plan.markdown
        for change in markdown.creates { item("create", "md", change.path) }
        for change in markdown.updates { item(Self.verb(change.kind, done: false), "md", Self.describe(change)) }
        for image in markdown.images { item("write", "image", image.path) }
        if markdown.configText != nil { item("write", "config", VaultConfig.path) }
        versionPlan(markdown)
        for trash in plan.trash { item("trash", "md", "\(trash.path)  (deleted in Contacts)") }
        if plan.appleWritesAllowed {
            for change in plan.apple { item(Self.appleVerb(change.kind, done: false), "apple", Self.describe(change)) }
        } else {
            held(plan)
        }
        syncWarnings(plan)
    }

    /// `timing   lock 0.00s  scan 0.42s  contacts 3.10s  …  total 4.71s` (`--verbose` only).
    func timings(_ timings: PhaseTimings) {
        guard verbose, !timings.entries.isEmpty else { return }
        info("timing   \(timings.line)  total \(String(format: "%.2f", timings.total))s")
    }

    /// One `WARNING held` line when writes wait for permission to control
    /// Contacts.app (architecture §6 "Write routing").
    func contactsControlWarning(reasons: [String]) {
        guard reasons.contains(CardWriteRouter.permissionReason) else { return }
        warning(
            "held",
            "contacts with notes are edited through Contacts.app: allow Contacts2MdSync to control Contacts "
                + "(open the app: Settings ▸ Accounts, or System Settings ▸ Privacy & Security ▸ Automation)")
    }

    /// The lines of an executed sync.
    func syncResult(_ result: SyncResult, of plan: SyncPlan) {
        markdownResult(result.markdown)
        for trash in result.trashed { item("trashed", "md", "\(trash.path)  (deleted in Contacts; in the Trash)") }
        for change in result.apple { item(Self.appleVerb(change.kind, done: true), "apple", Self.describe(change)) }
        for failure in result.appleFailures { error("apple: \(failure)") }
        for held in result.appleHeld { item("held", "apple", "\(held.title) — \(held.reason)") }
        contactsControlWarning(reasons: result.appleHeld.map(\.reason))
        for path in result.skippedLinks { warning("create", "\(path): contact not created; note left unlinked") }
        for entry in result.newUnapplyable {
            warning("unapplyable", "\(entry.field) not kept by card \(entry.cardID) — not retried while unchanged")
        }
        if !plan.appleWritesAllowed { held(plan) }
        syncWarnings(plan)
    }

    /// `held apple …` lines (stamps summarized in one line).
    private func held(_ plan: SyncPlan) {
        guard let hold = plan.appleHold, !plan.apple.isEmpty else { return }
        let stamps = plan.apple.filter { $0.kind == .stamp }
        for change in plan.apple where change.kind != .stamp {
            item("held", "apple", "\(Self.describe(change)) — \(hold.reason)")
        }
        if !stamps.isEmpty { item("held", "apple", "\(stamps.count) stamps — \(hold.reason)") }
        switch hold {
        case .appleWritesDisabled:
            let count = plan.apple.count
            item(
                "held", "apple",
                "\(count) \(count == 1 ? "change" : "changes") (\(AppleRecordChange.kindSummary(plan.apple))): "
                    + "apple_writes is disabled — enable with `contacts2md config --apple-writes enabled`")
        case .blastRadius(let count, let limit):
            warning(
                "limit",
                "\(count) Apple changes exceed the limit of \(limit) — Apple writes skipped, markdown "
                    + "written; review with `contacts2md plan`, then rerun with --max-apple-changes \(count)")
        }
    }

    private func syncWarnings(_ plan: SyncPlan) {
        accounts(plan)
        reviews(plan.markdown)
        for text in plan.blocked { warning("blocked", text + " — kept in markdown") }
        if let warning = plan.identityWarning { self.warning("identity", warning) }
        if !plan.awaitingDeleteConfirmation.isEmpty {
            note(
                "\(plan.awaitingDeleteConfirmation.count) contacts missing from Contacts; confirmed as deleted "
                    + "only if still missing 10 minutes from first seen")
        }
    }

    /// `WARNING account …` per unavailable account (not an error: its cards
    /// are kept as last seen), and the Apple changes held for it.
    private func accounts(_ plan: SyncPlan) {
        for status in plan.accounts {
            guard !status.isReturning else {
                warning("account", status.message)
                continue
            }
            let id = AccountMissingReview.idPrefix + status.account.containerID
            warning(
                "account",
                "\(status.message) (\(AccountGuard.count(status.frozenRecords, "contact")) only there, "
                    + "\(AccountGuard.count(status.linkedRecords)) linked). \(status.hint), or forget it: "
                    + "`review decide \(id) forget` [\(id)]")
        }
        for change in plan.accountHeld {
            item(
                "held", "apple",
                "\(change.title)  (\(change.fields.joined(separator: ", "))) — \(change.account) not visible")
        }
    }

    /// `summary  apple c/u/d …  md c/u/d …  skipped …  pending-review …  held …  2.4s`
    func syncSummary(plan: SyncPlan, result: SyncResult?, seconds: TimeInterval) {
        let apple = result?.apple ?? (plan.appleWritesAllowed ? plan.apple : [])
        let count = { (kinds: Set<AppleChangeKind>) in apple.filter { kinds.contains($0.kind) }.count }
        let markdownCreated = result?.markdown.created.count ?? plan.markdown.creates.count
        let markdownUpdated = result?.markdown.updated.count ?? plan.markdown.updates.count
        let trashed = result?.trashed.count ?? plan.trash.count
        let held =
            (plan.appleWritesAllowed ? 0 : plan.apple.count) + plan.accountHeld.count + (result?.appleHeld.count ?? 0)
        let pending = plan.markdown.reviews.filter(\.needsDecision).count
        let line =
            "summary  apple c/u/d \(count([.create]))/\(count([.update, .stamp, .unstamp]))/\(count([.delete]))"
            + "  md c/u/d \(markdownCreated)/\(markdownUpdated)/\(trashed)"
            + "  skipped \(plan.markdown.skipped.filter(\.needsReview).count)  pending-review \(pending)"
            + "  held \(held)  \(String(format: "%.1fs", seconds))"
        json?.summary(line)
        info(line)
    }
}
