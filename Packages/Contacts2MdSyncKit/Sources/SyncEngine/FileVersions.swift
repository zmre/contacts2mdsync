public import Foundation
public import VaultIndex

// iCloud conflict versions in review items and plans (architecture §11, M6).

extension ReviewItem {
    /// ` (iCloud conflicted copy: …)` for copied notes that look like one.
    var conflictedCopyHint: String {
        let copies = conflictedCopyPaths
        return copies.isEmpty ? "" : " (iCloud conflicted copy: \(copies.joined(separator: ", ")))"
    }

    /// For a copied note (`duplicateSyncID`): the copies whose names look
    /// like iCloud conflicted copies of another path in the group
    /// (`Jane Doe 2.md` next to `Jane Doe.md`). Empty otherwise.
    public var conflictedCopyPaths: [String] {
        guard case .duplicateSyncID(_, let paths) = self else { return [] }
        return FileVersionConflict.conflictedCopies(among: paths)
    }
}

/// One iCloud conflict version, for review.
public struct FileVersionInfo: Codable, Hashable, Sendable {
    public var sha256: String
    public var modifiedAt: Date?
    /// The computer that saved it, when iCloud says.
    public var deviceName: String?
    /// What differs from the current contents (contact keys, or `text`).
    public var differences: [String]

    /// Creates a summary.
    public init(sha256: String, modifiedAt: Date? = nil, deviceName: String? = nil, differences: [String] = []) {
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
        self.deviceName = deviceName
        self.differences = differences
    }
}

/// A file with iCloud conflict versions that differ from its current
/// contents (architecture §11). Decided with `keep-current` or
/// `keep-other:N`, bound to the current contents and the version set.
public struct FileVersionConflict: Codable, Hashable, Sendable {
    public var path: String
    /// Note title (or a description for vault files), for display.
    public var title: String
    /// The note's record, if it is a synced note (paused until decided).
    public var recordID: UUID?
    /// SHA-256 of the current contents when the conflict was found.
    public var currentSHA256: String
    /// The differing versions, in a stable order (by sha256).
    public var versions: [FileVersionInfo]

    /// Creates a conflict.
    public init(path: String, title: String, recordID: UUID?, currentSHA256: String, versions: [FileVersionInfo]) {
        self.path = path
        self.title = title
        self.recordID = recordID
        self.currentSHA256 = currentSHA256
        self.versions = versions
    }

    /// Identifies the version set a decision was made against.
    public var versionsKey: String { Self.key(versions.map(\.sha256)) }

    static func key(_ shas: [String]) -> String { shas.sorted().joined(separator: ",") }

    /// One-line description.
    public var summary: String {
        let sources = versions.map { version in
            let from = version.deviceName.map { "from \($0)" } ?? "another version"
            let what = version.differences.isEmpty ? "" : ": " + version.differences.joined(separator: ", ")
            return from + what
        }
        return "\(path) (\"\(title)\"): iCloud kept \(versions.count) conflicting "
            + (versions.count == 1 ? "version" : "versions") + " (\(sources.joined(separator: "; ")))"
    }

    /// Paths that look like iCloud conflicted copies of another path in
    /// `paths`: same folder, stem `<other stem> <number>` (`Jane Doe 2.md`).
    public static func conflictedCopies(among paths: [String]) -> [String] {
        let stems = Set(
            paths.map { (VaultPath.directory(of: $0), VaultPath.stem(of: $0).lowercased()) }.map {
                "\($0.0)/\($0.1)"
            })
        return paths.filter { path in
            let stem = VaultPath.stem(of: path).lowercased()
            guard let space = stem.lastIndex(of: " "), stem[stem.index(after: space)...].allSatisfy(\.isNumber),
                stem.index(after: space) < stem.endIndex
            else { return false }
            return stems.contains("\(VaultPath.directory(of: path))/\(stem[..<space])")
        }.sorted()
    }
}

/// Resolving a file's iCloud conflict versions (executed by the leader).
public struct FileVersionResolution: Hashable, Sendable {
    public var path: String
    /// The version whose bytes become current; `nil` keeps the current contents.
    public var keep: FileConflictVersion?
    /// `identical` (all versions canonically equal) or `decision`.
    public var reason: String

    /// Creates a resolution.
    public init(path: String, keep: FileConflictVersion?, reason: String) {
        self.path = path
        self.keep = keep
        self.reason = reason
    }
}
