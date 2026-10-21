public import ContactModel
public import Foundation
public import VaultIndex

/// What an executed export did.
public struct ExportResult: Sendable {
    public var created: [FileChange] = []
    public var updated: [FileChange] = []
    public var imagesWritten: [ImageWrite] = []
    public var configWritten = false
    /// Folder holding copies of every existing note before it was rewritten.
    public var noteBackup: URL?
    /// File-cache entries for the notes written (merge into the scan's cache).
    public var writtenCache: [String: FileCacheEntry] = [:]
    /// Files that could not be written (changed underneath us, I/O errors).
    public var failures: [(path: String, message: String)] = []

    /// Creates an empty result.
    public init() {}
}

/// Writes an `ExportPlan` to the vault and persists the record map.
///
/// Every note write is a compare-and-swap: new notes must not exist yet;
/// updated notes must still hash to what the planner read. A file edited
/// between plan and execute is reported, not overwritten. Identical bytes
/// were already filtered out by the planner, so unchanged notes are never
/// touched. Images are written before the notes that reference them.
public struct ExportExecutor: Sendable {
    public let fs: any VaultFS
    public let records: any RecordMapStore
    public let clock: any SyncClock
    /// When set, existing notes are copied here before being rewritten.
    public let noteBackups: NoteBackup?

    /// Creates an executor.
    public init(
        fs: any VaultFS, records: any RecordMapStore, clock: any SyncClock = SystemClock(),
        noteBackups: NoteBackup? = nil
    ) {
        self.fs = fs
        self.records = records
        self.clock = clock
        self.noteBackups = noteBackups
    }

    /// Executes `plan`. Never throws for per-file problems (see
    /// `ExportResult.failures`); throws only if the note backup or the
    /// record map cannot be saved (a failed backup writes nothing).
    public func execute(_ plan: ExportPlan) throws -> ExportResult {
        var result = ExportResult()
        var failedRecords = Set<UUID>()
        if let noteBackups, !plan.updates.isEmpty {
            result.noteBackup = try noteBackups.backup(plan.updates.map(\.path), from: fs)
        }

        for image in plan.images {
            do {
                _ = try fs.write(image.data, to: image.path, expecting: .any)
                result.imagesWritten.append(image)
            } catch {
                result.failures.append((image.path, String(describing: error)))
            }
        }
        if let text = plan.configText {
            do {
                _ = try fs.write(Data(text.utf8), to: VaultConfig.path, expecting: .any)
                result.configWritten = true
            } catch {
                result.failures.append((VaultConfig.path, String(describing: error)))
            }
        }
        for change in plan.creates + plan.updates {
            do {
                let stamp = try fs.write(change.data, to: change.path, expecting: change.expecting)
                result.writtenCache[change.path] = VaultIndex.cacheEntry(
                    path: change.path, data: change.data, stamp: stamp)
                if case .absent = change.expecting {
                    result.created.append(change)
                } else {
                    result.updated.append(change)
                }
            } catch {
                failedRecords.insert(change.recordID)
                result.failures.append((change.path, String(describing: error)))
            }
        }

        var map = try records.load()
        for (id, binding) in plan.bindings where !failedRecords.contains(id) { map[id] = binding }
        map.lastExport = clock.now
        try records.save(map)
        return result
    }
}

extension ExportResult {
    /// `cache` (from the scan) with the written notes' entries.
    public func fileCache(updating cache: [String: FileCacheEntry]) -> [String: FileCacheEntry] {
        cache.merging(writtenCache) { _, written in written }
    }
}

/// Copies of notes about to be rewritten (adoptions and updates), so a first
/// export over hand-written notes can be undone by hand:
/// `<directory>/notes-<timestamp>/<root-relative path>`, newest `keep` kept.
public struct NoteBackup: Sendable {
    public let directory: URL
    public let keep: Int
    public let clock: any SyncClock

    /// Creates a backup writer (default: keep the last 10).
    public init(directory: URL, keep: Int = 10, clock: any SyncClock = SystemClock()) {
        self.directory = directory
        self.keep = keep
        self.clock = clock
    }

    /// Copies `paths` from `fs`; returns the backup folder.
    public func backup(_ paths: [String], from fs: any VaultFS) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var folder = directory.appending(
            path: "notes-\(formatter.string(from: clock.now))", directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = directory.appending(path: "notes-\(formatter.string(from: clock.now))-\(suffix)")
            suffix += 1
        }
        for path in paths {
            let (data, _) = try fs.read(path)
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
        }
        let old = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("notes-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in old.dropFirst(keep) { try FileManager.default.removeItem(at: stale) }
        return folder
    }
}

/// Proof that a vCard backup was written. Only `VCardBackup` can create one,
/// so Apple writes cannot be issued without a backup first.
public struct BackupReceipt: Hashable, Sendable {
    /// The backup file.
    public let url: URL
    /// Its size in bytes.
    public let byteCount: Int

    fileprivate init(url: URL, byteCount: Int) {
        self.url = url
        self.byteCount = byteCount
    }
}

/// vCard backups of the whole address book before any Apple write session
/// (architecture §9): `<directory>/contacts-<timestamp>.vcf`, newest `keep` kept.
public struct VCardBackup: Sendable {
    public let directory: URL
    public let keep: Int
    public let clock: any SyncClock

    /// Errors creating a backup.
    public enum BackupError: Error, Hashable, Sendable, CustomStringConvertible {
        case empty

        public var description: String { "vCard backup came back empty; refusing to write to Contacts" }
    }

    /// Creates a backup writer (default: keep the last 10).
    public init(directory: URL, keep: Int = 10, clock: any SyncClock = SystemClock()) {
        self.directory = directory
        self.keep = keep
        self.clock = clock
    }

    /// Exports all contacts from `store`, writes them, prunes old backups.
    public func backup(_ store: any ContactStore) throws -> BackupReceipt {
        let data = try store.exportVCards()
        guard !data.isEmpty else { throw BackupError.empty }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var url = directory.appending(path: "contacts-\(formatter.string(from: clock.now)).vcf")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = directory.appending(path: "contacts-\(formatter.string(from: clock.now))-\(suffix).vcf")
            suffix += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        try prune()
        return BackupReceipt(url: url, byteCount: data.count)
    }

    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("contacts-") && $0.pathExtension == "vcf" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(keep) { try FileManager.default.removeItem(at: old) }
    }
}

/// Stamps Apple cards with their record id (`x-c2mdsync:<uuid>`, label `c2mdsync`).
///
/// The only Apple write in M1. Requires a `BackupReceipt`, i.e. a vCard
/// backup written in this session; callers additionally gate it behind an
/// explicit opt-in (`contacts2md export --stamp`), off by default.
public enum Stamper {
    /// Applies `requests` as one save, tagged with `author`.
    public static func stamp(
        _ requests: [StampRequest], in store: any ContactStore, backup: BackupReceipt, author: String
    ) throws -> AppleWriteResult {
        _ = backup  // The receipt's existence is the precondition.
        guard !requests.isEmpty else { return AppleWriteResult(applied: []) }
        let batch = AppleWriteBatch(operations: requests.map { .stamp(cardID: $0.cardID, id: $0.recordID) })
        return try store.apply(batch, author: author)
    }
}
