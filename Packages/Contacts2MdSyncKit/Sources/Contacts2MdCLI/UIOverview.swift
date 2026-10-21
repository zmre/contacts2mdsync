public import ContactModel
public import Foundation
public import SyncEngine
internal import VaultIndex

/// Created / updated / deleted counts for one side.
public struct UIChangeCounts: Hashable, Sendable {
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
        /// The next export would write notes.
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
        /// `This Session` or `Last Export`.
        public var heading: String
        public var contacts: UIChangeCounts
        public var markdown: UIChangeCounts
        public var adopted: Int
    }

    public var health: Health
    public var lastExport: Date?
    public var lastDuration: TimeInterval?
    public var deviceName: String
    /// Only non-zero queues, in sidebar order.
    public var needsReview: [ReviewRow]
    /// From the latest dry run (`nil` until one finished).
    public var changedInContacts: Int?
    public var toAdopt: Int
    public var movedNotes: Int
    public var planComputedAt: Date?
    public var session: SessionTable?
    public var syncedContacts: Int
    public var rootPath: String
    /// Several devices share this folder but contacts carry no sync ids.
    public var multiDeviceWithoutStamps: Bool

    /// Builds the overview. `sessionStart` is when the app launched;
    /// `stampContacts` is the vault's opt-in (off when unknown).
    public init(
        data: UIVaultData, plan: UIPlanSummary?, counts: UIReviewCounts, sessionStart: Date,
        stampContacts: Bool = false
    ) {
        let exports = data.sessions.filter { $0.command != "plan" }
        lastExport = data.records.lastExport
        lastDuration = exports.first.map { $0.finishedAt.timeIntervalSince($0.startedAt) }
        deviceName = data.device.name
        needsReview = UIReviewQueue.allCases.compactMap { queue in
            counts[queue] > 0 ? ReviewRow(queue: queue, title: Self.title(queue), count: counts[queue]) : nil
        }
        changedInContacts = plan.map { $0.toCreate + $0.toUpdate }
        toAdopt = plan?.toAdopt ?? 0
        movedNotes = plan?.moves ?? 0
        planComputedAt = plan?.computedAt
        syncedContacts = data.records.records.count
        rootPath = data.rootPath
        multiDeviceWithoutStamps = data.deviceCount > 1 && !stampContacts
        if data.records.lastExport == nil {
            health = .neverExported
        } else if counts.total > 0 {
            health = .needsReview(counts.total)
        } else if let plan, plan.pendingWrites > 0 {
            health = .changesWaiting(plan.pendingWrites)
        } else {
            health = .inSync
        }
        let thisSession = exports.filter { $0.startedAt >= sessionStart }
        if !thisSession.isEmpty {
            session = Self.table("This Session", thisSession)
        } else if let last = exports.first {
            session = Self.table("Last Export", [last])
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

    private static func table(_ heading: String, _ sessions: [SessionRecord]) -> SessionTable {
        SessionTable(
            heading: heading,
            contacts: sessions.reduce(UIChangeCounts()) { $0 + UIChangeCounts(updated: $1.stamped) },
            markdown: sessions.reduce(UIChangeCounts()) {
                $0 + UIChangeCounts(created: $1.created, updated: $1.updated)
            },
            adopted: sessions.reduce(0) { $0 + $1.adopted })
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
    public var command: String
    /// A dry run (preview), not an export.
    public var isPreview: Bool
    /// `nil` for previews (nothing was written).
    public var contacts: UIChangeCounts?
    public var markdown: UIChangeCounts?
    public var adopted: Int
    public var review: Int
    public var skipped: Int
    public var result: Result

    /// Rows for `sessions` (newest first); sessions from other devices show their id.
    public static func rows(_ sessions: [SessionRecord], device: DeviceIdentity) -> [UIActivityRow] {
        sessions.enumerated().map { offset, session in
            let preview = session.command == "plan"
            let result: Result =
                session.failures > 0
                ? .failed(session.failures) : session.skipped > 0 ? .warnings(session.skipped) : .success
            return UIActivityRow(
                id: "\(session.startedAt.timeIntervalSince1970)-\(session.command)-\(offset)",
                startedAt: session.startedAt, duration: session.finishedAt.timeIntervalSince(session.startedAt),
                deviceName: session.deviceID == device.id || session.deviceID.isEmpty
                    ? device.name : String(session.deviceID.prefix(8)),
                trigger: session.trigger == "GUI" ? "Manual" : session.trigger, command: session.command,
                isPreview: preview, contacts: preview ? nil : UIChangeCounts(updated: session.stamped),
                markdown: preview ? nil : UIChangeCounts(created: session.created, updated: session.updated),
                adopted: session.adopted, review: session.pendingReview, skipped: session.skipped, result: result)
        }
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

    /// Short duration: `0.4 s`, `4 s`, `2 min`.
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.1f s", max(0, seconds)) }
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        return "\(Int((seconds / 60).rounded())) min"
    }
}
