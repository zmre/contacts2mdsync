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
}

/// One enumerated file.
public struct FileEntry: Hashable, Sendable {
    /// Root-relative path.
    public var path: String
    public var modificationDate: Date
    public var size: Int
    /// iCloud placeholder whose bytes are not downloaded (never treated as deleted).
    public var isDataless: Bool

    /// Creates an entry.
    public init(path: String, modificationDate: Date, size: Int, isDataless: Bool = false) {
        self.path = path
        self.modificationDate = modificationDate
        self.size = size
        self.isDataless = isDataless
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
