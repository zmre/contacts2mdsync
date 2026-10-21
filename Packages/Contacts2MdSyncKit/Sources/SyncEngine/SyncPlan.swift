public import ContactModel
public import Foundation
public import VaultIndex

/// A cached image hash: valid while the file keeps this mtime and size.
public struct ImageHashEntry: Codable, Hashable, Sendable {
    public var modificationDate: Date
    public var size: Int
    public var sha256: String

    /// Creates an entry.
    public init(modificationDate: Date, size: Int, sha256: String) {
        self.modificationDate = modificationDate
        self.size = size
        self.sha256 = sha256
    }

    func matches(_ file: FileEntry) -> Bool {
        size == file.size && abs(modificationDate.timeIntervalSince(file.modificationDate)) < 0.001
    }
}

/// How a run treats anything that needs a human (architecture §15 "Shared
/// engine guarantees"). Both queue review items exactly the same way; the
/// GUI presents them, headless runs report them. Nothing is resolved on the
/// user's behalf in either mode.
public enum DecisionPolicy: String, Hashable, Sendable, Codable {
    /// Queue and present (the app).
    case gui
    /// Queue and report (`contacts2md sync`, launchd, cron).
    case headless
}

/// Options for a two-way sync run.
public struct SyncOptions: Hashable, Sendable {
    public var export: ExportOptions
    public var policy: DecisionPolicy
    /// Overrides `limits.max_apple_changes_without_approval` for this run.
    public var maxAppleChanges: Int?
    /// Proceed although more records vanished than the breaker allows.
    public var allowMassVanish: Bool
    /// A record whose contact is gone counts as deleted in Contacts only when
    /// it was already missing this long ago (two full snapshots, §9).
    public var deleteConfirmInterval: TimeInterval

    /// Creates options.
    public init(
        export: ExportOptions = ExportOptions(), policy: DecisionPolicy = .headless, maxAppleChanges: Int? = nil,
        allowMassVanish: Bool = false, deleteConfirmInterval: TimeInterval = 10 * 60
    ) {
        self.export = export
        self.policy = policy
        self.maxAppleChanges = maxAppleChanges
        self.allowMassVanish = allowMassVanish
        self.deleteConfirmInterval = deleteConfirmInterval
    }
}

/// Everything a sync plan is computed from: the export inputs plus the
/// device's sync bookkeeping.
public struct SyncInputs: Sendable {
    public var export: ExportInputs
    /// Writes cards refused before.
    public var unapplyable: [UnapplyableEntry]
    /// Records whose Apple contact was missing, with when that was first seen.
    public var vanished: [UUID: Date]
    /// Records already queued as "note deleted" (not counted again by the breaker).
    public var knownMissingNotes: Set<UUID>
    /// Containers the store may write to.
    public var writableContainerIDs: [String]
    /// Devices that ever used this vault (`.c2mdsync/devices/`).
    public var deviceIDs: [String]
    /// Non-markdown files (images) by path, from one enumeration: images are
    /// hashed only when their (mtime, size) changed, and dataless (evicted)
    /// ones are never read. `nil`: read images directly (tests).
    public var files: [String: FileEntry]?
    /// Image hashes from earlier runs, by path.
    public var imageHashes: [String: ImageHashEntry] = [:]

    /// Creates inputs.
    public init(
        export: ExportInputs, unapplyable: [UnapplyableEntry] = [], vanished: [UUID: Date] = [:],
        knownMissingNotes: Set<UUID> = [], writableContainerIDs: [String]? = nil, deviceIDs: [String] = []
    ) {
        self.export = export
        self.unapplyable = unapplyable
        self.vanished = vanished
        self.knownMissingNotes = knownMissingNotes
        self.writableContainerIDs = writableContainerIDs ?? export.snapshot.containers.map(\.id)
        self.deviceIDs = deviceIDs
    }
}

/// What kind of Apple change a record needs.
public enum AppleChangeKind: String, Hashable, Sendable, Codable {
    /// Field, group or note edits on existing cards.
    case update
    /// A contact created from a markdown-only note (opted in).
    case create
    /// Cards deleted (confirmed markdown delete).
    case delete
    /// Only the identity stamp is added.
    case stamp
    /// The stamp is removed (unlink).
    case unstamp
}

/// The Apple writes for one record.
public struct AppleRecordChange: Hashable, Sendable {
    public var recordID: UUID
    /// Contact title, for output.
    public var title: String
    public var kind: AppleChangeKind
    public var operations: [AppleWriteOperation]
    /// Markdown field names that change (`emails`, `job_title`, …).
    public var fields: [String]

    /// Creates a change.
    public init(
        recordID: UUID, title: String, kind: AppleChangeKind, operations: [AppleWriteOperation], fields: [String]
    ) {
        self.recordID = recordID
        self.title = title
        self.kind = kind
        self.operations = operations
        self.fields = fields
    }
}

/// Why planned Apple writes are not made this run.
public enum AppleHold: Hashable, Sendable {
    /// `apple_writes` is not enabled in `.c2mdsync/config.yaml` (not an error).
    case appleWritesDisabled
    /// More changes than the limit (blast radius, exit 2).
    case blastRadius(count: Int, limit: Int)

    /// `held: …` reason text.
    public var reason: String {
        switch self {
        case .appleWritesDisabled: "apple writes disabled"
        case .blastRadius(let count, let limit):
            "\(count) Apple changes exceed the limit of \(limit) (use --max-apple-changes \(count) to allow)"
        }
    }
}

/// A safety breaker that stops the whole run before anything is written.
public struct BreakerTrip: Hashable, Sendable {
    /// `apple` or `markdown`.
    public var side: String
    public var vanished: Int
    public var total: Int

    /// Message for stderr.
    public var message: String {
        let place = side == "apple" ? "from Contacts" : "from the notes folder"
        return "mass-vanish breaker: \(vanished) of \(total) synced records vanished \(place) in one run; "
            + "nothing was written (Contacts account or iCloud off? folder unmounted?). "
            + "Fix the cause, or rerun with --allow-mass-vanish to queue them as deletions."
    }
}

/// A note moved to the Trash (a deletion confirmed in Contacts).
public struct NoteTrash: Hashable, Sendable {
    public var recordID: UUID
    public var path: String
    public var title: String
}

/// The dry-run result of planning a two-way sync: the markdown side (an
/// `ExportPlan`: notes, images, config, review items), the Apple side, and
/// the safety verdicts. `SyncExecutor` performs it.
public struct SyncPlan: Sendable {
    /// Markdown writes, review items (including conflicts and delete queues),
    /// skipped contacts and bindings.
    public var markdown: ExportPlan
    /// Apple writes per record (updates, creates, deletes, stamps).
    public var apple: [AppleRecordChange] = []
    /// Conflicts (also in `markdown.reviews`).
    public var conflicts: [SyncConflict] = []
    /// Notes to move to the Trash.
    public var trash: [NoteTrash] = []
    /// Why the Apple writes are not made (`nil`: they are).
    public var appleHold: AppleHold?
    /// A tripped breaker: nothing is written at all.
    public var breaker: BreakerTrip?
    /// Changes that cannot be applied to Apple (no group-capable card, …).
    public var blocked: [String] = []
    /// One-line identity warning (several devices without stamps), if any.
    public var identityWarning: String?
    /// Devices that use this vault.
    public var deviceCount = 1
    /// `apple_writes` / `stamp_contacts` in effect.
    public var appleWritesEnabled = false
    public var stampContacts = false
    /// Records possibly deleted in Contacts, waiting for a second snapshot.
    public var awaitingDeleteConfirmation: [String] = []

    // Bookkeeping for the executor.
    var removedRecords = Set<UUID>()
    var unapplyableKept: [UnapplyableEntry] = []
    var newUnapplyable: [UnapplyableEntry] = []
    var vanished: [UUID: Date] = [:]
    /// Image hashes to remember (the cache, refreshed).
    var imageHashes: [String: ImageHashEntry] = [:]
    var records: [UUID: RecordSyncState] = [:]
    var context: SyncContext?

    /// Creates a plan around a markdown plan.
    public init(markdown: ExportPlan) { self.markdown = markdown }

    /// Number of Apple changes (one per record, create, delete or stamp).
    public var appleChangeCount: Int { apple.count }

    /// Apple writes that will actually be made.
    public var appleWritesAllowed: Bool { appleHold == nil && breaker == nil }

    /// `true` when nothing would be written on either side.
    public var isEmpty: Bool { markdown.isEmpty && apple.isEmpty && trash.isEmpty }

    /// Whether anything needs a decision (exit code 1).
    public var needsReview: Bool { markdown.needsReview }
}

/// Per-record facts the executor needs to refresh the merge base.
struct RecordSyncState: Sendable {
    var recordID: UUID
    /// Card ids at plan time (to find the contact again after writes).
    var cardIDs: [String]
    var stampID: UUID?
    /// The note as planned (written), and as it was (if the write fails).
    var plannedNote: CanonicalContact
    var existingNote: CanonicalContact?
    var markdownImage: ImageState
    /// Image state after a planned sidecar write.
    var plannedImage: ImageState
    var previousBase: RecordBase?
    /// Apple side at plan time (used when nothing was written to Apple).
    var apple: AppleContact?
    var title: String
}

/// Run-wide context shared by planner and executor.
struct SyncContext: Sendable {
    var builder: ViewBuilder
    var config: VaultConfig
    var groups: [AppleGroup]
    var writableContainerIDs: [String]
}
