internal import ContactModel
public import Foundation

/// A note's title regenerated because Apple's name changed (§7 title rule).
/// Synced notes' `to:` links follow at once; links in other notes are only
/// reported (Overview), and rewritten on the user's explicit action (§8).
public struct TitleRename: Codable, Hashable, Sendable {
    public var recordID: UUID
    public var oldTitle: String
    public var newTitle: String

    /// Creates a rename.
    public init(recordID: UUID, oldTitle: String, newTitle: String) {
        self.recordID = recordID
        self.oldTitle = oldTitle
        self.newTitle = newTitle
    }
}

extension SyncStateStore {
    /// Metadata key of the renames remembered for the Overview's link report.
    static var recentRenamesKey: String { "recent_renames" }

    /// How many renames are remembered (newest kept).
    public static var recentRenameLimit: Int { 20 }

    /// Renames of recent runs whose links in other notes may still use the old title.
    public func recentRenames() throws -> [TitleRename] {
        guard let data = try metadata(Self.recentRenamesKey) else { return [] }
        return (try? JSONDecoder().decode([TitleRename].self, from: data)) ?? []
    }

    /// Replaces the remembered renames (at most `recentRenameLimit`, newest kept).
    public func saveRecentRenames(_ renames: [TitleRename]) throws {
        let kept = Array(renames.suffix(Self.recentRenameLimit))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try setMetadata(Self.recentRenamesKey, kept.isEmpty ? nil : try encoder.encode(kept))
    }

    /// Remembers the renames of an executed run whose note was written.
    public func rememberRenames(_ plan: SyncPlan, result: SyncResult) throws {
        let written = Set(result.markdown.updated.map(\.recordID))
        let new = plan.titleRenames.filter { written.contains($0.recordID) }
        guard !new.isEmpty else { return }
        let replaced = Set(new.map { ComparisonKeys.name($0.oldTitle) })
        try saveRecentRenames(
            try recentRenames().filter { !replaced.contains(ComparisonKeys.name($0.oldTitle)) } + new)
    }
}
