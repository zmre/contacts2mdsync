public import ContactModel
public import Foundation
internal import MarkdownCodec
public import VaultIndex

/// Plans a two-way sync (architecture §5–§9): the M2 identity phases
/// (stamp, cached card ids, adoption, clusters, decisions), then per record a
/// three-way merge of the Apple side and the note against this device's
/// merge base, delete detection, opted-in creates, scope, and the safety
/// verdicts (gating, blast radius, mass-vanish breaker). Pure apart from
/// reading notes' image files; writes nothing.
public struct SyncPlanner: Sendable {
    public let fs: any VaultFS
    public let keyer: any PhoneKeyer
    public let ids: any IDGenerator
    public let options: SyncOptions

    /// Creates a planner.
    public init(fs: any VaultFS, keyer: any PhoneKeyer, ids: any IDGenerator, options: SyncOptions = SyncOptions()) {
        self.fs = fs
        self.keyer = keyer
        self.ids = ids
        self.options = options
    }

    /// Plans one sync run.
    public func plan(_ inputs: SyncInputs) throws -> SyncPlan {
        let planner = ExportPlanner(fs: fs, keyer: keyer, ids: ids, options: options.export)
        var run = PlanningRun(planner: planner, inputs: inputs.export)
        run.sync = SyncRun(options: options, inputs: inputs)
        run.reportVaultProblems()
        run.resolveIdentities()
        run.applyUnavailableAccounts()
        run.applyMergeDecisions()
        run.blockDetached()
        run.applyExclusions()
        run.applyUnlinks()
        run.applyScope()
        run.limitClustersToOneNote()
        run.matchUnboundContacts()
        run.planAppleDeletes()
        run.planContactCreates()
        run.chooseNotes()
        run.updateGroups()
        run.buildSyncNotes()
        return run.finishSync()
    }
}

/// Two-way state carried through a planning run.
struct SyncRun {
    let options: SyncOptions
    let inputs: SyncInputs
    var unapplyable: UnapplyableIndex
    var appleChanges: [AppleRecordChange] = []
    var trash: [NoteTrash] = []
    var removed = Set<UUID>()
    var conflicts: [SyncConflict] = []
    var vanished: [UUID: Date] = [:]
    /// The breaker (§9): notes of contacts newly gone; last paths of notes newly missing.
    var newlyVanishedApple: [String] = []
    var newlyMissingNotes: [String] = []
    /// Records whose note is missing this run (decided or not).
    var missingNotes = Set<UUID>()
    var awaiting: [String] = []
    var blocked: [String] = []
    var newUnapplyable: [UnapplyableEntry] = []
    var states: [UUID: RecordSyncState] = [:]
    var renames: [UUID: MarkdownMaterializer.Rename] = [:]
    var context: SyncContext?
    /// Image hashes used this run (cached or computed).
    var imageHashes: [String: ImageHashEntry] = [:]
    /// Bodies merged without a notes base.
    var notesBaseline = NotesBaseline()
    /// Unavailable accounts (frozen records, held changes, forget preview).
    var accounts = AccountPlanning()

    init(options: SyncOptions, inputs: SyncInputs) {
        self.options = options
        self.inputs = inputs
        self.unapplyable = UnapplyableIndex(inputs.unapplyable)
    }
}

extension PlanningRun {
    var isSync: Bool { sync != nil }

    var groupNames: [String: String] {
        Dictionary(inputs.snapshot.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func appleTags(_ contact: AppleContact) -> [String] {
        let names = groupNames
        return contact.groupIDs.compactMap { names[$0] }.compactMap(plan.config.tag(forGroup:))
    }

    // MARK: Detached notes

    /// Contacts of detached notes are not synced (scope left, delete kept).
    mutating func blockDetached() {
        for contact in contacts {
            guard let id = boundIDs[contact.unifiedID], detachedIDs.contains(id) else { continue }
            blocked.insert(contact.unifiedID)
            skip(contact, "its note is detached (c2mdsync.status: detached)", needsReview: false)
        }
    }

    // MARK: Scope (architecture §12)

    mutating func applyScope() {
        guard isSync, !plan.config.scope.isUnrestricted else { return }
        for contact in contacts where !blocked.contains(contact.unifiedID) && !isInScope(contact) {
            blocked.insert(contact.unifiedID)
            if let id = boundIDs[contact.unifiedID], let entry = note(of: id), records[id] != nil,
                plan.config.scope.onLeaveScope == "detach"
            {
                detach(entry, id: id, reason: "left the sync scope")
            } else {
                skip(contact, "outside the sync scope", needsReview: false)
            }
        }
    }

    private func isInScope(_ contact: AppleContact) -> Bool {
        let names = groupNames
        let groups = contact.groupIDs.compactMap { names[$0] }
        let id = boundIDs[contact.unifiedID]
        let entry = id.flatMap(note(of:))
        return plan.config.scope.contains(
            id: id, contact: contact, groupNames: groups, path: entry?.path,
            tags: entry?.contact?.tags ?? appleTags(contact))
    }

    /// Marks the note `c2mdsync.status: detached` and forgets the record.
    mutating func detach(_ entry: VaultEntry, id: UUID, reason: String) {
        sync?.removed.insert(id)
        guard let parsed = entry.note, var contact = entry.contact, let stamp = entry.stamp, !entry.isDataless else {
            return
        }
        contact.sync.status = SyncMetadata.detached
        do {
            let data = Data(try MarkdownCodec.encode(contact, patching: parsed).utf8)
            plan.updates.append(
                FileChange(
                    path: entry.path, recordID: id, title: entry.title, data: data, expecting: .unchanged(stamp),
                    changedFields: ["c2mdsync"], kind: .detach, detail: reason))
        } catch {
            plan.skipped.append(SkippedContact(title: entry.title, reason: String(describing: error)))
        }
    }

    // MARK: Deleted in Contacts (architecture §9)

    /// A record no contact points at any more (no stamp, no card id, no
    /// re-match ≥ 0.5) whose note is still here: missing in two full
    /// snapshots at least `deleteConfirmInterval` apart → queued.
    ///
    /// An incremental run (a cached snapshot patched from change history)
    /// never concludes anything here: it keeps the records already seen
    /// missing as they are, records no new ones, confirms nothing, and adds
    /// nothing to the mass-vanish count. Only full snapshots do.
    mutating func planAppleDeletes() {
        guard let sync else { return }
        let bound = Set(boundIDs.values)
        let now = inputs.now
        for (id, _) in records.records.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard !bound.contains(id), !claimedRecords.contains(id), !pausedIDs.contains(id),
                !detachedIDs.contains(id), !sync.removed.contains(id)
            else { continue }
            guard sync.inputs.appleSnapshotComplete else {
                if let first = sync.inputs.vanished[id] { self.sync?.vanished[id] = first }
                continue
            }
            guard let entry = note(of: id) else {
                self.sync?.removed.insert(id)  // both sides gone: nothing left to sync
                continue
            }
            guard !entry.isDataless, entry.contact != nil, !proposedPaths.contains(entry.path) else { continue }
            // Not a mass vanish: forgotten accounts (the user's word), decided or known records.
            let forgotten = sync.inputs.accounts.forgottenRecords.contains(id)
            let first = sync.inputs.vanished[id]
            if first == nil, !forgotten, decisions.appleDeleteChoice(for: id) == nil {
                self.sync?.newlyVanishedApple.append(entry.path)
            }
            let since = forgotten ? Date.distantPast : first ?? now
            self.sync?.vanished[id] = since
            guard now.timeIntervalSince(since) >= sync.options.deleteConfirmInterval else {
                self.sync?.awaiting.append(entry.title)
                continue
            }
            confirmedAppleDelete(entry, id: id)
        }
    }

    /// A confirmed deletion: queued, or acted on per the user's decision.
    private mutating func confirmedAppleDelete(_ entry: VaultEntry, id: UUID) {
        switch decisions.appleDeleteChoice(for: id) {
        case "trash"?:
            sync?.trash.append(NoteTrash(recordID: id, path: entry.path, title: entry.title))
            sync?.removed.insert(id)
        case "keep"?:
            detach(entry, id: id, reason: "deleted in Contacts; note kept")
        case "restore"?:
            planCreate(from: entry, recordID: id, detail: "restored")
        default:
            plan.reviews.append(.appleDeleted(id: id, title: entry.title, path: entry.path))
        }
    }

    // MARK: Note deleted (architecture §9)

    mutating func markdownDeleted(_ contact: AppleContact, id: UUID) {
        guard let sync else { return }
        self.sync?.missingNotes.insert(id)
        // Newly missing (§9): not known missing, not decided (a held
        // delete-contact stays bound with its note gone).
        let path = records[id]?.path ?? title(contact)
        if !sync.inputs.knownMissingNotes.contains(id), decisions.markdownDeleteChoice(for: id) == nil {
            self.sync?.newlyMissingNotes.append(path)
        }
        let title = title(contact)
        switch decisions.markdownDeleteChoice(for: id) {
        case "restore"?:
            if holdCreates {
                skip(contact, "note restore held back until iCloud finishes downloading notes", needsReview: false)
            } else {
                addNewNote(for: contact, id: id)
            }
        case "delete-contact"?:
            let writable = Set(sync.inputs.writableContainerIDs)
            let operations = contact.cards.filter { writable.contains($0.containerID) }.map {
                AppleWriteOperation.delete(cardID: $0.id)
            }
            self.sync?.appleChanges.append(
                AppleRecordChange(recordID: id, title: title, kind: .delete, operations: operations, fields: []))
            skip(contact, "contact deletion confirmed", needsReview: false)
        default:
            plan.reviews.append(
                .markdownDeleted(contact: ref(contact), id: id, title: title, lastPath: records[id]?.path))
            skip(contact, "note was deleted; contact kept until you decide")
        }
    }

    /// Contacts unlinked after their note was deleted: forget the record and
    /// remove the stamp (when there is one).
    mutating func applyUnlinks() {
        for contact in contacts where decisions.isUnlinked(contact) {
            blocked.insert(contact.unifiedID)
            skip(contact, "unlinked (decision)", needsReview: false)
            guard isSync, let id = boundIDs[contact.unifiedID] ?? contact.stampIDs.first else { continue }
            if records[id] != nil { sync?.removed.insert(id) }
            let operations = contact.cards.filter { $0.stampID != nil }.map {
                AppleWriteOperation.removeStamp(cardID: $0.id)
            }
            if !operations.isEmpty {
                let change = AppleRecordChange(
                    recordID: id, title: title(contact), kind: .unstamp, operations: operations, fields: [])
                sync?.appleChanges.append(change)
            }
        }
    }

    // MARK: Contacts created from notes (opt-in only)

    mutating func planContactCreates() {
        guard isSync else { return }
        let adopted = Set(adoptions.values.map(\.entry.path))
        for entry in index.contacts where entry.syncID == nil && decisions.wantsContact(forNoteAt: entry.path) {
            guard !adopted.contains(entry.path), !proposedPaths.contains(entry.path),
                !decisions.isIgnored(path: entry.path, syncID: nil)
            else { continue }
            planCreate(from: entry, recordID: planner.ids.next(), detail: "added")
        }
    }

    /// Creates an Apple contact from a note after the create gate (§6): any
    /// Apple contact matching it at ≥ 0.5 blocks creation (review instead).
    mutating func planCreate(from entry: VaultEntry, recordID: UUID, detail: String) {
        guard let sync, let note = entry.contact, let parsed = entry.note, let stamp = entry.stamp,
            passesCreateGate(entry, note: note)
        else { return }
        let containers = inputs.snapshot.containers.filter { sync.inputs.writableContainerIDs.contains($0.id) }
        guard let container = containers.first(where: { $0.kind == .iCloud }) ?? containers.first(where: \.isDefault)
        else {
            self.sync?.blocked.append("\(entry.path): no iCloud container to create the contact in")
            return
        }
        let builder = viewBuilder(resolver: RelationResolver())
        let image = markdownImage(note.image, notePath: entry.path)
        let view = builder.markdown(MarkdownCodec.normalize(note), image: image.state)
        let writer = writePlanner(builder)
        let new = NewAppleContact(
            recordID: recordID, containerID: container.id, kind: note.kind,
            edits: writer.edits(for: view, imageData: imageBytes(image.path)),
            stamp: plan.config.stampContacts ? recordID : nil,
            groupIDs: writer.groupIDs(for: view.tags, containerID: container.id))
        self.sync?.appleChanges.append(
            AppleRecordChange(
                recordID: recordID, title: entry.title, kind: .create, operations: [.create(new)], fields: [detail]))
        var linked = note
        linked.sync.id = recordID
        linked.sync.status = nil
        if note.sync.id != recordID || note.sync.status != nil {
            do {
                let data = Data(try MarkdownCodec.encode(linked, patching: parsed).utf8)
                var change = FileChange(
                    path: entry.path, recordID: recordID, title: entry.title, data: data,
                    expecting: .unchanged(stamp), changedFields: ["c2mdsync"], kind: .link, detail: detail)
                change.requiresCreatedContact = true
                plan.updates.append(change)
            } catch {
                plan.skipped.append(SkippedContact(title: entry.title, reason: String(describing: error)))
                return
            }
        }
        plan.bindings[recordID] = RecordBinding(unifiedID: nil, cards: [], path: entry.path)
        self.sync?.states[recordID] = RecordSyncState(
            recordID: recordID, cardIDs: [], stampID: new.stamp, plannedNote: MarkdownCodec.normalize(linked),
            existingNote: MarkdownCodec.normalize(note), markdownImage: image.state, plannedImage: image.state,
            previousBase: nil, apple: nil, title: entry.title)
    }

    /// §6 create gate: no Apple contact may match the note at ≥ 0.5
    /// (unless declared a different person); a match becomes a review item.
    private mutating func passesCreateGate(_ entry: VaultEntry, note: CanonicalContact) -> Bool {
        let profile = MatchProfile(note: entry, contact: note, keyer: planner.keyer)
        for contact in contacts where !decisions.isDistinct(contact, fromNoteAt: entry.path) {
            guard let score = MatchProfile(apple: values(contact), keyer: planner.keyer).score(against: profile),
                score.confidence >= MatchScore.gateThreshold
            else { continue }
            proposedPaths.insert(entry.path)
            plan.reviews.append(
                .possibleMatch(
                    contact: ref(contact), path: entry.path, confidence: score.confidence, reasons: score.reasons))
            return false
        }
        return true
    }

    // MARK: Helpers

    func viewBuilder(resolver: RelationResolver) -> ViewBuilder {
        ViewBuilder(
            keyer: planner.keyer, notesAvailable: inputs.snapshot.notesAvailable,
            managedTagKeys: plan.config.managedTagKeys, resolver: resolver)
    }

    func writePlanner(_ builder: ViewBuilder) -> AppleWritePlanner {
        AppleWritePlanner(
            builder: builder, writableContainers: Set(sync?.inputs.writableContainerIDs ?? []),
            groups: inputs.snapshot.groups, config: plan.config)
    }

    /// The image a note references: its hash and root-relative path;
    /// unknown for URLs, missing files and dataless (evicted) files, none
    /// without `image:`. Unchanged files reuse the cached hash.
    mutating func markdownImage(_ image: ImageRef?, notePath: String) -> (state: ImageState, path: String?) {
        guard let path = image?.path, !path.isEmpty else { return (.none, nil) }
        let folder = VaultPath.directory(of: notePath)
        guard !path.contains("://"), let resolved = VaultPath.resolve(path, fromDirectory: folder) else {
            return (.unknown, nil)
        }
        guard let files = sync?.inputs.files else {
            guard let (_, stamp) = try? planner.fs.read(resolved) else { return (.unknown, nil) }
            return (.hash(stamp.sha256), resolved)
        }
        guard let file = files[resolved], !file.isDataless else { return (.unknown, nil) }
        if let cached = sync?.inputs.imageHashes[resolved], cached.matches(file) {
            sync?.imageHashes[resolved] = cached
            return (.hash(cached.sha256), resolved)
        }
        guard let (_, stamp) = try? planner.fs.read(resolved) else { return (.unknown, nil) }
        sync?.imageHashes[resolved] = ImageHashEntry(
            modificationDate: file.modificationDate, size: file.size, sha256: stamp.sha256)
        return (.hash(stamp.sha256), resolved)
    }

    /// The bytes of a note's image (read only when they go to Apple).
    func imageBytes(_ path: String?) -> Data? {
        path.flatMap { try? planner.fs.read($0).0 }
    }
}

extension VaultPath {
    /// `relative` (`../_images/x.jpg`) from the folder `directory`, as a
    /// root-relative path; `nil` when it leaves the root.
    public static func resolve(_ relative: String, fromDirectory directory: String) -> String? {
        var parts = relative.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for component in relative.split(separator: "/").map(String.init) {
            switch component {
            case ".", "": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(component)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}
