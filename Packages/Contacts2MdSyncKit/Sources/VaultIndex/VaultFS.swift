internal import CryptoKit
public import Foundation

/// The engine's only view of the notes folder (architecture §2 seams).
///
/// Paths are relative to the vault root, `/`-separated, never starting with
/// `/` (e.g. `Inbox/Jane Doe.md`). Implemented by `LocalVaultFS` (real disk)
/// and `SyncTestSupport.InMemoryVault`.
public protocol VaultFS: Sendable {
    /// Every regular file under the root, skipping hidden (dot) files and
    /// directories. Order is unspecified.
    func enumerate() throws -> [FileEntry]
    /// Contents and stamp of a file.
    func read(_ path: String) throws -> (Data, FileStamp)
    /// Writes atomically, creating parent folders, after checking `expecting`
    /// (compare-and-swap). Returns the new stamp.
    func write(_ data: Data, to path: String, expecting: WriteExpectation) throws -> FileStamp
    /// Moves a file to the Trash (M3 deletes).
    func trash(_ path: String) throws
    /// `true` when a file exists at `path`.
    func exists(_ path: String) -> Bool
    /// Names of the entries directly inside `directory` (root-relative, `""`
    /// for the root), including hidden ones, sorted. Empty when it does not exist.
    func list(_ directory: String) throws -> [String]
    /// Asks iCloud Drive to download a dataless file in the background.
    /// Never blocks; a no-op for file systems without placeholders.
    func requestDownload(_ path: String)
    /// iCloud conflict versions of `path` that nobody resolved yet
    /// (`NSFileVersion.unresolvedConflictVersionsOfItem`, architecture §11).
    /// Empty when there are none or the file system has no versions.
    func unresolvedConflictVersions(_ path: String) throws -> [FileConflictVersion]
    /// Resolves every unresolved conflict version of `path`: with `keeping`
    /// `nil` the current contents stay; otherwise that version's bytes
    /// become the current contents first. The other versions are marked
    /// resolved and removed. Throws `notFound` when `keeping` is no longer
    /// among the versions.
    func resolveConflictVersions(_ path: String, keeping: FileConflictVersion?) throws
}

extension VaultFS {
    /// Default: nothing to download.
    public func requestDownload(_ path: String) {}

    /// Default: no versions.
    public func unresolvedConflictVersions(_ path: String) throws -> [FileConflictVersion] { [] }

    /// Default: nothing to resolve.
    public func resolveConflictVersions(_ path: String, keeping: FileConflictVersion?) throws {}
}

/// An unresolved iCloud conflict version of a file: another device's copy
/// that iCloud did not pick as the current contents (`NSFileVersion`).
public struct FileConflictVersion: Hashable, Sendable {
    /// SHA-256 of the bytes, lowercase hex: the version's identity on every
    /// device (the decision log refers to versions by it).
    public var sha256: String
    public var data: Data
    public var modificationDate: Date?
    /// The computer that saved it (`localizedNameOfSavingComputer`), if known.
    public var deviceName: String?

    /// Creates a version.
    public init(data: Data, modificationDate: Date? = nil, deviceName: String? = nil) {
        self.sha256 = FileStamp.hash(data)
        self.data = data
        self.modificationDate = modificationDate
        self.deviceName = deviceName
    }
}

/// One enumerated file.
public struct FileEntry: Hashable, Sendable {
    /// Root-relative path.
    public var path: String
    public var modificationDate: Date
    public var size: Int
    /// iCloud placeholder whose bytes are not downloaded (never treated as deleted).
    public var isDataless: Bool
    /// iCloud reports unresolved conflict versions
    /// (`ubiquitousItemHasUnresolvedConflicts`); read them with
    /// `VaultFS.unresolvedConflictVersions`.
    public var hasUnresolvedConflicts: Bool

    /// Creates an entry.
    public init(
        path: String, modificationDate: Date, size: Int, isDataless: Bool = false, hasUnresolvedConflicts: Bool = false
    ) {
        self.path = path
        self.modificationDate = modificationDate
        self.size = size
        self.isDataless = isDataless
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
    }
}

/// What a file looked like when read: the compare-and-swap token.
public struct FileStamp: Hashable, Sendable {
    public var modificationDate: Date
    public var size: Int
    /// SHA-256 of the contents, lowercase hex.
    public var sha256: String

    /// Creates a stamp.
    public init(modificationDate: Date, size: Int, sha256: String) {
        self.modificationDate = modificationDate
        self.size = size
        self.sha256 = sha256
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Precondition for a write.
public enum WriteExpectation: Hashable, Sendable {
    /// Create only; fail if something is already there.
    case absent
    /// Replace only if the file's contents still hash to this stamp's `sha256`.
    case unchanged(FileStamp)
    /// Overwrite unconditionally (engine-owned sidecars such as images).
    case any
}

/// Vault file-system errors.
public enum VaultFSError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file changed (or appeared) since it was read; nothing was written.
    case conflict(path: String)
    case notFound(path: String)
    /// A path escaping the root or otherwise unusable.
    case invalidPath(String)

    public var description: String {
        switch self {
        case .conflict(let path): "\(path) changed on disk since it was read; not overwritten"
        case .notFound(let path): "\(path) not found"
        case .invalidPath(let path): "invalid vault path: \(path)"
        }
    }
}

/// Root-relative path helpers.
public enum VaultPath {
    /// Rejects absolute paths and `..` components.
    public static func validate(_ path: String) throws(VaultFSError) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.isEmpty || path.hasPrefix("/") || components.contains("..") || components.contains("") {
            throw .invalidPath(path)
        }
    }

    /// Folder part of `path` (`""` at the root).
    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// File name without extension.
    public static func stem(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// `target` relative to the folder `fromDirectory` (`../_images/x.jpg`).
    public static func relative(_ target: String, fromDirectory directory: String) -> String {
        let source = directory.split(separator: "/").map(String.init)
        let destination = target.split(separator: "/").map(String.init)
        var common = 0
        while common < source.count, common < destination.count - 1, source[common] == destination[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: source.count - common)
        return (ups + destination[common...]).joined(separator: "/")
    }

    /// Joins `directory` and `name`.
    public static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }
}
