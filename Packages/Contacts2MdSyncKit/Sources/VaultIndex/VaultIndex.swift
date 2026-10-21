public import ContactModel
public import Foundation
public import MarkdownCodec

/// One markdown file in the vault.
public struct VaultEntry: Sendable {
    /// Root-relative path.
    public var path: String
    /// Stamp at scan time (compare-and-swap token for updates); `nil` when unread.
    public var stamp: FileStamp?
    /// The parse, when the file was readable and its frontmatter valid.
    public var note: ParsedNote?
    /// Why the file could not be parsed (invalid YAML, not UTF-8, …).
    public var problem: String?
    /// iCloud placeholder that was not read.
    public var isDataless: Bool

    /// The contact, for `type: person|organization` notes.
    public var contact: CanonicalContact? { note?.contact }
    /// `c2mdsync.id` of a contact note.
    public var syncID: UUID? { contact?.sync.id }
    /// Filename stem.
    public var stem: String { VaultPath.stem(of: path) }
    /// mbr's title for matching: frontmatter `title`, else the filename stem.
    public var title: String { note?.title ?? stem }
}

/// What the engine knows about the notes folder after one scan (M1 subset of
/// architecture §2 `VaultIndex`): every markdown file, its contact parse, and
/// lookups by `c2mdsync.id`, title and filename stem.
///
/// Identity is `c2mdsync.id`, never the path: a file moved to any subfolder is
/// still found by id.
public struct VaultIndex: Sendable {
    /// Version of the index format.
    public static let indexVersion = 1

    /// Every markdown file, sorted by path.
    public let entries: [VaultEntry]
    private let byID: [UUID: [Int]]
    private let stems: Set<String>
    private let titleKeys: Set<String>

    /// Builds an index from entries (sorted by path for determinism).
    public init(entries: [VaultEntry]) {
        let sorted = entries.sorted { $0.path < $1.path }
        self.entries = sorted
        var byID: [UUID: [Int]] = [:]
        for (index, entry) in sorted.enumerated() {
            if let id = entry.syncID { byID[id, default: []].append(index) }
        }
        self.byID = byID
        self.stems = Set(sorted.map { $0.stem.lowercased() })
        self.titleKeys = Set(sorted.flatMap { [$0.title] + ($0.note?.aliasNames ?? []) }.map(ComparisonKeys.name))
    }

    /// Scans the vault: all `.md`/`.markdown` files except under `excludedFolders`.
    public static func scan(_ fs: any VaultFS, excludedFolders: [String] = []) throws -> VaultIndex {
        let excluded = excludedFolders.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let files = try fs.enumerate().filter { file in
            let lower = file.path.lowercased()
            return (lower.hasSuffix(".md") || lower.hasSuffix(".markdown"))
                && !excluded.contains { file.path.hasPrefix($0) }
        }
        let entries = files.map { file -> VaultEntry in
            var entry = VaultEntry(path: file.path, stamp: nil, note: nil, problem: nil, isDataless: file.isDataless)
            guard !file.isDataless else { return entry }
            do {
                let (data, stamp) = try fs.read(file.path)
                entry.stamp = stamp
                guard let text = String(data: data, encoding: .utf8) else {
                    entry.problem = "not valid UTF-8"
                    return entry
                }
                entry.note = try MarkdownCodec.parse(text)
            } catch {
                entry.problem = String(describing: error)
            }
            return entry
        }
        return VaultIndex(entries: entries)
    }

    /// Contact notes (`type: person|organization`).
    public var contacts: [VaultEntry] { entries.filter { $0.contact != nil } }

    /// Files with the given `c2mdsync.id` (more than one = copied file).
    public func entries(withID id: UUID) -> [VaultEntry] {
        (byID[id] ?? []).map { entries[$0] }
    }

    /// `c2mdsync.id`s that appear in more than one file.
    public var duplicateIDs: [UUID: [String]] {
        byID.filter { $0.value.count > 1 }.mapValues { $0.map { entries[$0].path } }
    }

    /// Contact notes without an `c2mdsync.id` (markdown-only candidates).
    public var unlinkedContacts: [VaultEntry] { contacts.filter { $0.syncID == nil } }

    /// Files whose contact frontmatter could not be read.
    public var problems: [VaultEntry] { entries.filter { $0.problem != nil } }

    /// `true` when any file anywhere has this stem (case-insensitive). mbr
    /// resolves links by stem globally, so new names avoid every folder.
    public func isStemTaken(_ stem: String) -> Bool { stems.contains(stem.lowercased()) }

    /// `true` when any note answers to `name` by title or alias (name key).
    public func hasTitle(_ name: String) -> Bool { titleKeys.contains(ComparisonKeys.name(name)) }

    /// Organization notes' titles (name keys), for `company:` wikilinks.
    public var organizationTitleKeys: Set<String> {
        Set(contacts.filter { $0.contact?.kind == .organization }.map { ComparisonKeys.name($0.title) })
    }
}
