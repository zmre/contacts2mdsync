public import Foundation

/// What the last scan learned about one file, keyed by root-relative path
/// (the device-state `file_cache` table, architecture §4).
///
/// A file whose (modification date, size) still match is not re-read when the
/// cache says it is not a contact note, or that it failed to parse: those are
/// the bulk of a notes folder, and only their title, aliases and problem are
/// needed. Contact notes are always re-read, because export patches them.
/// Dataless (iCloud-evicted) files are never read; their cached facts stand in.
public struct FileCacheEntry: Codable, Hashable, Sendable {
    /// What the file turned out to be.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// `type: person|organization` note.
        case contact
        /// Any other readable markdown file.
        case other
        /// Unreadable: invalid frontmatter or not UTF-8.
        case problem
    }

    public var path: String
    public var modificationDate: Date
    public var size: Int
    public var sha256: String
    public var kind: Kind
    /// `c2mdsync.id` of a contact note.
    public var syncID: UUID?
    /// mbr title (frontmatter `title`, else nil → filename stem).
    public var title: String?
    /// `aliases` names.
    public var aliases: [String]
    /// Parse error of a `.problem` file.
    public var problem: String?
    /// A `.problem` file that looks like a contact note (has `type: person`,
    /// `type: organization` or a `c2mdsync:` key in its text).
    public var contactRelated: Bool

    /// Creates an entry.
    public init(
        path: String, modificationDate: Date, size: Int, sha256: String, kind: Kind, syncID: UUID? = nil,
        title: String? = nil, aliases: [String] = [], problem: String? = nil, contactRelated: Bool = false
    ) {
        self.path = path
        self.modificationDate = modificationDate
        self.size = size
        self.sha256 = sha256
        self.kind = kind
        self.syncID = syncID
        self.title = title
        self.aliases = aliases
        self.problem = problem
        self.contactRelated = contactRelated
    }

    /// `true` when `file` still has the cached modification date and size.
    public func matches(_ file: FileEntry) -> Bool {
        size == file.size && abs(modificationDate.timeIntervalSince(file.modificationDate)) < 0.001
    }
}

/// Glob matching for `scope.markdown.exclude_paths` (root-relative paths):
/// `**` matches across folders, `*` within one path component, `?` one
/// character.
public enum PathGlob {
    /// `true` when `path` matches `pattern`.
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        Matcher(pattern: Array(pattern), path: Array(path)).match(0, 0)
    }

    private struct Matcher {
        let pattern: [Character]
        let path: [Character]

        func match(_ patternIndex: Int, _ pathIndex: Int) -> Bool {
            guard patternIndex < pattern.count else { return pathIndex == path.count }
            if pattern[patternIndex] == "*" {
                let isDouble = patternIndex + 1 < pattern.count && pattern[patternIndex + 1] == "*"
                return isDouble ? doubleStar(patternIndex + 2, pathIndex) : star(patternIndex + 1, pathIndex)
            }
            guard pathIndex < path.count else { return false }
            let matchesHere =
                pattern[patternIndex] == "?" ? path[pathIndex] != "/" : pattern[patternIndex] == path[pathIndex]
            return matchesHere && match(patternIndex + 1, pathIndex + 1)
        }

        /// `*`: any run of characters within one path component.
        private func star(_ rest: Int, _ pathIndex: Int) -> Bool {
            var index = pathIndex
            while true {
                if match(rest, index) { return true }
                guard index < path.count, path[index] != "/" else { return false }
                index += 1
            }
        }

        /// `**`: any run of characters, across folders; `**/` also matches no folder.
        private func doubleStar(_ rest: Int, _ pathIndex: Int) -> Bool {
            if rest == pattern.count { return true }
            if pattern[rest] == "/", match(rest + 1, pathIndex) { return true }
            return (pathIndex...path.count).contains { match(rest, $0) }
        }
    }
}
