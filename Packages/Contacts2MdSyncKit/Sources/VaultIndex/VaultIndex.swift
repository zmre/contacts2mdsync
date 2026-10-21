public import ContactModel
public import Foundation
public import MarkdownCodec

/// One markdown file in the vault.
public struct VaultEntry: Sendable {
    /// Root-relative path.
    public var path: String
    /// Stamp at scan time (compare-and-swap token for updates); `nil` when unread.
    public var stamp: FileStamp?
    /// The parse, when the file was read and its frontmatter valid.
    public var note: ParsedNote?
    /// Why the file could not be parsed (invalid YAML, not UTF-8, …).
    public var problem: String?
    /// iCloud placeholder whose bytes are not on this Mac (never read, never
    /// treated as deleted).
    public var isDataless: Bool
    /// Facts from the file cache, for files that were not read this scan
    /// (unchanged non-contact notes, unchanged problem files, dataless files).
    public var cached: FileCacheEntry?

    /// Creates an entry.
    public init(
        path: String, stamp: FileStamp? = nil, note: ParsedNote? = nil, problem: String? = nil,
        isDataless: Bool = false, cached: FileCacheEntry? = nil
    ) {
        self.path = path
        self.stamp = stamp
        self.note = note
        self.problem = problem
        self.isDataless = isDataless
        self.cached = cached
    }

    /// The contact, for `type: person|organization` notes that were read.
    public var contact: CanonicalContact? { note?.contact }
    /// `c2mdsync.id` of a contact note (from the cache for dataless notes).
    public var syncID: UUID? {
        if let note { return note.contact?.sync.id }
        return cached?.kind == .contact ? cached?.syncID : nil
    }
    /// `true` for contact notes, read or (dataless) known from the cache.
    public var isContactNote: Bool { contact != nil || (note == nil && cached?.kind == .contact) }
    /// Filename stem.
    public var stem: String { VaultPath.stem(of: path) }
    /// mbr's title for matching: frontmatter `title`, else the filename stem.
    public var title: String { note?.title ?? cached?.title ?? stem }
    /// `aliases` names.
    public var aliasNames: [String] { note?.aliasNames ?? cached?.aliases ?? [] }
    /// SHA-256 of the bytes as last read (this scan or the cache).
    public var sha256: String? { stamp?.sha256 ?? cached?.sha256 }
    /// A dataless file this device has never read: its content is unknown.
    public var isUnknownDataless: Bool { isDataless && cached == nil }
    /// A problem file that looks like a contact note.
    public var problemIsContactRelated: Bool {
        problem != nil && (cached?.contactRelated ?? false)
    }
}

/// What the engine knows about the notes folder after one scan
/// (architecture §2 `VaultIndex`): every markdown file, its contact parse,
/// and lookups by `c2mdsync.id`, title, alias and filename stem.
///
/// Identity is `c2mdsync.id`, never the path: a file moved to any subfolder is
/// still found by id.
public struct VaultIndex: Sendable {
    /// Version of the index format.
    public static let indexVersion = 2

    /// Every markdown file, sorted by path.
    public let entries: [VaultEntry]
    /// The file cache to persist for the next scan (scanned files only).
    public let fileCache: [String: FileCacheEntry]
    /// Files read and parsed this scan.
    public let filesRead: Int
    /// Files answered from the cache without reading.
    public let filesFromCache: Int
    private let byID: [UUID: [Int]]
    private let stems: [String: [Int]]
    private let titles: [String: [Int]]
    private let aliases: [String: [Int]]

    /// Builds an index from entries (sorted by path for determinism).
    public init(
        entries: [VaultEntry], fileCache: [String: FileCacheEntry] = [:], filesRead: Int = 0,
        filesFromCache: Int = 0
    ) {
        let sorted = entries.sorted { $0.path < $1.path }
        self.entries = sorted
        self.fileCache = fileCache
        self.filesRead = filesRead
        self.filesFromCache = filesFromCache
        var byID: [UUID: [Int]] = [:]
        var stems: [String: [Int]] = [:]
        var titles: [String: [Int]] = [:]
        var aliases: [String: [Int]] = [:]
        for (index, entry) in sorted.enumerated() {
            if let id = entry.syncID { byID[id, default: []].append(index) }
            stems[entry.stem.lowercased(), default: []].append(index)
            titles[ComparisonKeys.name(entry.title), default: []].append(index)
            for alias in Set(entry.aliasNames.map(ComparisonKeys.name)) { aliases[alias, default: []].append(index) }
        }
        self.byID = byID
        self.stems = stems
        self.titles = titles
        self.aliases = aliases
    }

    // MARK: - Scanning

    /// Scans the vault: all `.md`/`.markdown` files except under
    /// `excludedFolders` (the images folder) and paths matching
    /// `excludeGlobs` (`scope.markdown.exclude_paths`). Hidden paths
    /// (`.c2mdsync/`, dot files) are never enumerated.
    ///
    /// With a `cache` from the previous scan, unchanged non-contact and
    /// problem files are not re-read. Dataless files are never read; unknown
    /// ones are asked to download in the background.
    public static func scan(
        _ fs: any VaultFS, excludedFolders: [String] = [], excludeGlobs: [String] = [],
        cache: [String: FileCacheEntry] = [:]
    ) throws -> VaultIndex {
        let excluded = excludedFolders.filter { !$0.isEmpty }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let files = try fs.enumerate().filter { file in
            let lower = file.path.lowercased()
            return (lower.hasSuffix(".md") || lower.hasSuffix(".markdown"))
                && !excluded.contains { file.path.hasPrefix($0) }
                && !excludeGlobs.contains { PathGlob.matches($0, file.path) }
        }
        var newCache: [String: FileCacheEntry] = [:]
        var read = 0
        var fromCache = 0
        var entries: [VaultEntry] = []
        for file in files {
            let previous = cache[file.path]
            if file.isDataless {
                if previous == nil || previous?.kind == .contact { fs.requestDownload(file.path) }
                if let previous { newCache[file.path] = previous }
                entries.append(VaultEntry(path: file.path, isDataless: true, cached: previous))
                continue
            }
            if let previous, previous.kind != .contact, previous.matches(file) {
                fromCache += 1
                newCache[file.path] = previous
                entries.append(VaultEntry(path: file.path, problem: previous.problem, cached: previous))
                continue
            }
            read += 1
            let entry = readEntry(fs, file: file)
            if let cacheEntry = entry.cached { newCache[file.path] = cacheEntry }
            entries.append(entry)
        }
        return VaultIndex(entries: entries, fileCache: newCache, filesRead: read, filesFromCache: fromCache)
    }

    /// The cache entry for bytes just written to `path` (so a note evicted by
    /// iCloud right after an export is still known on the next scan).
    public static func cacheEntry(path: String, data: Data, stamp: FileStamp) -> FileCacheEntry? {
        guard let text = String(data: data, encoding: .utf8), let note = try? MarkdownCodec.parse(text) else {
            return nil
        }
        return FileCacheEntry(
            path: path, modificationDate: stamp.modificationDate, size: stamp.size, sha256: stamp.sha256,
            kind: note.contact == nil ? .other : .contact, syncID: note.contact?.sync.id, title: note.title,
            aliases: note.aliasNames)
    }

    private static func readEntry(_ fs: any VaultFS, file: FileEntry) -> VaultEntry {
        var entry = VaultEntry(path: file.path)
        let data: Data
        do {
            let (bytes, stamp) = try fs.read(file.path)
            data = bytes
            entry.stamp = stamp
        } catch {
            entry.problem = String(describing: error)
            return entry
        }
        let sha = entry.stamp?.sha256 ?? FileStamp.hash(data)
        let mtime = entry.stamp?.modificationDate ?? file.modificationDate
        guard let text = String(data: data, encoding: .utf8) else {
            entry.problem = "not valid UTF-8"
            entry.cached = FileCacheEntry(
                path: file.path, modificationDate: mtime, size: data.count, sha256: sha, kind: .problem,
                problem: entry.problem)
            return entry
        }
        do {
            let note = try MarkdownCodec.parse(text)
            entry.note = note
            entry.cached = FileCacheEntry(
                path: file.path, modificationDate: mtime, size: data.count, sha256: sha,
                kind: note.contact == nil ? .other : .contact, syncID: note.contact?.sync.id, title: note.title,
                aliases: note.aliasNames)
        } catch {
            entry.problem = String(describing: error)
            entry.cached = FileCacheEntry(
                path: file.path, modificationDate: mtime, size: data.count, sha256: sha, kind: .problem,
                problem: entry.problem, contactRelated: looksLikeContactNote(text))
        }
        return entry
    }

    /// Text heuristic for files whose frontmatter does not parse: a
    /// `type: person|organization` line or a `c2mdsync:` key.
    public static func looksLikeContactNote(_ text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline).prefix(200) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("c2mdsync:") { return true }
            guard trimmed.hasPrefix("type:") else { continue }
            let value = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if value.hasPrefix("person") || value.hasPrefix("organization") { return true }
        }
        return false
    }

    // MARK: - Lookups

    /// Contact notes that were read (`type: person|organization`).
    public var contacts: [VaultEntry] { entries.filter { $0.contact != nil } }

    /// Files with the given `c2mdsync.id` (more than one = copied file).
    public func entries(withID id: UUID) -> [VaultEntry] {
        (byID[id] ?? []).map { entries[$0] }
    }

    /// The entry at `path`, if scanned.
    public func entry(atPath path: String) -> VaultEntry? {
        guard let indices = stems[VaultPath.stem(of: path).lowercased()] else { return nil }
        return indices.lazy.map { entries[$0] }.first { $0.path == path }
    }

    /// `c2mdsync.id`s that appear in more than one file.
    public var duplicateIDs: [UUID: [String]] {
        byID.filter { $0.value.count > 1 }.mapValues { $0.map { entries[$0].path } }
    }

    /// Contact notes without an `c2mdsync.id` (markdown-only candidates).
    public var unlinkedContacts: [VaultEntry] { contacts.filter { $0.syncID == nil } }

    /// Files whose frontmatter could not be read.
    public var problems: [VaultEntry] { entries.filter { $0.problem != nil } }

    /// Dataless files this device has never read (content unknown).
    public var undownloaded: [VaultEntry] { entries.filter(\.isUnknownDataless) }

    /// `true` when any file anywhere has this stem (case-insensitive). mbr
    /// resolves links by stem globally, so new names avoid every folder.
    public func isStemTaken(_ stem: String) -> Bool { stems[stem.lowercased()] != nil }

    /// `true` when any note answers to `name` by title or alias (name key).
    public func hasTitle(_ name: String) -> Bool {
        let key = ComparisonKeys.name(name)
        return titles[key] != nil || aliases[key] != nil
    }

    /// The notes a `[[name]]` link resolves to, in mbr's order: frontmatter
    /// title, then alias, then filename stem (all case-insensitive). The first
    /// level with any hit wins; several hits there = ambiguous link.
    public func resolve(_ name: String) -> [VaultEntry] {
        let key = ComparisonKeys.name(name)
        for level in [titles[key], aliases[key], stems[name.lowercased()]] {
            if let hits = level, !hits.isEmpty { return hits.map { entries[$0] } }
        }
        return []
    }

    /// Contact notes sharing a title (name key) with another contact note:
    /// `[[Title]]` links to them are ambiguous. Keyed by title key.
    public var duplicateContactTitles: [String: [String]] {
        var byTitle: [String: [String]] = [:]
        for entry in entries where entry.isContactNote {
            byTitle[ComparisonKeys.name(entry.title), default: []].append(entry.path)
        }
        return byTitle.filter { $0.value.count > 1 }
    }

    /// Organization notes' titles (name keys), for `company:` wikilinks.
    public var organizationTitleKeys: Set<String> {
        Set(contacts.filter { $0.contact?.kind == .organization }.map { ComparisonKeys.name($0.title) })
    }
}
