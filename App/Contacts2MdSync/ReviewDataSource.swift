import Contacts2MdCLI
import Foundation
import SyncEngine

// The seam between the review UI and the sync engine. Everything goes
// through `UIVaultReader` (Contacts2MdCLI), the same `VaultSession` paths as
// `contacts2md`. Review answers (conflicts, deletions, Add to Contacts,
// duplicates incl. Keep This File, matches) are decision-log entries recorded with `record`; the
// next sync applies them. Screen data (conflict records, deletion rows) is
// derived from `UIVaultData` by `UIReviewQueues`.

/// What the backing engine can do. Views disable controls whose flag is off.
struct ReviewCapabilities: Sendable, Equatable {
    /// `Sync Now` (two-way) instead of `Export Now`.
    var twoWaySync = true
    /// Field conflicts are detected and can be resolved.
    var conflicts = true
    /// Deletion queues accept decisions.
    var deletionActions = true
    /// Markdown-only notes can be created in Contacts.
    var addToContacts = true
    /// `apple_writes` / `stamp_contacts` can be read and changed.
    var vaultOptions = true

    /// Tooltip for controls the engine does not support yet.
    static let unsupportedHelp = "Not supported by the sync engine yet"
}

/// Everything the review UI reads and writes. Implementations run their
/// work off the main actor.
protocol ReviewDataSource: Sendable {
    var capabilities: ReviewCapabilities { get }

    /// Stored state and a folder scan; `nil` when the folder was never exported to.
    func load(root: URL) async throws -> UIVaultData?
    /// A dry run (reads Contacts); refreshes the pending review queue.
    /// `progress` hears each phase as it starts (any thread).
    func plan(root: URL, progress: @escaping @Sendable (SyncPhase) -> Void) async throws -> UIPlanSummary
    /// Sync Now (the first export on this Mac when it has never synced).
    func sync(
        _ request: UISyncRequest, root: URL, progress: @escaping @Sendable (SyncPhase) -> Void
    ) async throws -> UISyncOutcome
    /// Appends review answers to the decision log.
    func record(_ answers: [UIReviewDecision], root: URL) async throws
    func setDefaultFolder(_ folder: String, root: URL) async throws
    /// Writes `apple_writes` / `stamp_contacts`.
    func setVaultOptions(_ options: UIVaultOptions, root: URL) async throws
    /// Gives this Mac's vault lease up (live sync not running); the lease afterwards.
    func releaseLease(root: URL) async throws -> LeaseStatus
    /// Rescan Everything: forgets this Mac's caches (the next run reads everything).
    func rescanEverything(root: URL) async throws -> RescanOutcome
    /// Reset Sync State: backup, then forgets this Mac's sync state for the vault.
    func resetSyncState(root: URL) async throws -> StateResetOutcome
    /// The change log of one run (Activity inspector).
    func sessionChanges(of session: SessionRecord, root: URL) async throws -> [SessionChange]
    /// File ▸ Export Log…: this Mac's runs with their change logs.
    func activityLog(format: UIActivityLogFormat, root: URL) async throws -> String
    /// Renamed contacts still linked by their old title from other notes.
    func renamedLinks(root: URL) async throws -> [UIRenamedLinks]
    /// Update Links (user action): rewrites those links; returns the notes rewritten.
    func updateLinks(_ links: UIRenamedLinks, root: URL) async throws -> [String]
    /// Stops reporting a rename.
    func dismissRename(_ rename: TitleRename, root: URL) async throws
}

/// The live engine through `UIVaultReader`.
struct LiveReviewDataSource: ReviewDataSource {
    let capabilities = ReviewCapabilities()

    private func reader(_ root: URL) -> UIVaultReader {
        var environment = CLIEnvironment.live()
        environment.trigger = "GUI"
        environment.output = .capturing()
        return UIVaultReader(root: root, environment: environment)
    }

    @concurrent
    func load(root: URL) async throws -> UIVaultData? { try reader(root).read() }

    @concurrent
    func plan(root: URL, progress: @escaping @Sendable (SyncPhase) -> Void) async throws -> UIPlanSummary {
        try reader(root).plan(progress: progress)
    }

    @concurrent
    func sync(
        _ request: UISyncRequest, root: URL, progress: @escaping @Sendable (SyncPhase) -> Void
    ) async throws -> UISyncOutcome {
        try reader(root).sync(request, progress: progress)
    }

    @concurrent
    func record(_ answers: [UIReviewDecision], root: URL) async throws { try reader(root).record(answers) }

    @concurrent
    func setDefaultFolder(_ folder: String, root: URL) async throws { try reader(root).setDefaultFolder(folder) }

    @concurrent
    func setVaultOptions(_ options: UIVaultOptions, root: URL) async throws { try reader(root).setOptions(options) }

    @concurrent
    func releaseLease(root: URL) async throws -> LeaseStatus { try reader(root).releaseLease() }

    @concurrent
    func rescanEverything(root: URL) async throws -> RescanOutcome { try reader(root).rescanEverything() }

    @concurrent
    func resetSyncState(root: URL) async throws -> StateResetOutcome { try reader(root).resetSyncState() }

    @concurrent
    func sessionChanges(of session: SessionRecord, root: URL) async throws -> [SessionChange] {
        try reader(root).sessionChanges(of: session)
    }

    @concurrent
    func activityLog(format: UIActivityLogFormat, root: URL) async throws -> String {
        try reader(root).activityLog(format: format)
    }

    @concurrent
    func renamedLinks(root: URL) async throws -> [UIRenamedLinks] { try reader(root).renamedLinks() }

    @concurrent
    func updateLinks(_ links: UIRenamedLinks, root: URL) async throws -> [String] {
        try reader(root).updateLinks(links)
    }

    @concurrent
    func dismissRename(_ rename: TitleRename, root: URL) async throws { try reader(root).dismissRename(rename) }
}
