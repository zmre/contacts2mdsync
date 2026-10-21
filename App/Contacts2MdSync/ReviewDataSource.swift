import Contacts2MdCLI
import Foundation

// The seam between the review UI and the sync engine. Everything the M2
// engine offers goes through `UIVaultReader` (Contacts2MdCLI). Conflicts,
// Apple-side deletions, Add to Contacts, Pick Surviving File and the vault's
// write options arrive with two-way sync (M3). They are declared here with
// app-side types, so wiring M3 means filling in `LiveReviewDataSource` and
// flipping `ReviewCapabilities`.

/// What the backing engine can do. Views disable controls whose flag is off.
struct ReviewCapabilities: Sendable, Equatable {
    /// `Sync Now` (two-way) instead of `Export Now`.
    var twoWaySync = false
    /// Field conflicts are detected and can be resolved.
    var conflicts = false
    /// Deletion queues accept decisions.
    var deletionActions = false
    /// Markdown-only notes can be created in Contacts.
    var addToContacts = false
    /// Merge-records groups accept a surviving file.
    var pickSurvivingFile = false
    /// `apple_writes` / `stamp_contacts` can be read and changed.
    var vaultOptions = false

    /// Tooltip for controls that wait on two-way sync.
    static let twoWayHelp = "Arrives with two-way sync"
}

/// Per-vault write options (`.c2mdsync/config.yaml`, M3).
struct VaultOptions: Sendable, Equatable {
    /// `apple_writes`: write markdown edits back to Apple Contacts.
    var appleWrites: Bool
    /// `stamp_contacts`: add `x-c2mdsync:` sync ids to Apple cards.
    var stampContacts: Bool
}

// MARK: - Conflicts (docs/ui.md §4)

/// A record changed on both sides.
struct ConflictRecord: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var path: String
    /// Both sides changed since this time.
    var since: Date?
    var cardIDs: [String]
    var fields: [ConflictField]
}

/// One field that disagrees.
struct ConflictField: Identifiable, Hashable, Sendable {
    var id: String
    /// `Job`, `Phone`.
    var name: String
    /// `mobile`.
    var label: String?
    var previous: String?
    var contacts: String
    var markdown: String
    /// Keep Both only for multi-value fields and the body.
    var options: [ConflictResolution]
}

/// How to resolve a field.
enum ConflictResolution: String, CaseIterable, Hashable, Sendable, Identifiable {
    case keepContacts
    case keepMarkdown
    case keepBoth

    var id: Self { self }

    var title: String {
        switch self {
        case .keepContacts: "Keep Contacts"
        case .keepMarkdown: "Keep Markdown"
        case .keepBoth: "Keep Both"
        }
    }

    /// Batch wording (`Resolve Selected` menu).
    var preferenceTitle: String {
        switch self {
        case .keepContacts: "Prefer Contacts"
        case .keepMarkdown: "Prefer Markdown"
        case .keepBoth: "Keep Both Where Possible"
        }
    }
}

/// A chosen resolution.
struct ConflictChoice: Hashable, Sendable {
    var recordID: String
    var fieldID: String
    var resolution: ConflictResolution
}

// MARK: - Deletions (docs/ui.md §6)

/// Which side lost the record.
enum DeletionSide: String, CaseIterable, Hashable, Sendable, Identifiable {
    case contacts
    case markdown

    var id: Self { self }

    var title: String {
        switch self {
        case .contacts: "Deleted in Contacts"
        case .markdown: "Deleted in Markdown"
        }
    }
}

/// What to do about a deletion. The first option per side is the
/// non-destructive default.
enum DeletionOption: String, CaseIterable, Hashable, Sendable, Identifiable {
    case keepFileUnlink
    case deleteFile
    case restoreContact
    case restoreFile
    case unlinkKeepContact
    case deleteAppleContact

    var id: Self { self }

    var title: String {
        switch self {
        case .keepFileUnlink: "Keep File, Unlink"
        case .deleteFile: "Delete File"
        case .restoreContact: "Restore Contact"
        case .restoreFile: "Restore File"
        case .unlinkKeepContact: "Unlink, Keep Contact"
        case .deleteAppleContact: "Delete Apple Contact…"
        }
    }

    var isDestructive: Bool { self == .deleteFile || self == .deleteAppleContact }

    static func options(for side: DeletionSide) -> [DeletionOption] {
        switch side {
        case .contacts: [.keepFileUnlink, .deleteFile, .restoreContact]
        case .markdown: [.restoreFile, .unlinkKeepContact, .deleteAppleContact]
        }
    }
}

/// A queued deletion.
struct DeletionRow: Identifiable, Hashable, Sendable {
    var id: String
    var side: DeletionSide
    var title: String
    /// The file (Deleted in Contacts) or where it was (Deleted in Markdown).
    var path: String?
    var noticed: Date?
    var cardIDs: [String]
    /// `false` while the engine cannot act on it yet (M2 missing-note items).
    var isActionable: Bool

    var options: [DeletionOption] { DeletionOption.options(for: side) }
}

/// A chosen deletion action.
struct DeletionChoice: Hashable, Sendable {
    var id: String
    var option: DeletionOption
}

// MARK: - The protocol

/// The engine operation is not available yet.
struct ReviewUnavailable: Error, CustomStringConvertible {
    let feature: String

    var description: String { "\(feature) arrives with two-way sync." }
}

/// Everything the review UI reads and writes. Implementations run their
/// work off the main actor.
protocol ReviewDataSource: Sendable {
    var capabilities: ReviewCapabilities { get }

    /// Stored state and a folder scan; `nil` when the folder was never exported to.
    func load(root: URL) async throws -> UIVaultData?
    /// A dry run (reads Contacts); refreshes the pending review queue.
    func plan(root: URL) async throws -> UIPlanSummary
    /// Export Now (M2) / Sync Now (M3).
    func sync(root: URL) async throws -> UIExportSummary
    /// Appends review answers to the decision log.
    func record(_ answers: [UIReviewDecision], root: URL) async throws
    func setDefaultFolder(_ folder: String, root: URL) async throws

    // M3
    func conflicts(root: URL) async throws -> [ConflictRecord]
    func resolve(_ choices: [ConflictChoice], root: URL) async throws
    /// Engine deletion queues (M2 missing notes come from `UIReviewQueues`).
    func deletions(root: URL) async throws -> [DeletionRow]
    func applyDeletions(_ choices: [DeletionChoice], root: URL) async throws
    func pickSurvivingFile(itemID: String, path: String, root: URL) async throws
    func addToContacts(paths: [String], root: URL) async throws
    /// `nil` until the engine exposes the options.
    func vaultOptions(root: URL) async throws -> VaultOptions?
    func setVaultOptions(_ options: VaultOptions, root: URL) async throws
}

/// The M2 engine through `UIVaultReader`; M3 operations report `ReviewUnavailable`.
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
    func sync(root: URL) async throws -> UIExportSummary { try reader(root).export() }

    @concurrent
    func record(_ answers: [UIReviewDecision], root: URL) async throws { try reader(root).record(answers) }

    @concurrent
    func setDefaultFolder(_ folder: String, root: URL) async throws { try reader(root).setDefaultFolder(folder) }

    func conflicts(root: URL) async throws -> [ConflictRecord] { [] }

    func resolve(_ choices: [ConflictChoice], root: URL) async throws {
        throw ReviewUnavailable(feature: "Resolving conflicts")
    }

    func deletions(root: URL) async throws -> [DeletionRow] { [] }

    func applyDeletions(_ choices: [DeletionChoice], root: URL) async throws {
        throw ReviewUnavailable(feature: "Confirming deletions")
    }

    func pickSurvivingFile(itemID: String, path: String, root: URL) async throws {
        throw ReviewUnavailable(feature: "Merging files")
    }

    func addToContacts(paths: [String], root: URL) async throws {
        throw ReviewUnavailable(feature: "Adding notes to Contacts")
    }

    func vaultOptions(root: URL) async throws -> VaultOptions? { nil }

    func setVaultOptions(_ options: VaultOptions, root: URL) async throws {
        throw ReviewUnavailable(feature: "Changing write options")
    }
}
