public import ContactModel
public import Foundation
public import VaultIndex

/// Options for a one-way Apple → markdown export.
public struct ExportOptions: Hashable, Sendable {
    /// Re-create notes whose file was deleted (otherwise they are reported and skipped).
    public var restoreMissing: Bool

    /// Creates options.
    public init(restoreMissing: Bool = false) {
        self.restoreMissing = restoreMissing
    }
}

/// One markdown file to create or update. The bytes are final: already
/// emitted and validated by re-parsing.
public struct FileChange: Hashable, Sendable {
    public var path: String
    public var recordID: UUID
    /// Contact title, for output.
    public var title: String
    public var data: Data
    /// Compare-and-swap precondition for the write.
    public var expecting: WriteExpectation
    /// Frontmatter keys that changed (updates only).
    public var changedFields: [String]
}

/// A contact photo sidecar to write.
public struct ImageWrite: Hashable, Sendable {
    public var path: String
    public var recordID: UUID
    public var data: Data
}

/// One member of a duplicate cluster, for display.
public struct ClusterMember: Hashable, Sendable {
    public var unifiedID: String
    public var title: String
    public var accounts: [AccountKind]
    /// Path of the note this member is (or will be) exported to, if any.
    public var path: String?
}

/// Something that needs a human (Review in the app; WARNING in the CLI).
public enum ReviewItem: Hashable, Sendable {
    /// Unified contacts that look like the same person.
    case duplicateCluster(members: [ClusterMember], reasons: [String])
    /// A new Apple contact matches an existing, unlinked note: not created.
    case possibleMatch(title: String, path: String, reason: String)
    /// Several notes carry the same `c2mdsync.id` (a copied file): record paused.
    case duplicateSyncID(id: UUID, paths: [String])
    /// One unified contact carries several different stamps (linked cards).
    case multipleStamps(title: String, ids: [UUID])
    /// A previously exported note is gone (deleted?): not re-created.
    case missingFile(title: String, id: UUID, lastPath: String?)
    /// A note could not be parsed; never written to.
    case unreadableFile(path: String, problem: String)
}

/// A contact left out of this export, and why.
public struct SkippedContact: Hashable, Sendable {
    public var title: String
    public var reason: String
}

/// A request to stamp an Apple card with its record id.
public struct StampRequest: Hashable, Sendable {
    public var cardID: String
    public var recordID: UUID
    public var title: String
}

/// The dry-run result of planning an export: exactly what `ExportExecutor`
/// would write, plus everything that needs review.
public struct ExportPlan: Sendable {
    public var creates: [FileChange] = []
    public var updates: [FileChange] = []
    /// Exported contacts whose note is already byte-identical.
    public var unchanged: Int = 0
    public var images: [ImageWrite] = []
    public var reviews: [ReviewItem] = []
    public var skipped: [SkippedContact] = []
    /// Non-blocking observations (duplicate titles, …).
    public var warnings: [String] = []
    /// Cards to stamp (only applied with an explicit opt-in and a backup).
    public var stamps: [StampRequest] = []
    /// Bindings to persist after a successful run.
    public var bindings: [UUID: RecordBinding] = [:]
    /// The vault configuration after this export.
    public var config: VaultConfig
    /// The config file text to write, when it changed.
    public var configText: String?
    /// Number of Apple contacts considered.
    public var appleContactCount: Int = 0
    /// Contact notes without an `c2mdsync.id` (markdown-only candidates, M2).
    public var markdownOnly: Int = 0

    /// Creates an empty plan.
    public init(config: VaultConfig) { self.config = config }

    /// `true` when nothing would be written.
    public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && images.isEmpty && configText == nil }
}
