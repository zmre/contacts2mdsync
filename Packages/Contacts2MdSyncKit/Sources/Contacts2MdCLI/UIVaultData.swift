public import ContactModel
public import Foundation
public import SyncEngine
internal import VaultIndex

// View-model adapters for the app's review UI (docs/ui.md). Everything here
// reads through the same public APIs the CLI uses; nothing writes except
// `UIVaultReader.record` (decision log) and `setDefaultFolder` (config).

/// A contact note as the review screens show it.
public struct UINoteSummary: Hashable, Sendable, Identifiable {
    /// Root-relative path.
    public var path: String
    public var title: String
    public var kind: ContactKind?
    /// `c2mdsync.id`, when the note has one.
    public var syncID: UUID?
    public var organization: String?
    public var jobTitle: String?
    public var emails: [String]
    public var phones: [String]
    public var tags: [String]
    /// An iCloud placeholder whose bytes are not on this Mac.
    public var isDataless: Bool

    /// Creates a summary.
    public init(
        path: String, title: String, kind: ContactKind? = .person, syncID: UUID? = nil, organization: String? = nil,
        jobTitle: String? = nil, emails: [String] = [], phones: [String] = [], tags: [String] = [],
        isDataless: Bool = false
    ) {
        self.path = path
        self.title = title
        self.kind = kind
        self.syncID = syncID
        self.organization = organization
        self.jobTitle = jobTitle
        self.emails = emails
        self.phones = phones
        self.tags = tags
        self.isDataless = isDataless
    }

    init(_ entry: VaultEntry) {
        let contact = entry.contact
        self.init(
            path: entry.path, title: entry.title, kind: contact?.kind, syncID: entry.syncID,
            organization: contact?.company?.name, jobTitle: contact?.jobTitle,
            emails: contact?.emails.map(\.value) ?? [], phones: contact?.phones.map(\.value) ?? [],
            tags: contact?.tags ?? [], isDataless: entry.isDataless)
    }

    public var id: String { path }

    /// Folder part of the path (`""` at the root).
    public var folder: String { VaultPath.directory(of: path) }
}

/// An Apple contact as the review screens show it.
public struct UIContactSummary: Hashable, Sendable {
    public var title: String
    public var accounts: [AccountKind]
    /// Underlying card ids (for `addressbook://` links).
    public var cardIDs: [String]
    public var organization: String?
    public var jobTitle: String?
    public var emails: [String]
    public var phones: [String]

    /// Creates a summary.
    public init(
        title: String, accounts: [AccountKind], cardIDs: [String], organization: String? = nil,
        jobTitle: String? = nil, emails: [String] = [], phones: [String] = []
    ) {
        self.title = title
        self.accounts = accounts
        self.cardIDs = cardIDs
        self.organization = organization
        self.jobTitle = jobTitle
        self.emails = emails
        self.phones = phones
    }

    init(_ contact: AppleContact) {
        let values = contact.contact
        self.init(
            title: TitleGenerator.title(for: values), accounts: contact.cards.map(\.accountKind),
            cardIDs: contact.cardIDs, organization: values.company?.name, jobTitle: values.jobTitle,
            emails: values.emails.map(\.value), phones: values.phones.map(\.value))
    }
}

/// A contact note that could not be parsed (never written to).
public struct UIProblemNote: Hashable, Sendable, Identifiable {
    public var path: String
    public var problem: String

    public var id: String { path }
}

/// Cards in one account kind.
public struct UIAccountCount: Hashable, Sendable {
    public var account: AccountKind
    public var count: Int
}

/// Everything the app shows that comes from the notes folder and this
/// device's state — no Contacts access needed.
public struct UIVaultData: Sendable {
    public var rootPath: String
    public var config: VaultConfig
    public var status: StoredStatus
    public var pending: PendingReviews
    /// Union of every device's decision log, oldest first.
    public var decisions: [Decision]
    /// Decision-log lines that could not be read.
    public var decisionProblems: [String]
    public var records: RecordMap
    /// Newest first.
    public var sessions: [SessionRecord]
    /// Contact notes, sorted by path.
    public var notes: [UINoteSummary]
    public var invalidContactNotes: [UIProblemNote]
    /// iCloud placeholders never read on this Mac.
    public var undownloaded: Int
    public var device: DeviceIdentity
    /// Ids of devices that wrote to `.c2mdsync/devices/` (this one included when it has).
    public var vaultDevices: [String]
    /// This vault's per-device state folder.
    public var stateDirectory: URL
    public var readAt: Date

    /// Where vCard and note backups are kept.
    public var backupsDirectory: URL { stateDirectory.appending(path: "backups") }

    /// Pending item ids some decision already answers (effective on the next run).
    public var decidedItemIDs: Set<String> { Set(decisions.compactMap(\.itemID)) }

    /// Pending items no decision answers yet.
    public var openItems: [PendingReview] {
        let decided = decidedItemIDs
        return pending.items.filter { !decided.contains($0.id) }
    }

    /// Notes ignored as markdown-only candidates.
    public func isIgnored(_ note: UINoteSummary) -> Bool {
        DecisionSet(decisions).isIgnored(path: note.path, syncID: note.syncID)
    }

    /// Number of devices known to share this folder (at least this one).
    public var deviceCount: Int { Set(vaultDevices + [device.id]).count }

    /// Contact note at `path`.
    public func note(at path: String) -> UINoteSummary? {
        notes.first { $0.path == path }
    }
}

/// Summary of a dry-run plan (needs Contacts access; computed off the main actor).
public struct UIPlanSummary: Sendable {
    public var computedAt: Date
    public var contactsRead: Int
    /// Cards per account, largest first.
    public var accounts: [UIAccountCount]
    public var groups: Int
    public var toCreate: Int
    public var toUpdate: Int
    public var toAdopt: Int
    public var fixups: Int
    public var moves: Int
    public var unchanged: Int
    public var markdownOnly: Int
    public var ignoredCandidates: Int
    public var excludedByDecision: Int
    public var skipped: Int
    public var warnings: [String]
    public var notesAvailable: Bool
    public var reviews: [ReviewItem]
    /// Contacts named by review items, by underlying card id.
    public var contacts: [String: UIContactSummary]

    /// Creates a summary of `prepared`.
    public init(_ prepared: PreparedExport, computedAt: Date) {
        let plan = prepared.plan
        self.computedAt = computedAt
        contactsRead = plan.appleContactCount
        let kinds = prepared.snapshot.contacts.flatMap(\.cards).map(\.accountKind)
        accounts = Dictionary(grouping: kinds, by: { $0 }).map {
            UIAccountCount(account: $0.key, count: $0.value.count)
        }
        .sorted { ($1.count, $0.account.displayName) < ($0.count, $1.account.displayName) }
        groups = plan.config.groups.count
        toCreate = plan.creates.count
        toUpdate = plan.updates.filter { $0.kind == .update }.count
        toAdopt = plan.adoptions.count
        fixups = plan.updates.filter { $0.kind == .pathFixup }.count
        moves = plan.moves.count
        unchanged = plan.unchanged
        markdownOnly = plan.markdownOnly
        ignoredCandidates = plan.ignoredCandidates
        excludedByDecision = plan.excludedByDecision
        skipped = plan.skipped.count
        warnings = plan.warnings
        notesAvailable = prepared.snapshot.notesAvailable
        reviews = plan.reviews
        let wanted = Set(plan.reviews.flatMap(\.referencedCardIDs))
        var contacts: [String: UIContactSummary] = [:]
        for contact in prepared.snapshot.contacts where contact.cardIDs.contains(where: wanted.contains) {
            let summary = UIContactSummary(contact)
            for id in contact.cardIDs { contacts[id] = summary }
        }
        self.contacts = contacts
    }

    /// The contact that still has any of `cardIDs`.
    public func contact(for cardIDs: [String]) -> UIContactSummary? {
        cardIDs.lazy.compactMap { contacts[$0] }.first
    }

    /// Notes the next export would write (creates, updates, adoptions, fix-ups).
    public var pendingWrites: Int { toCreate + toUpdate + toAdopt + fixups }
}

extension ReviewItem {
    /// Card ids this item refers to.
    var referencedCardIDs: [String] {
        if case .duplicateCluster(let members, _) = self { return members.flatMap(\.cardIDs) }
        if case .possibleMatch(let contact, _, _, _) = self { return contact.cardIDs }
        if case .mergeRecords(let contact, _, _) = self { return contact.cardIDs }
        return []
    }
}

/// What an export started from the app did.
public struct UIExportSummary: Hashable, Sendable {
    public var created: Int
    public var adopted: Int
    public var updated: Int
    public var contactsBackup: String?
    public var notesBackup: String?
    public var failures: [String]
    public var pendingReview: Int
}

/// A review answer from the app, turned into decision-log entries by `UIVaultReader.record`.
public enum UIReviewDecision: Hashable, Sendable {
    /// One of the item's `choices` (same strings as `contacts2md review decide`).
    case choice(itemID: String, choice: String)
    /// Never match the markdown-only note at `path` (no review item needed).
    case ignoreNote(path: String)
}

/// Errors from the app adapters.
public enum UIReviewError: Error, Hashable, Sendable, CustomStringConvertible {
    case notConfigured
    case itemNotFound(String)

    public var description: String {
        switch self {
        case .notConfigured: "This folder has not been exported to yet."
        case .itemNotFound(let id): "The review item \(id) is no longer pending. Refresh and try again."
        }
    }
}

/// The app's entry point into a vault: reads stored state, plans, exports,
/// and records review decisions — the same code paths as the CLI.
public struct UIVaultReader: Sendable {
    public let root: URL
    public let environment: CLIEnvironment

    /// Creates a reader for `root` (already opened through the bookmark).
    public init(root: URL, environment: CLIEnvironment) {
        self.root = root
        self.environment = environment
    }

    /// Stored state, the decision log and a scan of the folder; `nil` when the
    /// folder was never exported to. Creates nothing on disk.
    public func read() throws -> UIVaultData? {
        let fs = environment.makeVault(root)
        guard let config = try VaultConfig.load(from: fs)?.config else { return nil }
        let directory = stateDirectory(config)
        let device = try environment.device()
        let (decisions, decisionProblems) = try DecisionLog.readAll(fs)
        var records = RecordMap()
        var pending = PendingReviews()
        var sessions: [SessionRecord] = []
        var cache: [String: FileCacheEntry] = [:]
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            let state = try environment.makeStateStore(directory)
            records = try state.load()
            pending = try state.loadPending()
            sessions = try state.recentSessions(limit: 200)
            cache = try state.loadFileCache()
        }
        let index = try VaultIndex.scan(
            fs, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths, cache: cache)
        let devices = ((try? fs.list(DecisionLog.devicesFolder)) ?? []).filter { !$0.hasPrefix(".") }
        return UIVaultData(
            rootPath: root.path(percentEncoded: false), config: config,
            status: StoredStatus(
                lastExport: records.lastExport, records: records.records.count, pendingReview: pending.items.count,
                pendingAsOf: pending.computedAt),
            pending: pending, decisions: decisions, decisionProblems: decisionProblems, records: records,
            sessions: sessions,
            notes: index.entries.filter(\.isContactNote).map(UINoteSummary.init).sorted { $0.path < $1.path },
            invalidContactNotes: index.problems.filter(\.problemIsContactRelated).map {
                UIProblemNote(path: $0.path, problem: $0.problem ?? "unreadable")
            },
            undownloaded: index.undownloaded.count, device: device, vaultDevices: devices.sorted(),
            stateDirectory: directory, readAt: environment.clock.now)
    }

    /// A dry run (reads Contacts): refreshes the pending review queue and
    /// records a `plan` session, exactly like `contacts2md plan`.
    public func plan() throws -> UIPlanSummary {
        let startedAt = environment.clock.now
        let session = VaultSession(root: root, environment: environment)
        let prepared = try session.prepare(ExportRequest(), forWriting: false)
        try session.recordPlan(prepared, command: "plan", startedAt: startedAt)
        return UIPlanSummary(prepared, computedAt: environment.clock.now)
    }

    /// Exports (vCard backup first, never stamps), like the app's first export.
    public func export() throws -> UIExportSummary {
        let startedAt = environment.clock.now
        let session = VaultSession(root: root, environment: environment)
        let prepared = try session.prepare(ExportRequest(), forWriting: true)
        let outcome = try session.execute(
            prepared, backupContacts: true, stamp: false, command: "export", startedAt: startedAt)
        let adopted = outcome.result.updated.filter { $0.kind == .adopt }.count
        return UIExportSummary(
            created: outcome.result.created.count, adopted: adopted, updated: outcome.result.updated.count - adopted,
            contactsBackup: outcome.backup?.url.path(percentEncoded: false),
            notesBackup: outcome.result.noteBackup?.path(percentEncoded: false),
            failures: outcome.result.failures.map { "\($0.path): \($0.message)" },
            pendingReview: prepared.plan.reviews.count)
    }

    /// Appends the decisions to this device's log. They take effect on the
    /// next plan or export. Returns the number of log entries written.
    @discardableResult
    public func record(_ answers: [UIReviewDecision]) throws -> Int {
        guard !answers.isEmpty else { return 0 }
        let fs = environment.makeVault(root)
        guard let config = try VaultConfig.load(from: fs)?.config else { throw UIReviewError.notConfigured }
        let directory = stateDirectory(config)
        let hasState = FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
        let state = hasState ? try environment.makeStateStore(directory) : nil
        let pending = try state?.loadPending().items ?? []
        let device = try environment.device()
        let now = environment.clock.now
        var decisions: [Decision] = []
        for answer in answers {
            switch answer {
            case .choice(let itemID, let choice):
                guard let entry = pending.first(where: { $0.id == itemID }) else {
                    throw UIReviewError.itemNotFound(itemID)
                }
                decisions += try entry.item.decisions(for: choice, device: device, at: now)
            case .ignoreNote(let path):
                decisions.append(Decision(kind: .ignoreCandidate, createdAt: now, device: device, path: path))
            }
        }
        try DecisionLog.append(decisions, deviceID: device.id, fs: fs)
        try state?.saveDecisionMirror(try DecisionLog.readAll(fs).decisions)
        return decisions.count
    }

    /// Changes the folder for new notes in `.c2mdsync/config.yaml`
    /// (compare-and-swap: a concurrent edit is never overwritten).
    public func setDefaultFolder(_ folder: String) throws {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        try VaultPath.validate(folder)
        let fs = environment.makeVault(root)
        guard fs.exists(VaultConfig.path) else { throw UIReviewError.notConfigured }
        let (_, stamp) = try fs.read(VaultConfig.path)
        guard let loaded = try VaultConfig.load(from: fs) else { throw UIReviewError.notConfigured }
        var config = loaded.config
        guard config.defaultFolder != folder else { return }
        config.defaultFolder = folder
        _ = try fs.write(
            Data(config.render(patching: loaded.text).utf8), to: VaultConfig.path, expecting: .unchanged(stamp))
        let bookmark = RootBookmark(directory: environment.stateDirectory)
        var settings = bookmark.loadSettings()
        settings.defaultFolder = folder
        try? bookmark.saveSettings(settings)
    }

    private func stateDirectory(_ config: VaultConfig) -> URL {
        environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
    }
}
