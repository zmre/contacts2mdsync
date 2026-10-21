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
    func plan(root: URL) async throws -> UIPlanSummary
    /// Sync Now (the first export on this Mac when it has never synced).
    func sync(_ request: UISyncRequest, root: URL) async throws -> UISyncOutcome
    /// Appends review answers to the decision log.
    func record(_ answers: [UIReviewDecision], root: URL) async throws
    func setDefaultFolder(_ folder: String, root: URL) async throws
    /// Writes `apple_writes` / `stamp_contacts`.
    func setVaultOptions(_ options: UIVaultOptions, root: URL) async throws
    /// Gives this Mac's vault lease up (live sync not running); the lease afterwards.
    func releaseLease(root: URL) async throws -> LeaseStatus
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
    func plan(root: URL) async throws -> UIPlanSummary { try reader(root).plan() }

    @concurrent
    func sync(_ request: UISyncRequest, root: URL) async throws -> UISyncOutcome {
        try reader(root).sync(request)
    }

    @concurrent
    func record(_ answers: [UIReviewDecision], root: URL) async throws { try reader(root).record(answers) }

    @concurrent
    func setDefaultFolder(_ folder: String, root: URL) async throws { try reader(root).setDefaultFolder(folder) }

    @concurrent
    func setVaultOptions(_ options: UIVaultOptions, root: URL) async throws { try reader(root).setOptions(options) }

    @concurrent
    func releaseLease(root: URL) async throws -> LeaseStatus { try reader(root).releaseLease() }
}
