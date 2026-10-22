public import ContactModel
public import Foundation
public import SyncEngine
internal import SyncTriggers
internal import VaultIndex

/// Created / updated / deleted counts for one side.
public struct UIChangeCounts: Codable, Hashable, Sendable {
    public var created: Int
    public var updated: Int
    public var deleted: Int

    /// Creates counts.
    public init(created: Int = 0, updated: Int = 0, deleted: Int = 0) {
        self.created = created
        self.updated = updated
        self.deleted = deleted
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(created: lhs.created + rhs.created, updated: lhs.updated + rhs.updated, deleted: lhs.deleted + rhs.deleted)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }

    /// `0/2/0`.
    public var text: String { "\(created)/\(updated)/\(deleted)" }

    public var isZero: Bool { created == 0 && updated == 0 && deleted == 0 }
}

// MARK: - Overview (docs/ui.md §3)

/// The Overview screen.
public struct UIOverview: Sendable {
    /// The headline state.
    public enum Health: Hashable, Sendable {
        /// Nothing to write, nothing to review.
        case inSync
        /// The next sync (or export) would change this many notes or contacts.
        case changesWaiting(Int)
        /// Items wait in Review.
        case needsReview(Int)
        /// Not exported from this Mac yet.
        case neverExported
    }

    /// One "Needs Review" row.
    public struct ReviewRow: Hashable, Sendable, Identifiable {
        public var queue: UIReviewQueue
        public var title: String
        public var count: Int

        public var id: UIReviewQueue { queue }
    }

    /// The "This Session" table.
    public struct SessionTable: Hashable, Sendable {
        /// `This Session` or `Last Sync`.
        public var heading: String
        public var contacts: UIChangeCounts
        public var markdown: UIChangeCounts
        public var adopted: Int
        /// Apple changes held (writes off or over the limit).
        public var held: Int
    }

    public var health: Health
    /// Last sync or export on this Mac.
    public var lastExport: Date?
    public var lastDuration: TimeInterval?
    public var deviceName: String
    /// Only non-zero queues, in sidebar order.
    public var needsReview: [ReviewRow]
    /// From the latest dry run (`nil` until one finished): notes the next run writes.
    public var changedInContacts: Int?
    /// From the latest two-way dry run: Apple changes from markdown edits
    /// (`nil` until one finished, or before the first sync on this Mac).
    public var changedInMarkdown: Int?
    /// Of those, how many are held (Apple writes off or over the limit).
    public var appleHeld: Int
    public var toAdopt: Int
    public var movedNotes: Int
    /// Notes the next sync moves to the Trash (confirmed deletions).
    public var toTrash: Int
    public var planComputedAt: Date?
    public var session: SessionTable?
    public var syncedContacts: Int
    public var rootPath: String
    /// Several devices share this folder but contacts carry no sync ids.
    public var multiDeviceWithoutStamps: Bool
    /// `apple_writes` is on.
    public var appleWritesEnabled: Bool

    /// Builds the overview. `sessionStart` is when the app launched.
    public init(data: UIVaultData, plan: UIPlanSummary?, counts: UIReviewCounts, sessionStart: Date) {
        let runs = data.sessions.filter { $0.command != "plan" }
        lastExport = data.records.lastExport
        lastDuration = runs.first.map { $0.finishedAt.timeIntervalSince($0.startedAt) }
        deviceName = data.device.name
        needsReview = UIReviewQueue.allCases.compactMap { queue in
            counts[queue] > 0 ? ReviewRow(queue: queue, title: Self.title(queue), count: counts[queue]) : nil
        }
        changedInContacts = plan.map { $0.toCreate + $0.toUpdate }
        changedInMarkdown = plan?.sync?.changedInMarkdown
        appleHeld = plan?.sync?.held ?? 0
        toAdopt = plan?.toAdopt ?? 0
        movedNotes = plan?.moves ?? 0
        toTrash = plan?.sync?.trash ?? 0
        planComputedAt = plan?.computedAt
        syncedContacts = data.records.records.count
        rootPath = data.rootPath
        appleWritesEnabled = data.config.appleWrites
        multiDeviceWithoutStamps = data.deviceCount > 1 && !data.config.stampContacts
        if data.records.lastExport == nil {
            health = .neverExported
        } else if counts.total > 0 {
            health = .needsReview(counts.total)
        } else if let plan, plan.pendingChanges > 0 {
            health = .changesWaiting(plan.pendingChanges)
        } else {
            health = .inSync
        }
        let thisSession = runs.filter { $0.startedAt >= sessionStart }
        if !thisSession.isEmpty {
            session = Self.table("This Session", thisSession, details: data.sessionDetails)
        } else if let last = runs.first {
            session = Self.table(
                last.command == "sync" ? "Last Sync" : "Last Export", [last], details: data.sessionDetails)
        }
    }

    /// Sidebar / Overview wording for a queue.
    public static func title(_ queue: UIReviewQueue) -> String {
        switch queue {
        case .conflicts: "Conflicts"
        case .markdownOnly: "In markdown only"
        case .deletions: "Pending deletions"
        case .duplicates: "Possible duplicates"
        }
    }

    private static func table(
        _ heading: String, _ sessions: [SessionRecord], details: [UISessionDetail]
    )
        -> SessionTable
    {
        var table = SessionTable(
            heading: heading, contacts: UIChangeCounts(), markdown: UIChangeCounts(), adopted: 0, held: 0)
        for session in sessions {
            let split = UISessionSplit(session, details: details)
            table.contacts += split.contacts ?? UIChangeCounts()
            table.markdown += split.markdown ?? UIChangeCounts()
            table.adopted += session.adopted
            table.held += split.held
        }
        return table
    }
}

/// Apple / markdown counts of one session. Exact for exports and for syncs
/// recorded with `SessionRecord.sides` (M5 on: every sync, from the app,
/// live triggers, the CLI and schedules). Older app syncs kept the split in
/// the device state's metadata (`UISessionDetail`); older CLI syncs only
/// stored both sides combined, so only the totals are known.
struct UISessionSplit {
    var contacts: UIChangeCounts?
    var markdown: UIChangeCounts?
    /// Created / updated over both sides, when the split is unknown.
    var combined: UIChangeCounts?
    var held: Int
    var holdReason: String?
    /// `full` / `incremental` (how Apple Contacts was read), when recorded.
    var appleRead: String?

    init(_ session: SessionRecord, details: [UISessionDetail]) {
        held = 0
        if session.command == "plan" { return }
        if let sides = session.sides {
            contacts = UIChangeCounts(
                created: sides.appleCreated, updated: sides.appleUpdated, deleted: sides.appleDeleted)
            // Adoptions are counted separately (This Session ▸ Existing notes linked).
            markdown = UIChangeCounts(
                created: sides.markdownCreated, updated: max(0, sides.markdownUpdated - session.adopted),
                deleted: sides.markdownDeleted)
            held = sides.held
            holdReason = sides.heldReason.map(Self.holdReason)
            appleRead = sides.appleRead
        } else if let detail = details.first(where: { $0.matches(session) }) {
            contacts = detail.apple
            markdown = detail.markdown
            held = detail.held
            holdReason = detail.holdReason
        } else if session.command == "sync" {
            combined = UIChangeCounts(created: session.created, updated: session.updated + session.stamped)
        } else {
            contacts = UIChangeCounts(updated: session.stamped)
            markdown = UIChangeCounts(created: session.created, updated: session.updated)
        }
    }

    /// The engine's hold reason (`AppleHold.reason`) in Activity wording,
    /// without the command-line hint.
    static func holdReason(_ reason: String) -> String {
        if reason == AppleHold.appleWritesDisabled.reason { return "Apple writes off" }
        guard let hint = reason.range(of: " (use --") else { return reason }
        return String(reason[..<hint.lowerBound])
    }
}

// MARK: - Activity (docs/ui.md §8)

/// One run in the Activity list.
public struct UIActivityRow: Identifiable, Hashable, Sendable {
    public enum Result: Hashable, Sendable {
        case success
        case warnings(Int)
        case failed(Int)
    }

    public var id: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var deviceName: String
    /// `GUI` is shown as Manual (docs/ui.md wording).
    public var trigger: String
    /// `export`, `sync` or `plan`.
    public var command: String
    /// A dry run (preview), not an export or sync.
    public var isPreview: Bool
    /// `nil` for previews (nothing was written) and for syncs whose split is unknown.
    public var contacts: UIChangeCounts?
    public var markdown: UIChangeCounts?
    /// Both sides together, for syncs recorded without the split (CLI, launchd).
    public var combined: UIChangeCounts?
    public var adopted: Int
    /// Apple changes held (writes off or over the limit), with the reason.
    public var held: Int
    public var holdReason: String?
    /// `full` / `incremental` (how Apple Contacts was read; M5 syncs).
    public var appleRead: String?
    public var review: Int
    public var skipped: Int
    public var result: Result
    /// Contact notes this run: `2 → Contacts · 1 → notes`, `skipped`, or
    /// `nil` (notes off, previews, runs before notes existed).
    public var notes: String?
    /// Changes in the run's change log (`nil`: none recorded).
    public var changeCount: Int?
    /// The key of the run's change log (`SessionRecord.changeLogID`).
    public var changeLogID: String?

    /// `2 → Contacts · 1 → notes` / `skipped` for a session's notes counts.
    static func notesText(_ session: SessionRecord) -> String? {
        guard session.command != "plan", let sides = session.sides, let source = sides.notes else { return nil }
        if source == "skipped" { return "skipped" }
        let toContacts = sides.notesToContacts ?? 0
        let toMarkdown = sides.notesToMarkdown ?? 0
        return toContacts + toMarkdown == 0 ? "0" : "\(toContacts) → Contacts · \(toMarkdown) → notes"
    }

    /// Rows for `sessions` (newest first); sessions from other devices show their id.
    public static func rows(
        _ sessions: [SessionRecord], device: DeviceIdentity, details: [UISessionDetail] = []
    ) -> [UIActivityRow] {
        sessions.enumerated().map { offset, session in
            let preview = session.command == "plan"
            let split = UISessionSplit(session, details: details)
            let result: Result =
                session.failures > 0
                ? .failed(session.failures) : session.skipped > 0 ? .warnings(session.skipped) : .success
            return UIActivityRow(
                id: "\(session.startedAt.timeIntervalSince1970)-\(session.command)-\(offset)",
                startedAt: session.startedAt, duration: session.finishedAt.timeIntervalSince(session.startedAt),
                deviceName: session.deviceID == device.id || session.deviceID.isEmpty
                    ? device.name : String(session.deviceID.prefix(8)),
                trigger: Self.trigger(session.trigger), command: session.command, isPreview: preview,
                contacts: split.contacts, markdown: split.markdown, combined: split.combined,
                adopted: session.adopted, held: split.held, holdReason: split.holdReason,
                appleRead: split.appleRead, review: session.pendingReview, skipped: session.skipped, result: result,
                notes: notesText(session), changeCount: session.changeCount, changeLogID: session.changeLogID)
        }
    }

    /// docs/ui.md §8 wording: `GUI` → Manual; the coordinator's kinds
    /// (`Live`, `Launch`, `Wake`, `Sweep`, `Manual`, `Rescan`) and `CLI` as
    /// recorded; the raw kind names (`rescan-vault`, …) as their labels.
    static func trigger(_ recorded: String) -> String {
        if recorded == "GUI" { return "Manual" }
        return SyncRunKind(rawValue: recorded)?.displayName ?? recorded
    }
}

// MARK: - All Contacts (docs/ui.md §1 Library)

/// One synced record: Apple cards ↔ note path.
public struct UILibraryRow: Identifiable, Hashable, Sendable {
    /// `c2mdsync.id`.
    public var id: UUID
    public var title: String
    public var path: String
    public var accounts: [AccountKind]
    public var cardIDs: [String]

    /// Folder part of the path (`""` at the root).
    public var folder: String { VaultPath.directory(of: path) }

    /// `iCloud + Google`.
    public var accountsText: String {
        var names: [String] = []
        for name in accounts.map(\.displayName) where !names.contains(name) { names.append(name) }
        return names.joined(separator: " + ")
    }

    /// Case- and diacritic-insensitive match on title, path and accounts.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, path, accountsText].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Rows for every bound record, sorted by title. The title comes from the
    /// note (by sync id, else path), falling back to the file name.
    public static func rows(_ data: UIVaultData) -> [UILibraryRow] {
        let byID = Dictionary(
            data.notes.compactMap { note in note.syncID.map { ($0, note) } }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(data.notes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return data.records.records.map { id, binding in
            let note = byID[id] ?? byPath[binding.path]
            return UILibraryRow(
                id: id, title: note?.title ?? VaultPath.stem(of: binding.path), path: note?.path ?? binding.path,
                accounts: binding.cards.map(\.accountKind), cardIDs: binding.cardIDs)
        }
        .sorted { ($0.title.localizedLowercase, $0.path) < ($1.title.localizedLowercase, $1.path) }
    }
}

// MARK: - Formatting

/// Shared formatting for the review screens (docs/ui.md §13).
public enum UIFormat {
    /// `Today 10:42 AM`, `Yesterday 6:12 PM`, else `Oct 19, 4:10 PM`.
    public static func relativeDay(
        _ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var calendar = calendar
        calendar.locale = locale
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar).month(
            .abbreviated
        )
        .day()
        if !sameYear { style = style.year() }
        return date.formatted(style)
    }

    /// `addressbook://` URLs that open each card in Contacts.app.
    public static func contactsURLs(cardIDs: [String]) -> [URL] {
        var seen = Set<String>()
        return cardIDs.filter { seen.insert($0).inserted }.compactMap { URL(string: "addressbook://\($0)") }
    }

    /// An error for display: engine errors describe themselves; Cocoa,
    /// POSIX and URL errors use their localized text (not the `NSError` dump).
    public static func message(for error: any Error) -> String {
        let domain = (error as NSError).domain
        if domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain || domain == NSURLErrorDomain {
            return error.localizedDescription
        }
        return String(describing: error)
    }

    /// Short duration: `0.4 s`, `4 s`, `2 min`.
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.1f s", max(0, seconds)) }
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        return "\(Int((seconds / 60).rounded())) min"
    }
}
