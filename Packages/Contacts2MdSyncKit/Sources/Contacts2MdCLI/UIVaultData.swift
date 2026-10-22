public import ContactModel
public import Foundation
public import SyncEngine
public import SyncTriggers
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
    /// Household and office numbers among `phones`: shared by spouses and
    /// colleagues, so they never make two contacts duplicates (shown
    /// de-emphasized).
    public var householdPhones: [UIHouseholdPhone]

    /// Creates a summary.
    public init(
        title: String, accounts: [AccountKind], cardIDs: [String], organization: String? = nil,
        jobTitle: String? = nil, emails: [String] = [], phones: [String] = [],
        householdPhones: [UIHouseholdPhone] = []
    ) {
        self.title = title
        self.accounts = accounts
        self.cardIDs = cardIDs
        self.organization = organization
        self.jobTitle = jobTitle
        self.emails = emails
        self.phones = phones
        self.householdPhones = householdPhones
    }

    init(_ contact: AppleContact) {
        let values = contact.contact
        let household = values.phones.filter { PhoneLabels.isHousehold($0.label) }
        self.init(
            title: TitleGenerator.title(for: values), accounts: contact.cards.map(\.accountKind),
            cardIDs: contact.cardIDs, organization: values.company?.name, jobTitle: values.jobTitle,
            emails: values.emails.map(\.value), phones: values.phones.map(\.value),
            householdPhones: household.map { UIHouseholdPhone(value: $0.value, label: $0.label ?? "") })
    }

    /// Mobile, iPhone and unlabeled numbers (the ones that can identify a person).
    public var personalPhones: [String] {
        let household = Set(householdPhones.map(\.value))
        return phones.filter { !household.contains($0) }
    }
}

/// A home / main / work number: shared within a household or office.
public struct UIHouseholdPhone: Hashable, Sendable {
    public var value: String
    /// Markdown label (`home`, `work_fax`, …).
    public var label: String

    /// Creates a phone.
    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    /// `+1 303 555 0100 (home)`.
    public var line: String { "\(value) (\(label.replacingOccurrences(of: "_", with: " ")))" }
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
    /// Apple / markdown split of syncs started from the app (see `UISessionDetail`).
    public var sessionDetails: [UISessionDetail] = []

    /// `apple_writes` / `stamp_contacts`.
    public var options: UIVaultOptions { UIVaultOptions(config) }

    /// Synced or exported on this Mac before (Sync Now runs two-way; before
    /// that it runs the first export).
    public var hasSynced: Bool { records.lastExport != nil }

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
    /// Whether the Contacts notes field was readable.
    public var notesAvailable: Bool
    public var reviews: [ReviewItem]
    /// Contacts named by review items, by underlying card id.
    public var contacts: [String: UIContactSummary]
    /// The two-way part (`nil` when this was the one-way export plan).
    public var sync: UISyncPlanSummary?
    /// The two-way plan counted like a follower's check: while another
    /// device leads, what it still has to apply (`nil` for the export plan).
    public var planned: SyncRunSummary?

    /// Creates a summary of a one-way export plan.
    public init(_ prepared: PreparedExport, computedAt: Date) {
        self.init(
            prepared.plan, computedAt: computedAt, cards: prepared.snapshot.contacts.flatMap(\.cards),
            contacts: prepared.snapshot.contacts, notesAvailable: prepared.snapshot.notesAvailable)
    }

    /// Creates a summary of a two-way plan. Account counts and contact
    /// details for review items come from the snapshot the plan was made
    /// from (`PreparedSync.snapshot`), so Contacts is read only once.
    public init(_ prepared: PreparedSync, computedAt: Date) {
        let snapshot = prepared.snapshot
        self.init(
            prepared.plan.markdown, computedAt: computedAt, cards: snapshot.contacts.flatMap(\.cards),
            contacts: snapshot.contacts, notesAvailable: snapshot.notesAvailable)
        sync = UISyncPlanSummary(prepared.plan)
        planned = VaultSyncRunner.plannedSummary(
            .manual, prepared: prepared, startedAt: computedAt, finishedAt: computedAt)
    }

    private init(
        _ plan: ExportPlan, computedAt: Date, cards: [AppleCard], contacts: [AppleContact], notesAvailable: Bool
    ) {
        self.init(
            plan, computedAt: computedAt, accountKinds: cards.map(\.accountKind), contacts: contacts,
            notesAvailable: notesAvailable)
    }

    private init(
        _ plan: ExportPlan, computedAt: Date, accountKinds: [AccountKind], contacts all: [AppleContact],
        notesAvailable: Bool
    ) {
        self.computedAt = computedAt
        contactsRead = plan.appleContactCount
        accounts = Dictionary(grouping: accountKinds, by: { $0 }).map {
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
        self.notesAvailable = notesAvailable
        reviews = plan.reviews
        contacts = Self.contactDetails(all, wanted: Set(plan.reviews.flatMap(\.referencedCardIDs)))
    }

    /// Summaries of the contacts that have any of `wanted`, by card id.
    static func contactDetails(_ contacts: [AppleContact], wanted: Set<String>) -> [String: UIContactSummary] {
        var details: [String: UIContactSummary] = [:]
        for contact in contacts where contact.cardIDs.contains(where: wanted.contains) {
            let summary = UIContactSummary(contact)
            for id in contact.cardIDs { details[id] = summary }
        }
        return details
    }

    /// The contact that still has any of `cardIDs`.
    public func contact(for cardIDs: [String]) -> UIContactSummary? {
        cardIDs.lazy.compactMap { contacts[$0] }.first
    }

    /// Notes the next export would write (creates, updates, adoptions, fix-ups).
    public var pendingWrites: Int { toCreate + toUpdate + toAdopt + fixups }

    /// Changes on either side the next Sync Now would make (held Apple changes excluded).
    public var pendingChanges: Int { pendingWrites + (sync.map { $0.appleWrites + $0.trash } ?? 0) }
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
    /// Create an Apple contact from the markdown-only note at `path`
    /// (`create-contact`; applied by the next sync with Apple writes on).
    case addContact(path: String)
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
