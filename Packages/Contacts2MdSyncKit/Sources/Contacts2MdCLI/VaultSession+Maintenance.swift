public import Foundation
internal import SyncEngine

// Device-state maintenance (docs/ui.md §9 Advanced; `contacts2md rescan`,
// `contacts2md reset-state`). Both touch only this Mac's state for the vault,
// never the vault's files or the decision log, and both take the local run
// lock first so they never interleave with a sync on this Mac.

/// Another run on this Mac holds the local lock; nothing was changed.
public struct MaintenanceBlocked: Error, CustomStringConvertible {
    public var description: String {
        "another sync on this Mac is running; nothing was changed. Try again when it finishes"
    }
}

/// What Rescan Everything cleared.
public struct RescanOutcome: Hashable, Sendable {
    /// File-cache entries forgotten (every note is read again).
    public var cachedFiles: Int
    /// A cached Apple mirror was dropped (the next run takes a full snapshot).
    public var appleMirror: Bool
}

/// What Reset Sync State did.
public struct StateResetOutcome: Hashable, Sendable {
    /// The copy of the state database taken first.
    public var backup: URL
    /// Records (note ↔ contact bindings with their merge bases) forgotten.
    public var records: Int
    /// Review items forgotten (found again by the next run).
    public var pendingReview: Int
}

extension VaultSession {
    /// Metadata kept by a reset: history, not sync state.
    static let historyMetadataKeys: Set<String> = [UISessionDetail.metadataKey]

    /// This Mac's state for the vault, opened under the local run lock.
    private struct LockedState {
        var state: any SyncStateStore
        var directory: URL
        var lock: LocalLock
    }

    private func lockedState() throws -> LockedState {
        let fs = environment.makeVault(root)
        let directory = try configured(fs).directory
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw VaultNotReady(description: "this Mac has not synced this folder yet; nothing to clear")
        }
        guard
            let lock = try LocalLock.acquire(
                at: directory.appending(path: "sync.lock"), wait: environment.lockWait, sleep: environment.sleep)
        else { throw MaintenanceBlocked() }
        do {
            return LockedState(state: try environment.makeStateStore(directory), directory: directory, lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    /// Rescan Everything: forgets the file cache, cached image hashes and
    /// the Apple mirror (with its history token), so the next run re-reads
    /// every note and takes a full Contacts snapshot. Records, merge bases,
    /// the review queue and the decision log stay; nothing is written to the
    /// vault or to Contacts.
    @discardableResult
    public func rescanEverything() throws -> RescanOutcome {
        let locked = try lockedState()
        defer { locked.lock.release() }
        let state = locked.state
        let outcome = RescanOutcome(
            cachedFiles: try state.loadFileCache().count,
            appleMirror: try state.metadata(AppleChangeTracker.cacheKey) != nil)
        try state.clearCaches()
        return outcome
    }

    /// Reset Sync State: copies `state.sqlite` to
    /// `backups/state-<time>.sqlite` (last 10 kept; no copy, no reset), then
    /// forgets this Mac's records, merge bases, caches, review queue, groups
    /// and unapplyable writes. Activity history and the decision log (in the
    /// vault) stay, and no file in the vault is touched.
    ///
    /// The next run is this Mac's first export again and binds like a device
    /// joining the vault (architecture §11 "Identity when a device joins"):
    /// by stamp when `stamp_contacts` is on, else orphaned notes are re-found
    /// by strong keys at ≥ 0.9 or held for review by the orphan title gate.
    /// Nothing is duplicated.
    @discardableResult
    public func resetSyncState() throws -> StateResetOutcome {
        let locked = try lockedState()
        defer { locked.lock.release() }
        let state = locked.state
        let backups = locked.directory.appending(path: "backups")
        let backup = try Self.stateBackupURL(in: backups, now: environment.clock.now)
        try state.backup(to: backup)
        Self.pruneStateBackups(in: backups, keep: 10)
        let outcome = StateResetOutcome(
            backup: backup, records: try state.load().records.count,
            pendingReview: try state.loadPending().items.count)
        try state.resetSyncState(keepingMetadata: Self.historyMetadataKeys)
        return outcome
    }

    static func stateBackupURL(in folder: URL, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stem = "state-\(formatter.string(from: now))"
        var url = folder.appending(path: "\(stem).sqlite")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: "\(stem)-\(suffix).sqlite")
            suffix += 1
        }
        return url
    }

    static func pruneStateBackups(in folder: URL, keep: Int) {
        let old = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in old.dropFirst(keep) { try? FileManager.default.removeItem(at: stale) }
    }
}

extension UIVaultReader {
    /// Settings ▸ Advanced ▸ Rescan Everything (`VaultSession.rescanEverything`).
    @discardableResult
    public func rescanEverything() throws -> RescanOutcome {
        try VaultSession(root: root, environment: environment).rescanEverything()
    }

    /// Settings ▸ Advanced ▸ Reset Sync State (`VaultSession.resetSyncState`):
    /// backup first; the next Sync Now is this Mac's first export again.
    @discardableResult
    public func resetSyncState() throws -> StateResetOutcome {
        try VaultSession(root: root, environment: environment).resetSyncState()
    }
}
