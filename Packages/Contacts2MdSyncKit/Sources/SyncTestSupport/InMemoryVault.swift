public import Foundation
internal import Synchronization
public import VaultIndex

/// A `VaultFS` held in memory, with write accounting for idempotency tests.
///
/// Mirrors `LocalVaultFS` semantics: hidden (dot) paths are not enumerated
/// but can be read and written directly; writes honour `WriteExpectation`.
public final class InMemoryVault: VaultFS {
    private struct File {
        var data: Data
        var modificationDate: Date
    }

    private struct State {
        var files: [String: File] = [:]
        var writes: [String] = []
        var tick: TimeInterval = 0
    }

    private let state = Mutex(State())

    /// Creates a vault with `files` (path → UTF-8 text).
    public init(files: [String: String] = [:]) {
        for (path, text) in files { seed(path, Data(text.utf8)) }
    }

    /// Adds or replaces a file without counting it as a write.
    public func seed(_ path: String, _ data: Data) {
        state.withLock { state in
            state.tick += 1
            state.files[path] = File(data: data, modificationDate: Date(timeIntervalSinceReferenceDate: state.tick))
        }
    }

    /// Paths written through `write`, in order.
    public var writes: [String] { state.withLock { $0.writes } }

    /// Forgets recorded writes.
    public func resetWrites() { state.withLock { $0.writes = [] } }

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
        state.withLock { state in
            guard let file = state.files.removeValue(forKey: from) else { return }
            state.files[destination] = file
        }
    }

    /// Deletes a file.
    public func remove(_ path: String) { _ = state.withLock { $0.files.removeValue(forKey: path) } }

    // MARK: - VaultFS

    public func enumerate() throws -> [FileEntry] {
        state.withLock { state in
            state.files.filter { path, _ in !path.split(separator: "/").contains { $0.hasPrefix(".") } }
                .map { FileEntry(path: $0.key, modificationDate: $0.value.modificationDate, size: $0.value.data.count) }
        }
    }

    public func read(_ path: String) throws -> (Data, FileStamp) {
        try VaultPath.validate(path)
        return try state.withLock { state in
            guard let file = state.files[path] else { throw VaultFSError.notFound(path: path) }
            return (file.data, Self.stamp(file))
        }
    }

    public func write(_ data: Data, to path: String, expecting: WriteExpectation) throws -> FileStamp {
        try VaultPath.validate(path)
        return try state.withLock { state in
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
    }

    public func trash(_ path: String) throws {
        try state.withLock { state in
            guard state.files.removeValue(forKey: path) != nil else { throw VaultFSError.notFound(path: path) }
        }
    }

    public func exists(_ path: String) -> Bool { state.withLock { $0.files[path] != nil } }

    private static func stamp(_ file: File) -> FileStamp {
        FileStamp(modificationDate: file.modificationDate, size: file.data.count, sha256: FileStamp.hash(file.data))
    }
}
