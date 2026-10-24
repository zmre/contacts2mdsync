public import ContactModel
public import Foundation
public import VaultIndex

/// What an executed sync did.
public struct SyncResult: Sendable {
    /// Markdown writes (notes, images, config) and their failures.
    public var markdown = ExportResult()
    public var trashed: [NoteTrash] = []
    /// Apple changes that were saved completely.
    public var apple: [AppleRecordChange] = []
    /// Apple operations that failed (`title: message`).
    public var appleFailures: [String] = []
    /// Apple changes not made because they wait for the user (Contacts.app
    /// scripting without Automation permission, architecture §6 "Write
    /// routing"): not failures, retried on the next run.
    public var appleHeld: [AppleHeldChange] = []
    /// The vCard backup taken before the Apple writes.
    public var backup: BackupReceipt?
    /// Writes cards did not keep (recorded, not retried).
    public var newUnapplyable: [UnapplyableEntry] = []
    /// Notes not linked because their contact was not created.
    public var skippedLinks: [String] = []
    /// The full snapshot re-read after the Apple writes, and the change-history
    /// token read just before it (the Apple mirror after a run that wrote).
    public var postWriteSnapshot: AppleSnapshot?
    public var postWriteHistoryToken: Data?
    /// Notes were synced this run (read, and re-read after Apple writes); their base was refreshed.
    public var notesSynced = false

    /// Creates an empty result.
    public init() {}
}

/// An Apple change held at write time, with the reason.
public struct AppleHeldChange: Hashable, Sendable {
    public var recordID: UUID
    public var title: String
    public var reason: String

    /// Creates a held change.
    public init(recordID: UUID, title: String, reason: String) {
        self.recordID = recordID
        self.title = title
        self.reason = reason
    }
}

/// Errors that stop a sync before anything is written.
public enum SyncError: Error, Hashable, Sendable, CustomStringConvertible {
    case breakerTripped(BreakerTrip)

    public var description: String {
        switch self {
        case .breakerTripped(let trip): trip.message
        }
    }
}

/// Executes a `SyncPlan` (architecture §5 "execute"): vCard backup → one
/// Apple batch (`transactionAuthor`) → re-fetch and verify each written card
/// → markdown writes (compare-and-swap) → merge bases refreshed from what
/// both sides agree on after the writes.
public struct SyncExecutor: Sendable {
    public let fs: any VaultFS
    public let store: any ContactStore
    public let state: any SyncStateStore
    public let clock: any SyncClock
    /// Existing notes are copied here before being rewritten or trashed.
    public let noteBackups: NoteBackup?
    /// `com.zmre.contacts2mdsync.<deviceID>`.
    public let author: String
    /// Measures `apple-write`, `reread`, `md-write` and `save-state` (`--verbose`).
    public var timer = PhaseTimer()

    /// Creates an executor.
    public init(
        fs: any VaultFS, store: any ContactStore, state: any SyncStateStore, clock: any SyncClock = SystemClock(),
        noteBackups: NoteBackup? = nil, author: String
    ) {
        self.fs = fs
        self.store = store
        self.state = state
        self.clock = clock
        self.noteBackups = noteBackups
        self.author = author
    }

    /// Executes `plan`. `backup` is called once, before the first Apple
    /// write; if it throws, nothing at all is written. Throws
    /// `SyncError.breakerTripped` for a plan whose breaker tripped.
    public func execute(_ plan: SyncPlan, backup: () throws -> BackupReceipt) throws -> SyncResult {
        if let trip = plan.breaker { throw SyncError.breakerTripped(trip) }
        var result = SyncResult()
        var created: [UUID: String] = [:]
        var postSnapshot: AppleSnapshot?
        var appliedUpdates: [(record: UUID, operation: AppleWriteOperation)] = []
        var deletedRecords = Set<UUID>()
        var skipped: [UnapplyableEntry] = []

        if plan.appleWritesAllowed, !plan.apple.isEmpty {
            let receipt = try backup()
            result.backup = receipt
            if let noteBackups { result.markdown.noteBackup = try backupNotes(plan, to: noteBackups) }
            let write = applyBatch(plan, receipt: receipt)
            created = write.createdCardIDs
            skipped = Self.unapplyable(write.skipped, plan: plan)
            (appliedUpdates, deletedRecords) = Self.record(write, of: plan, in: &result)
            // Token first: our own saves are older than it, so they are never
            // reported back as changes (they are excluded by author as well).
            result.postWriteHistoryToken = try? store.currentHistoryToken()
            result.postWriteSnapshot = try timer.measure("reread") { try store.snapshot() }
            // Unavailable accounts' cards back as last seen: the base keeps their values (§9).
            postSnapshot = result.postWriteSnapshot.map { plan.accountGuard.augment($0).snapshot }
        } else if let noteBackups {
            result.markdown.noteBackup = try backupNotes(plan, to: noteBackups)
        }

        let failedRecords = timer.measure("md-write") { writeMarkdown(plan, created: created, result: &result) }
        if let postSnapshot, let context = plan.context {
            result.newUnapplyable = verify(plan, applied: appliedUpdates, after: postSnapshot, context: context)
        }
        result.newUnapplyable += skipped.filter { !result.newUnapplyable.contains($0) }
        result.notesSynced = plan.notes.isActive && (postSnapshot?.notesAvailable ?? true)
        try timer.measure("save-state") {
            try saveState(
                plan, result: result,
                outcome: Outcome(
                    created: created, snapshot: postSnapshot, failedRecords: failedRecords, deleted: deletedRecords))
        }
        return result
    }

    /// Sorts each planned change into made, failed or held; returns the
    /// applied operations (for verification) and the deleted records.
    private static func record(
        _ write: AppleWriteResult, of plan: SyncPlan, in result: inout SyncResult
    ) -> ([(record: UUID, operation: AppleWriteOperation)], Set<UUID>) {
        let applied = Set(write.applied)
        var appliedUpdates: [(record: UUID, operation: AppleWriteOperation)] = []
        var deleted = Set<UUID>()
        for change in plan.apple {
            let failures = write.failed.filter { change.operations.contains($0.operation) }
            if failures.isEmpty, change.operations.allSatisfy(applied.contains) {
                result.apple.append(change)
                if change.kind == .delete { deleted.insert(change.recordID) }
            } else {
                result.appleFailures += failures.map { "\(change.title): \($0.message)" }
                if let hold = write.held.first(where: { change.operations.contains($0.operation) }) {
                    result.appleHeld.append(
                        AppleHeldChange(recordID: change.recordID, title: change.title, reason: hold.reason))
                }
            }
            for operation in change.operations where applied.contains(operation) {
                appliedUpdates.append((change.recordID, operation))
            }
        }
        return (appliedUpdates, deleted)
    }

    /// The one Apple batch; a thrown error fails every operation.
    private func applyBatch(_ plan: SyncPlan, receipt: BackupReceipt) -> AppleWriteResult {
        let batch = AppleWriteBatch(operations: plan.apple.flatMap(\.operations), cardNotes: Self.cardNotes(plan))
        do {
            return try timer.measure("apple-write") {
                try AppleWriter.apply(batch, in: store, backup: receipt, author: author)
            }
        } catch {
            let message = String(describing: error)
            return AppleWriteResult(
                applied: [], failed: batch.operations.map { AppleWriteFailure(operation: $0, message: message) })
        }
    }

    // MARK: - Markdown

    private func backupNotes(_ plan: SyncPlan, to backups: NoteBackup) throws -> URL? {
        let paths = plan.markdown.updates.map(\.path) + plan.trash.map(\.path)
        guard !paths.isEmpty else { return nil }
        return try backups.backup(paths.filter(fs.exists), from: fs)
    }

    /// Writes images, config, notes and trashes; returns records whose note failed.
    private func writeMarkdown(_ plan: SyncPlan, created: [UUID: String], result: inout SyncResult) -> Set<UUID> {
        var failed = Set<UUID>()
        result.markdown.resolveVersions(plan.markdown.versionResolutions, fs: fs)
        for image in plan.markdown.images {
            do {
                _ = try fs.write(image.data, to: image.path, expecting: .any)
                result.markdown.imagesWritten.append(image)
            } catch {
                result.markdown.failures.append((image.path, String(describing: error)))
            }
        }
        if let text = plan.markdown.configText {
            do {
                _ = try fs.write(Data(text.utf8), to: VaultConfig.path, expecting: .any)
                result.markdown.configWritten = true
            } catch {
                result.markdown.failures.append((VaultConfig.path, String(describing: error)))
            }
        }
        for change in plan.markdown.creates + plan.markdown.updates {
            if change.requiresCreatedContact, created[change.recordID] == nil {
                result.skippedLinks.append(change.path)
                failed.insert(change.recordID)
                continue
            }
            do {
                let stamp = try fs.write(change.data, to: change.path, expecting: change.expecting)
                result.markdown.writtenCache[change.path] = VaultIndex.cacheEntry(
                    path: change.path, data: change.data, stamp: stamp)
                if case .absent = change.expecting {
                    result.markdown.created.append(change)
                } else {
                    result.markdown.updated.append(change)
                }
            } catch {
                failed.insert(change.recordID)
                result.markdown.failures.append((change.path, String(describing: error)))
            }
        }
        for item in plan.trash {
            do {
                try fs.trash(item.path)
                result.trashed.append(item)
            } catch {
                failed.insert(item.recordID)
                result.markdown.failures.append((item.path, String(describing: error)))
            }
        }
        return failed
    }

    // MARK: - State

    /// What the Apple phase and the markdown writes produced.
    private struct Outcome {
        var created: [UUID: String] = [:]
        var snapshot: AppleSnapshot?
        var failedRecords = Set<UUID>()
        var deleted = Set<UUID>()
    }

    private func saveState(_ plan: SyncPlan, result: SyncResult, outcome: Outcome) throws {
        let (created, snapshot, failedRecords, deleted) = (
            outcome.created, outcome.snapshot, outcome.failedRecords, outcome.deleted
        )
        var map = try state.load()
        let byCard = snapshot.map(Self.contactsByCard) ?? [:]
        let byStamp = Dictionary(
            (snapshot?.contacts ?? []).flatMap { contact in contact.stampIDs.map { ($0, contact) } },
            uniquingKeysWith: { first, _ in first })
        let unapplyable = Self.merge(plan.unapplyableKept, result.newUnapplyable)
        let now = clock.now
        for (id, planned) in plan.markdown.bindings where !failedRecords.contains(id) {
            var binding = planned
            guard let record = plan.records[id], let context = plan.context else {
                map[id] = binding
                continue
            }
            var apple = record.apple
            if snapshot != nil {
                let located =
                    created[id].flatMap { byCard[$0] } ?? record.cardIDs.lazy.compactMap { byCard[$0] }.first
                    ?? byStamp[id]
                apple = located ?? apple
                // Notes not re-read after the writes: the body base stays as it was.
                if snapshot?.notesAvailable == false { apple?.notesUnknown = true }
            }
            guard let apple else { continue }  // a create that did not happen
            binding.unifiedID = apple.unifiedID
            let previous = Dictionary(binding.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            binding.cards = apple.cards.map { card in
                var bound =
                    previous[card.id]
                    ?? BoundCard(
                        id: card.id, containerID: card.containerID, accountKind: card.accountKind, firstSeen: now)
                bound.stampSeen = bound.stampSeen || card.stampID == id
                return bound
            }
            binding.base = Self.base(for: record, apple: apple, context: context, unapplyable: unapplyable)
            map[id] = binding
        }
        for id in plan.removedRecords.union(deleted) { map[id] = nil }
        map.lastExport = now
        try state.save(map)
        try state.saveGroups(after: plan, result: result)
        try state.saveUnapplyable(unapplyable)
        try state.saveVanished(plan.vanished)
        try plan.accountGuard.save(executed: true, in: state)
        try NotesSyncState.record(plan.notes, notesSynced: result.notesSynced, in: state)
    }

    /// Entries kept plus new ones (one per record, card and field; new wins).
    static func merge(_ kept: [UnapplyableEntry], _ new: [UnapplyableEntry]) -> [UnapplyableEntry] {
        var bySlot: [String: UnapplyableEntry] = [:]
        for entry in kept + new { bySlot["\(entry.recordID)|\(entry.slot)"] = entry }
        return bySlot.values.sorted { "\($0.recordID)|\($0.slot)" < "\($1.recordID)|\($1.slot)" }
    }

    static func base(
        for record: RecordSyncState, apple: AppleContact, context: SyncContext, unapplyable: [UnapplyableEntry]
    ) -> RecordBase {
        let builder = context.builder
        let values = apple.cardMergedContact(keyer: builder.keyer)
        let groupNames = Dictionary(context.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let tags = apple.groupIDs.compactMap { groupNames[$0] }.compactMap(context.config.tag(forGroup:))
        let image: ImageState =
            apple.imageUnavailable ? .unknown : apple.imageData.map { .hash(FileStamp.hash($0)) } ?? .none
        let appleView = builder.apple(values, tags: tags, image: image)
        let markdownView = builder.markdown(record.plannedNote, image: record.plannedImage)
        var index = UnapplyableIndex(unapplyable.filter { $0.recordID == record.recordID })
        return MergeBaseBuilder(
            apple: appleView, markdown: markdownView, appleValues: values, previous: record.previousBase,
            aliases: index.aliases(record: record.recordID),
            notesSynced: builder.notesAvailable && apple.notesUnknown != true
        ).build()
    }
}
