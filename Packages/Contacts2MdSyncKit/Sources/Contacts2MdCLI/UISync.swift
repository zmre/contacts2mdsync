public import Foundation
public import SyncEngine

// Two-way sync for the app (architecture §9, §11; docs/ui.md §3, §12): what
// Sync Now asks for, what came back, what the next sync would do, and the
// banners that follow from it.

/// Overrides for one Sync Now (each needs an explicit confirmation in the UI).
public struct UISyncRequest: Hashable, Sendable {
    /// Approve up to this many Apple changes (blast radius "Apply Anyway").
    public var maxAppleChanges: Int?
    /// Proceed although the mass-vanish breaker trips (deletions are still only queued).
    public var allowMassVanish: Bool
    /// Take the vault lease from another device.
    public var takeOver: Bool

    /// Creates a request.
    public init(maxAppleChanges: Int? = nil, allowMassVanish: Bool = false, takeOver: Bool = false) {
        self.maxAppleChanges = maxAppleChanges
        self.allowMassVanish = allowMassVanish
        self.takeOver = takeOver
    }
}

/// The vault's write switches (`.c2mdsync/config.yaml`).
public struct UIVaultOptions: Hashable, Sendable {
    /// `apple_writes`: write markdown edits back to Apple Contacts.
    public var appleWrites: Bool
    /// `stamp_contacts`: add `x-c2mdsync:` sync ids to Apple cards.
    public var stampContacts: Bool

    /// Creates options.
    public init(appleWrites: Bool, stampContacts: Bool) {
        self.appleWrites = appleWrites
        self.stampContacts = stampContacts
    }

    /// The options in `config`.
    public init(_ config: VaultConfig) {
        self.init(appleWrites: config.appleWrites, stampContacts: config.stampContacts)
    }
}

/// What a finished Sync Now (or the first export on this Mac) did.
public struct UISyncSummary: Hashable, Sendable {
    /// Apple changes made: created / updated (incl. stamps) / deleted.
    public var apple: UIChangeCounts
    /// Notes written: created / updated / moved to the Trash.
    public var markdown: UIChangeCounts
    public var adopted: Int
    /// Apple changes not made, and why.
    public var held: Int
    public var hold: AppleHold?
    public var failures: [String]
    public var contactsBackup: String?
    public var notesBackup: String?
    public var pendingReview: Int
    /// This was a one-way export (the vault had not been synced on this Mac).
    public var wasExport: Bool

    /// Creates a summary.
    public init(
        apple: UIChangeCounts = UIChangeCounts(), markdown: UIChangeCounts = UIChangeCounts(), adopted: Int = 0,
        held: Int = 0, hold: AppleHold? = nil, failures: [String] = [], contactsBackup: String? = nil,
        notesBackup: String? = nil, pendingReview: Int = 0, wasExport: Bool = false
    ) {
        self.apple = apple
        self.markdown = markdown
        self.adopted = adopted
        self.held = held
        self.hold = hold
        self.failures = failures
        self.contactsBackup = contactsBackup
        self.notesBackup = notesBackup
        self.pendingReview = pendingReview
        self.wasExport = wasExport
    }

    /// Summary of an executed sync.
    public init(_ result: SyncResult, plan: SyncPlan) {
        let adopted = result.markdown.updated.filter { $0.kind == .adopt }.count
        self.init(
            apple: UIChangeCounts(apple: result.apple),
            markdown: UIChangeCounts(
                created: result.markdown.created.count, updated: result.markdown.updated.count - adopted,
                deleted: result.trashed.count),
            adopted: adopted, held: plan.appleWritesAllowed ? 0 : plan.apple.count, hold: plan.appleHold,
            failures: result.markdown.failures.map { "\($0.path): \($0.message)" } + result.appleFailures
                + result.skippedLinks.map { "\($0): contact not created; note left unlinked" },
            contactsBackup: result.backup?.url.path(percentEncoded: false),
            notesBackup: result.markdown.noteBackup?.path(percentEncoded: false),
            pendingReview: plan.markdown.reviews.filter(\.needsDecision).count)
    }

    /// Summary of a one-way export (first run on this Mac).
    public init(export: UIExportSummary) {
        self.init(
            markdown: UIChangeCounts(created: export.created, updated: export.updated), adopted: export.adopted,
            failures: export.failures, contactsBackup: export.contactsBackup, notesBackup: export.notesBackup,
            pendingReview: export.pendingReview, wasExport: true)
    }
}

extension UIChangeCounts {
    /// Apple changes by kind: create / update, stamp, unstamp / delete.
    public init(apple changes: [AppleRecordChange]) {
        self.init(
            created: changes.filter { $0.kind == .create }.count,
            updated: changes.filter { [.update, .stamp, .unstamp].contains($0.kind) }.count,
            deleted: changes.filter { $0.kind == .delete }.count)
    }
}

/// Why Sync Now did not run, or what it did.
public enum UISyncOutcome: Hashable, Sendable {
    case synced(UISyncSummary)
    /// Another run on this Mac (the CLI, launchd) holds the local lock.
    case localRunInProgress
    /// Another device leads syncing this vault.
    case leaseHeldElsewhere(VaultLease)
    /// The mass-vanish breaker stopped the run; nothing was written.
    case breaker(BreakerTrip)

    /// The summary of a finished run.
    public var summary: UISyncSummary? {
        if case .synced(let summary) = self { return summary }
        return nil
    }
}

/// The two-way part of a dry run (`nil` on `UIPlanSummary` before the first
/// sync on this Mac, when the dry run is the one-way export plan).
public struct UISyncPlanSummary: Hashable, Sendable {
    /// Apple changes the plan holds: created / updated (incl. stamps) / deleted.
    public var apple: UIChangeCounts
    /// Records with Apple changes (the blast-radius count).
    public var appleChanges: Int
    /// Apple changes that come from markdown edits (not stamps): "Changed in Markdown".
    public var changedInMarkdown: Int
    /// Stamps and unstamps among the Apple changes.
    public var stamps: Int
    /// Notes the next sync moves to the Trash (deletions confirmed in Contacts).
    public var trash: Int
    public var hold: AppleHold?
    public var breaker: BreakerTrip?
    public var identityWarning: String?
    /// Changes Apple cannot take (no group-capable card, …).
    public var blocked: [String]
    /// Contacts missing from Contacts, waiting for the second snapshot.
    public var awaitingDeleteConfirmation: Int
    public var appleWritesEnabled: Bool
    public var stampContacts: Bool
    public var deviceCount: Int
    /// `limits.max_apple_changes_without_approval`.
    public var appleChangeLimit: Int

    /// Summarizes `plan`.
    public init(_ plan: SyncPlan) {
        apple = UIChangeCounts(apple: plan.apple)
        appleChanges = plan.appleChangeCount
        stamps = plan.apple.filter { $0.kind == .stamp || $0.kind == .unstamp }.count
        changedInMarkdown = appleChanges - stamps
        trash = plan.trash.count
        hold = plan.appleHold
        breaker = plan.breaker
        identityWarning = plan.identityWarning
        blocked = plan.blocked
        awaitingDeleteConfirmation = plan.awaitingDeleteConfirmation.count
        appleWritesEnabled = plan.appleWritesEnabled
        stampContacts = plan.stampContacts
        deviceCount = plan.deviceCount
        appleChangeLimit = plan.markdown.config.limits.maxAppleChanges
    }

    /// Apple changes that the next sync will not make (held).
    public var held: Int { hold == nil ? 0 : appleChanges }

    /// Apple changes the next sync will make.
    public var appleWrites: Int { hold == nil && breaker == nil ? appleChanges : 0 }
}

// MARK: - Banners (docs/ui.md §3, §12)

/// A banner above every screen. Most come from the latest dry run; the
/// last Sync Now adds the lease and lock outcomes immediately.
public enum UIBanner: Hashable, Sendable, Identifiable {
    /// Mass-vanish breaker: nothing is written until resolved. Action: Resume Anyway (confirmed).
    case breaker(BreakerTrip)
    /// More Apple changes than the limit. Action: Apply Anyway (confirmed), approving `count`.
    case blastRadius(count: Int, limit: Int)
    /// Apple changes held because `apple_writes` is off. Action: Open Settings.
    case appleWritesDisabled(held: Int)
    /// Another device leads syncing. Action: Take Over (confirmed).
    case waitingForDevice(name: String, since: Date, expires: Date)
    /// Another run on this Mac is syncing.
    case localRunInProgress
    /// Several devices without stamps. Action: Open Settings.
    case identity(String)

    public var id: String {
        switch self {
        case .breaker: "breaker"
        case .blastRadius: "blast-radius"
        case .appleWritesDisabled: "apple-writes"
        case .waitingForDevice: "lease"
        case .localRunInProgress: "local-lock"
        case .identity: "identity"
        }
    }

    /// The banner text (docs/ui.md §13 wording).
    public var message: String {
        switch self {
        case .breaker(let trip):
            let noun = trip.vanished == 1 ? "contact" : "contacts"
            return trip.side == "apple"
                ? "Sync paused: \(trip.vanished) of \(trip.total) \(noun) disappeared from Contacts. "
                    + "Is iCloud signed in? Nothing was written."
                : "Sync paused: \(trip.vanished) of \(trip.total) notes disappeared from the notes folder. "
                    + "Is the folder available? Nothing was written."
        case .blastRadius(let count, let limit):
            return "\(count) changes to Apple Contacts wait for your approval "
                + "(more than \(limit) in one sync). Notes were still updated."
        case .appleWritesDisabled(let held):
            return "\(held) \(held == 1 ? "change" : "changes") held for Apple Contacts — "
                + "enable writing to Contacts in Settings."
        case .waitingForDevice(let name, let since, let expires):
            return "Waiting for \(name). It started syncing \(UIFormat.relativeDay(since)); "
                + "this Mac syncs when it finishes (expires \(UIFormat.relativeDay(expires)))."
        case .localRunInProgress:
            return "Another sync is running on this Mac (the command line or a scheduled run). Try again shortly."
        case .identity:
            return "Several devices share this folder, but your contacts don't carry sync IDs. "
                + "Turn on “Add sync IDs to contacts” in Settings ▸ Accounts."
        }
    }

    /// Red for the breaker, orange when something waits on you, else gray.
    public var severity: Severity {
        switch self {
        case .breaker: .error
        case .blastRadius, .identity: .warning
        case .appleWritesDisabled, .waitingForDevice, .localRunInProgress: .info
        }
    }

    /// Banner color.
    public enum Severity: Hashable, Sendable {
        case info
        case warning
        case error
    }

    /// Banners for the current state, most severe first.
    ///
    /// - `plan`: the latest dry run (breaker, blast radius, held changes, identity).
    /// - `outcome`: the last Sync Now (lease, lock and breaker right away).
    /// - `status`: stored status (lease held by another device, identity).
    public static func banners(
        status: StoredStatus?, plan: UISyncPlanSummary?, outcome: UISyncOutcome?, deviceID: String, now: Date
    ) -> [UIBanner] {
        var banners: [UIBanner] = []
        if let trip = plan?.breaker {
            banners.append(.breaker(trip))
        } else if case .breaker(let trip)? = outcome {
            banners.append(.breaker(trip))
        }
        switch plan?.hold {
        case .blastRadius(let count, let limit)?: banners.append(.blastRadius(count: count, limit: limit))
        case .appleWritesDisabled? where (plan?.changedInMarkdown ?? 0) > 0:
            // Stamps alone are not worth a banner while writes are off.
            banners.append(.appleWritesDisabled(held: plan?.changedInMarkdown ?? 0))
        default: break
        }
        if let lease = otherLease(status: status, outcome: outcome, deviceID: deviceID, now: now) {
            banners.append(.waitingForDevice(name: lease.deviceName, since: lease.acquiredAt, expires: lease.expiresAt))
        } else if outcome == .localRunInProgress {
            banners.append(.localRunInProgress)
        }
        if let warning = plan?.identityWarning ?? status?.identityWarning {
            banners.append(.identity(warning))
        }
        return banners
    }

    /// The unexpired lease of another device, from the last outcome or the stored status.
    static func otherLease(
        status: StoredStatus?, outcome: UISyncOutcome?, deviceID: String, now: Date
    ) -> VaultLease? {
        var candidates: [VaultLease] = []
        if case .leaseHeldElsewhere(let lease)? = outcome { candidates.append(lease) }
        if let lease = status?.lease { candidates.append(lease) }
        return candidates.first { $0.deviceID != deviceID && $0.expiresAt > now }
    }
}

// MARK: - Activity details

/// Per-side counts of a sync started from the app. `SessionRecord` stores
/// Apple and markdown changes combined, so the app keeps this split (and the
/// held count) in the device state's metadata, keyed by start time.
public struct UISessionDetail: Codable, Hashable, Sendable {
    public var startedAt: Date
    /// The session's trigger (`GUI`, …), so a detail never attaches to a
    /// CLI run that started in the same instant.
    public var trigger: String
    public var apple: UIChangeCounts
    public var markdown: UIChangeCounts
    public var held: Int
    /// `apple writes disabled`, `blast radius`, or `nil`.
    public var holdReason: String?

    /// Creates a detail.
    public init(
        startedAt: Date, trigger: String, apple: UIChangeCounts, markdown: UIChangeCounts, held: Int,
        holdReason: String?
    ) {
        self.startedAt = startedAt
        self.trigger = trigger
        self.apple = apple
        self.markdown = markdown
        self.held = held
        self.holdReason = holdReason
    }

    /// Metadata key in the device state.
    static let metadataKey = "ui_sync_sessions"
    /// Details kept (newest).
    static let limit = 200

    /// Whether this detail belongs to `session`.
    func matches(_ session: SessionRecord) -> Bool {
        session.trigger == trigger && abs(session.startedAt.timeIntervalSince(startedAt)) < 0.001
    }

    static func load(_ state: any SyncStateStore) -> [UISessionDetail] {
        guard let data = try? state.metadata(metadataKey) else { return [] }
        return (try? decoder.decode([UISessionDetail].self, from: data)) ?? []
    }

    static func append(_ detail: UISessionDetail, to state: any SyncStateStore) throws {
        let kept = (load(state) + [detail]).suffix(limit)
        try state.setMetadata(metadataKey, try encoder.encode(Array(kept)))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
