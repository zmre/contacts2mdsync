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

    /// Creates an empty result.
    public init() {}
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

/// Applies Apple writes. Requires a `BackupReceipt`, which only
/// `VCardBackup.backup` can create, so no Apple write happens without a
/// fresh vCard backup of the whole address book (architecture §9).
public enum AppleWriter {
    /// Saves `batch` tagged with `author`.
    public static func apply(
        _ batch: AppleWriteBatch, in store: any ContactStore, backup: BackupReceipt, author: String
    ) throws -> AppleWriteResult {
        _ = backup  // The receipt's existence is the precondition.
        guard !batch.operations.isEmpty else { return AppleWriteResult(applied: []) }
        return try store.apply(batch, author: author)
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

        if plan.appleWritesAllowed, !plan.apple.isEmpty {
            let receipt = try backup()
            result.backup = receipt
            if let noteBackups { result.markdown.noteBackup = try backupNotes(plan, to: noteBackups) }
            let batch = AppleWriteBatch(operations: plan.apple.flatMap(\.operations))
            let write: AppleWriteResult
            do {
                write = try AppleWriter.apply(batch, in: store, backup: receipt, author: author)
            } catch {
                let message = String(describing: error)
                write = AppleWriteResult(
                    applied: [], failed: batch.operations.map { AppleWriteFailure(operation: $0, message: message) })
            }
            created = write.createdCardIDs
            let applied = Set(write.applied)
            for change in plan.apple {
                let failures = write.failed.filter { change.operations.contains($0.operation) }
                if failures.isEmpty, change.operations.allSatisfy(applied.contains) {
                    result.apple.append(change)
                    if change.kind == .delete { deletedRecords.insert(change.recordID) }
                } else {
                    result.appleFailures += failures.map { "\(change.title): \($0.message)" }
                }
                for operation in change.operations where applied.contains(operation) {
                    appliedUpdates.append((change.recordID, operation))
                }
            }
            // Token first: our own saves are older than it, so they are never
            // reported back as changes (they are excluded by author as well).
            result.postWriteHistoryToken = try? store.currentHistoryToken()
            postSnapshot = try store.snapshot()
            result.postWriteSnapshot = postSnapshot
        } else if let noteBackups {
            result.markdown.noteBackup = try backupNotes(plan, to: noteBackups)
        }

        let failedRecords = writeMarkdown(plan, created: created, result: &result)
        if let postSnapshot, let context = plan.context {
            result.newUnapplyable = verify(plan, applied: appliedUpdates, after: postSnapshot, context: context)
        }
        try saveState(
            plan, result: result,
            outcome: Outcome(
                created: created, snapshot: postSnapshot, failedRecords: failedRecords, deleted: deletedRecords))
        return result
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

    // MARK: - Verification (unapplyable)

    /// Re-reads every written card and records the writes it did not keep.
    private func verify(
        _ plan: SyncPlan, applied: [(record: UUID, operation: AppleWriteOperation)], after snapshot: AppleSnapshot,
        context: SyncContext
    ) -> [UnapplyableEntry] {
        let byCard = Self.contactsByCard(snapshot)
        let groupNames = Dictionary(snapshot.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var entries: [UnapplyableEntry] = []
        for (record, operation) in applied {
            switch operation {
            case .update(let cardID, let edits):
                guard let before = plan.records[record]?.apple,
                    let beforeCard = before.cards.first(where: { $0.id == cardID }),
                    let beforeValues = before.values(of: beforeCard), let after = byCard[cardID],
                    let afterCard = after.cards.first(where: { $0.id == cardID }),
                    let afterValues = after.values(of: afterCard)
                else { continue }
                entries += Verifier(builder: context.builder, record: record, card: cardID).check(
                    edits, before: beforeValues, after: afterValues)
            case .addMember(let cardID, let groupID):
                guard let after = byCard[cardID], !after.groupIDs.contains(groupID),
                    let name = groupNames[groupID], let tag = context.config.tag(forGroup: name)
                else { continue }
                entries.append(
                    UnapplyableEntry(
                        recordID: record, cardID: "*", field: "tags|\(ComparisonKeys.tag(tag))", attempted: "+",
                        observed: "absent"))
            default:
                continue
            }
        }
        return entries
    }

    static func contactsByCard(_ snapshot: AppleSnapshot) -> [String: AppleContact] {
        var byCard: [String: AppleContact] = [:]
        for contact in snapshot.contacts {
            for card in contact.cards { byCard[card.id] = contact }
        }
        return byCard
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
        try state.saveUnapplyable(unapplyable)
        try state.saveVanished(plan.vanished)
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
            aliases: index.aliases(record: record.recordID), notesSynced: builder.notesAvailable
        ).build()
    }
}

/// Compares a card after a save with the edits sent to it.
private struct Verifier {
    let builder: ViewBuilder
    let record: UUID
    let card: String

    private func entry(_ field: String, _ attempted: String, _ observed: String) -> UnapplyableEntry {
        UnapplyableEntry(recordID: record, cardID: card, field: field, attempted: attempted, observed: observed)
    }

    func check(_ edits: [CardEdit], before: CanonicalContact, after: CanonicalContact) -> [UnapplyableEntry] {
        edits.flatMap { edit -> [UnapplyableEntry] in
            switch edit {
            case .scalar(let apple, let value):
                guard let field = ScalarField.allCases.first(where: { $0.apple == apple }) else { return [] }
                let got = ScalarField.key(field.value(in: after))
                return scalar(field.rawValue, wanted: ScalarField.key(value), got: got)
            case .birthday(let date):
                return scalar(
                    ScalarField.birthday.rawValue, wanted: date?.iso, got: ScalarField.birthday.value(in: after))
            case .note(let text):
                return ComparisonKeys.body(text) == ComparisonKeys.body(after.body)
                    ? [] : [entry("body", "text", "different")]
            case .image:
                return []  // the image may come back as a thumbnail only (spike S5): never "refused"
            case .list(let appleField, let elements):
                guard let field = ListField.allCases.first(where: { $0.apple == appleField }) else { return [] }
                return list(field, elements, before: before, after: after)
            }
        }
    }

    private func scalar(_ field: String, wanted: String?, got: String?) -> [UnapplyableEntry] {
        wanted == got ? [] : [entry(field, wanted ?? "∅", got ?? "∅")]
    }

    /// Additions missing, replacements missing, relabels not kept, removals still present.
    private func list(
        _ field: ListField, _ elements: [AppleListElement], before: CanonicalContact, after: CanonicalContact
    ) -> [UnapplyableEntry] {
        let beforeKeys = Set(builder.apple(before, tags: [], image: .none).list(field).map(\.key))
        let afterLabels = Dictionary(
            builder.apple(after, tags: [], image: .none).list(field).map { ($0.key, $0.label) },
            uniquingKeysWith: { first, _ in first })
        let name = field.rawValue
        var entries: [UnapplyableEntry] = []
        var kept = Set<String>()
        for element in elements {
            let key = builder.key(of: element.value, label: element.label, field: field)
            guard let existing = element.existing else {
                if afterLabels[key] == nil { entries.append(entry("\(name)|\(key)", "+", "absent")) }
                continue
            }
            let old = builder.key(of: existing, label: element.existingLabel, field: field)
            kept.insert(old)
            if old != key {
                if afterLabels[key] == nil { entries.append(entry("\(name)|\(old)", "~\(key)", "absent")) }
            } else if element.label != element.existingLabel, let label = afterLabels[key], label != element.label {
                entries.append(entry("\(name)|\(key)", "@\(element.label ?? "")", "@\(label ?? "")"))
            }
        }
        for key in beforeKeys.subtracting(kept) where afterLabels[key] != nil {
            entries.append(entry("\(name)|\(key)", "-", "present"))
        }
        return entries
    }
}
