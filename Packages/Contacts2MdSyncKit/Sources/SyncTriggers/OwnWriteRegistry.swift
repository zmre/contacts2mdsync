public import Foundation
public import SyncEngine
internal import Synchronization
internal import VaultIndex

/// Files the sync itself just wrote, so their FSEvents do not trigger
/// another run (architecture §10: own writes remembered as (path, sha) for
/// 30 s). Fed by the runner after each run; read by `VaultChangeSource`.
///
/// An event is ours only while the file still has the bytes we wrote (or is
/// still gone, for notes we moved to the Trash): an edit made right after
/// our write has a different hash and does trigger a run.
public final class OwnWriteRegistry: Sendable {
    /// How long a write is remembered.
    public let window: TimeInterval
    private let entries = Mutex<[String: Entry]>([:])

    struct Entry {
        /// sha256 of the written bytes; `nil` for a file we removed.
        var sha256: String?
        var recordedAt: Date
    }

    /// Creates a registry (`window` defaults to 30 s).
    public init(window: TimeInterval = 30) { self.window = window }

    /// Remembers that we wrote `sha256` (or removed the file, `nil`) at `path`
    /// (root-relative).
    public func record(path: String, sha256: String?, at date: Date) {
        entries.withLock { $0[path] = Entry(sha256: sha256, recordedAt: date) }
    }

    /// Remembers every vault file a sync run wrote or trashed.
    public func record(_ result: SyncResult, at date: Date) {
        for (path, entry) in result.markdown.writtenCache { record(path: path, sha256: entry.sha256, at: date) }
        for image in result.markdown.imagesWritten {
            record(path: image.path, sha256: FileStamp.hash(image.data), at: date)
        }
        for item in result.trashed { record(path: item.path, sha256: nil, at: date) }
    }

    /// `true` when the event for `path` is our own write: recorded less than
    /// `window` ago, and the file still holds what we wrote (`currentSHA`,
    /// `nil` when the file is gone).
    public func isOwnWrite(path: String, currentSHA: String?, at now: Date) -> Bool {
        entries.withLock { entries in
            entries = entries.filter { now.timeIntervalSince($0.value.recordedAt) < window }
            guard let entry = entries[path] else { return false }
            return entry.sha256 == currentSHA
        }
    }

    /// Paths currently remembered (tests, diagnostics).
    public func paths(at now: Date) -> [String] {
        entries.withLock { entries in
            entries.filter { now.timeIntervalSince($0.value.recordedAt) < window }.keys.sorted()
        }
    }
}
