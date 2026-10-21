public import Foundation
internal import Synchronization
public import VaultIndex

/// iCloud conflict versions shared by every replica of a simulated vault
/// (resolving them on one device resolves them everywhere, as with iCloud).
public final class ConflictVersionStore: Sendable {
    private let versions = Mutex<[String: [FileConflictVersion]]>([:])
    private let resolutions = Mutex<[(path: String, kept: String?)]>([])

    /// Creates an empty store.
    public init() {}

    /// Adds an unresolved version of `path`.
    public func add(_ path: String, _ version: FileConflictVersion) {
        versions.withLock { $0[path, default: []].append(version) }
    }

    /// Unresolved versions of `path`.
    public func versions(of path: String) -> [FileConflictVersion] { versions.withLock { $0[path] ?? [] } }

    /// Paths with unresolved versions.
    public var paths: [String] { versions.withLock { $0.filter { !$0.value.isEmpty }.keys.sorted() } }

    /// Resolutions so far: path and the kept version's sha (`nil`: current kept).
    public var resolved: [(path: String, kept: String?)] { resolutions.withLock { $0 } }

    func clear(_ path: String, kept: String?) {
        versions.withLock { $0[path] = nil }
        resolutions.withLock { $0.append((path, kept)) }
    }
}

/// One change to a vault file, as seen by a replication observer.
public struct VaultFileChange: Hashable, Sendable {
    public var path: String
    /// New contents; `nil` when the file was deleted or trashed.
    public var data: Data?
}

/// A `VaultFS` held in memory, with write accounting for idempotency tests.
///
/// Mirrors `LocalVaultFS` semantics: hidden (dot) paths are not enumerated
/// but can be read and written directly; writes honour `WriteExpectation`.
/// Conflict versions (`addConflictVersion`) model iCloud's `NSFileVersion`;
/// `observeChanges` / `applyRemote` let `SimulatedICloud` replicate it.
public final class InMemoryVault: VaultFS {
    private struct File {
        var data: Data
        var modificationDate: Date
    }

    private struct State {
        var files: [String: File] = [:]
        var writes: [String] = []
        var reads: [String] = []
        var dataless = Set<String>()
        var downloadRequests: [String] = []
        var tick: TimeInterval = 0
    }

    private let state = Mutex(State())
    private let observer = Mutex<(@Sendable (VaultFileChange) -> Void)?>(nil)
    /// Unresolved conflict versions (shared between replicas of one simulated vault).
    public let conflictVersions: ConflictVersionStore

    /// Creates a vault with `files` (path → UTF-8 text).
    public init(files: [String: String] = [:], conflictVersions: ConflictVersionStore = ConflictVersionStore()) {
        self.conflictVersions = conflictVersions
        for (path, text) in files { seed(path, Data(text.utf8)) }
    }

    /// Adds or replaces a file without counting it as a write (a user edit;
    /// replicated like any other change).
    public func seed(_ path: String, _ data: Data) {
        state.withLock { state in
            state.tick += 1
            state.files[path] = File(data: data, modificationDate: Date(timeIntervalSinceReferenceDate: state.tick))
        }
        notify(path, data)
    }

    /// Calls `observer` after every local change (writes, user edits,
    /// trashes, moves), never for `applyRemote`.
    public func observeChanges(_ observer: @escaping @Sendable (VaultFileChange) -> Void) {
        self.observer.withLock { $0 = observer }
    }

    /// Applies a change that arrived from another device (not a write, not observed).
    public func applyRemote(_ change: VaultFileChange) {
        state.withLock { state in
            guard let data = change.data else {
                state.files[change.path] = nil
                return
            }
            guard state.files[change.path]?.data != data else { return }
            state.tick += 1
            state.files[change.path] = File(
                data: data, modificationDate: Date(timeIntervalSinceReferenceDate: state.tick))
        }
    }

    /// Adds an unresolved iCloud conflict version of `path` (another
    /// device's copy that lost to the current contents).
    public func addConflictVersion(_ path: String, _ data: Data, deviceName: String? = nil) {
        conflictVersions.add(path, FileConflictVersion(data: data, deviceName: deviceName))
    }

    private func notify(_ path: String, _ data: Data?) {
        observer.withLock { $0 }?(VaultFileChange(path: path, data: data))
    }

    /// Paths written through `write`, in order.
    public var writes: [String] { state.withLock { $0.writes } }

    /// Forgets recorded writes.
    public func resetWrites() { state.withLock { $0.writes = [] } }

    /// Paths read through `read`, in order (hidden paths excluded).
    public var reads: [String] {
        state.withLock { $0.reads.filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } } }
    }

    /// Forgets recorded reads.
    public func resetReads() { state.withLock { $0.reads = [] } }

    /// Marks a file as an iCloud placeholder (enumerated as dataless; reading
    /// it fails like an evicted file would without coordination).
    public func setDataless(_ path: String, _ dataless: Bool = true) {
        state.withLock { state in
            if dataless { state.dataless.insert(path) } else { state.dataless.remove(path) }
        }
    }

    /// Paths `requestDownload` was called for.
    public var downloadRequests: [String] { state.withLock { $0.downloadRequests } }

    /// All paths, sorted.
    public var paths: [String] { state.withLock { $0.files.keys.sorted() } }

    /// A file's text, if present.
    public func text(_ path: String) -> String? {
        state.withLock { $0.files[path].flatMap { String(data: $0.data, encoding: .utf8) } }
    }

    /// A file's bytes, if present.
    public func data(_ path: String) -> Data? { state.withLock { $0.files[path]?.data } }

    /// Moves a file (as a user would in Finder), keeping its bytes.
    public func move(_ from: String, to destination: String) {
        let moved = state.withLock { state -> Data? in
            guard let file = state.files.removeValue(forKey: from) else { return nil }
            state.files[destination] = file
            return file.data
        }
        guard let moved else { return }
        notify(from, nil)
        notify(destination, moved)
    }

    /// Deletes a file.
    public func remove(_ path: String) {
        guard state.withLock({ $0.files.removeValue(forKey: path) }) != nil else { return }
        notify(path, nil)
    }

    // MARK: - VaultFS

    public func enumerate() throws -> [FileEntry] {
        let conflicted = Set(conflictVersions.paths)
        return state.withLock { state in
            state.files.filter { path, _ in !path.split(separator: "/").contains { $0.hasPrefix(".") } }
                .map {
                    FileEntry(
                        path: $0.key, modificationDate: $0.value.modificationDate, size: $0.value.data.count,
                        isDataless: state.dataless.contains($0.key),
                        hasUnresolvedConflicts: conflicted.contains($0.key))
                }
        }
    }

    public func unresolvedConflictVersions(_ path: String) throws -> [FileConflictVersion] {
        guard exists(path) else { return [] }
        return conflictVersions.versions(of: path)
    }

    public func resolveConflictVersions(_ path: String, keeping chosen: FileConflictVersion?) throws {
        guard exists(path) else { throw VaultFSError.notFound(path: path) }
        if let chosen {
            guard let version = conflictVersions.versions(of: path).first(where: { $0.sha256 == chosen.sha256 }) else {
                throw VaultFSError.notFound(path: path)
            }
            _ = try write(version.data, to: path, expecting: .any)
        }
        conflictVersions.clear(path, kept: chosen?.sha256)
    }

    public func read(_ path: String) throws -> (Data, FileStamp) {
        try VaultPath.validate(path)
        return try state.withLock { state in
            guard let file = state.files[path], !state.dataless.contains(path) else {
                throw VaultFSError.notFound(path: path)
            }
            state.reads.append(path)
            return (file.data, Self.stamp(file))
        }
    }

    public func write(_ data: Data, to path: String, expecting: WriteExpectation) throws -> FileStamp {
        try VaultPath.validate(path)
        let stamp = try state.withLock { state in
            let current = state.files[path]
            switch expecting {
            case .absent where current != nil:
                throw VaultFSError.conflict(path: path)
            case .unchanged(let stamp) where current.map({ FileStamp.hash($0.data) }) != stamp.sha256:
                throw VaultFSError.conflict(path: path)
            default:
                break
            }
            state.tick += 1
            let file = File(data: data, modificationDate: Date(timeIntervalSinceReferenceDate: state.tick))
            state.files[path] = file
            state.writes.append(path)
            return Self.stamp(file)
        }
        notify(path, data)
        return stamp
    }

    public func trash(_ path: String) throws {
        try state.withLock { state in
            guard state.files.removeValue(forKey: path) != nil else { throw VaultFSError.notFound(path: path) }
        }
        notify(path, nil)
    }

    public func exists(_ path: String) -> Bool { state.withLock { $0.files[path] != nil } }

    public func list(_ directory: String) throws -> [String] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        return state.withLock { state in
            Set(
                state.files.keys.filter { $0.hasPrefix(prefix) }.compactMap {
                    $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
                }
            ).sorted()
        }
    }

    public func requestDownload(_ path: String) { state.withLock { $0.downloadRequests.append(path) } }

    private static func stamp(_ file: File) -> FileStamp {
        FileStamp(modificationDate: file.modificationDate, size: file.data.count, sha256: FileStamp.hash(file.data))
    }
}
