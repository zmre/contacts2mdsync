internal import ContactModel
internal import Foundation
internal import MarkdownCodec
internal import VaultIndex

/// One candidate's note as built this run.
struct BuiltNote {
    var candidate: PlanningRun.Candidate
    var note: CanonicalContact
    /// Two-way merged (an existing note), not projected (a new note).
    var merged: Bool
}

/// The record-independent tools of the build phase.
struct BuildTools {
    let resolver: RelationResolver
    let renamer: RelationRenamer
    let builder: ViewBuilder
    let nameResolver: NameResolver
    let materializer: MarkdownMaterializer
    let writer: AppleWritePlanner
    let projection: ExportProjection
}

/// Phase 8 of a sync run: merge each bound record, build its note and its
/// Apple writes; then the safety verdicts.
extension PlanningRun {
    mutating func buildSyncNotes() {
        guard isSync else { return }
        let tools = buildTools()
        var built = candidates.map { candidate in
            if let existing = candidate.existing, let note = existing.contact {
                return BuiltNote(candidate: candidate, note: mergeCandidate(candidate, note: note, tools), merged: true)
            }
            return BuiltNote(candidate: candidate, note: projectNew(candidate, tools), merged: false)
        }
        rewriteRenamedLinks(&built, resolver: tools.resolver)
        emit(built)
        let context = SyncContext(
            builder: tools.builder, config: plan.config, groups: inputs.snapshot.groups,
            writableContainerIDs: sync?.inputs.writableContainerIDs ?? [])
        sync?.context = context
    }

    private func buildTools() -> BuildTools {
        let resolver = relationResolver()
        let builder = viewBuilder(resolver: resolver)
        let nameResolver = NameResolver(
            candidates: candidates.map {
                NamedNote(contact: $0.apple, values: values($0.apple), title: $0.title, path: $0.path)
            },
            index: index)
        let config = plan.config
        let materializer = MarkdownMaterializer(
            resolver: resolver,
            company: { name, existing, kind in
                let probe = CanonicalContact(kind: kind, title: "", company: .plain(name))
                return nameResolver.company(for: probe, existing: existing) ?? .plain(name)
            },
            managedTagKeys: config.managedTagKeys,
            tagText: { key in config.groups.first { ComparisonKeys.tag($0.tag) == key }?.tag ?? key })
        return BuildTools(
            resolver: resolver, renamer: relationRenamer(resolver), builder: builder, nameResolver: nameResolver,
            materializer: materializer,
            writer: writePlanner(builder),
            projection: ExportProjection(keyer: planner.keyer, notesAvailable: inputs.snapshot.notesAvailable))
    }

    /// A new note for a contact (the one-way projection; no merge needed).
    private mutating func projectNew(_ candidate: Candidate, _ tools: BuildTools) -> CanonicalContact {
        let note = MarkdownCodec.normalize(
            tools.projection.project(exportInputs(for: candidate, resolver: tools.nameResolver)))
        let state = RecordSyncState(
            recordID: candidate.recordID, cardIDs: candidate.apple.cardIDs, stampID: candidate.apple.stampIDs.first,
            plannedNote: note, existingNote: nil, markdownImage: .none,
            plannedImage: candidate.apple.imageData.map { .hash(FileStamp.hash($0)) } ?? .none,
            previousBase: notesBase(records[candidate.recordID]?.base), apple: candidate.apple, title: note.title)
        sync?.states[candidate.recordID] = state
        return note
    }

    /// Encodes every built note and records its file change.
    private mutating func emit(_ built: [BuiltNote]) {
        var pathsByTitle: [String: Set<String>] = [:]
        for entry in index.entries where entry.isContactNote {
            pathsByTitle[ComparisonKeys.name(entry.title), default: []].insert(entry.path)
        }
        for item in built {
            pathsByTitle[ComparisonKeys.name(item.note.title), default: []].insert(item.candidate.path)
            do {
                let data = Data(try MarkdownCodec.encode(item.note, patching: item.candidate.existing?.note).utf8)
                sync?.states[item.candidate.recordID]?.plannedNote = MarkdownCodec.normalize(item.note)
                record(item.candidate, note: item.note, data: data, writeImage: !item.merged)
            } catch {
                plan.skipped.append(SkippedContact(title: item.note.title, reason: String(describing: error)))
                sync?.appleChanges.removeAll { $0.recordID == item.candidate.recordID }
            }
        }
        for paths in pathsByTitle.values where paths.count > 1 {
            plan.warnings.append(
                "duplicate title in \(paths.sorted().joined(separator: ", ")): [[links]] are ambiguous")
        }
        plan.warnings.sort()
        for move in plan.moves.sorted(by: { $0.newPath < $1.newPath }) {
            plan.notes.append("moved \(move.oldPath) → \(move.newPath)")
        }
    }

    /// Record ids by every name they answer to: note titles and aliases, and
    /// the Apple contacts' name variants (relation names are free text);
    /// then, at lower priority, the names they answered to before a rename
    /// (merge bases).
    private func relationResolver() -> RelationResolver {
        var resolver = RelationResolver()
        var known = Set<UUID>()
        func add(_ name: String, _ id: UUID) {
            resolver.add(name, record: id)
            known.insert(id)
        }
        for entry in index.contacts {
            guard let id = entry.syncID else { continue }
            add(entry.title, id)
            for alias in entry.aliasNames { add(alias, id) }
            resolver.setTitle(entry.title, for: id)
        }
        for candidate in candidates {
            let contactValues = values(candidate.apple)
            add(candidate.title, candidate.recordID)
            for variant in TitleGenerator.nameVariants(for: contactValues) { add(variant, candidate.recordID) }
            resolver.setTitle(candidate.title, for: candidate.recordID)
            resolver.setAppleName(
                TitleGenerator.personalName(contactValues.name) ?? TitleGenerator.title(for: contactValues),
                for: candidate.recordID)
        }
        for id in known {
            for key in records[id]?.base?.nameHistoryKeys ?? [] { resolver.addFormer(key: key, record: id) }
        }
        return resolver
    }

    /// Former names of records with a contact this run: what other cards'
    /// relations may still call them (§8 "Apple relation names on other
    /// cards"): the base's name keys that are not among the record's current
    /// Apple name variants. An old title kept as a plain alias still
    /// counts as stale here, so a relation using it follows the rename.
    private func relationRenamer(_ resolver: RelationResolver) -> RelationRenamer {
        var stale: [UUID: Set<String>] = [:]
        for candidate in candidates {
            guard let base = records[candidate.recordID]?.base else { continue }
            let contactValues = values(candidate.apple)
            // The note title is left out: it is markdown-owned and may still
            // be the old generated title this run regenerates.
            let names = TitleGenerator.nameVariants(for: contactValues) + [TitleGenerator.title(for: contactValues)]
            let appleNames = Set(names.map(ComparisonKeys.name))
            let old = Set(base.nameHistoryKeys).subtracting(appleNames)
            if !old.isEmpty { stale[candidate.recordID] = old }
        }
        return RelationRenamer(resolver: resolver, stale: stale)
    }

    /// Two-way merge of one bound record with an existing note.
    private mutating func mergeCandidate(
        _ candidate: Candidate, note: CanonicalContact, _ tools: BuildTools
    ) -> CanonicalContact {
        let id = candidate.recordID
        let contact = candidate.apple
        var existing = MarkdownCodec.normalize(note)
        existing.tags = renamingTags(existing.tags)
        let appleImage: ImageState =
            contact.imageUnavailable ? .unknown : contact.imageData.map { .hash(FileStamp.hash($0)) } ?? .none
        let noteImage = markdownImage(existing.image, notePath: candidate.path)
        let previous = notesBase(records[id]?.base)
        var base = BaseView.of(previous)
        base.tags = base.tags.map { Set(renamingTags(Array($0)).map(ComparisonKeys.tag)) }
        var appleView = tools.builder.apple(values(contact), tags: appleTags(contact), image: appleImage)
        // A card whose note could not be read: the body is unknown, not empty.
        if contact.notesUnknown == true { appleView.body = nil }
        let aliases = sync?.unapplyable.aliases(record: id) ?? [:]
        let decisions = self.decisions
        let markdownView = tools.builder.markdown(existing, image: noteImage.state)
        let merge = RecordMerger.merge(
            RecordMerger(
                recordID: id, title: candidate.title, path: candidate.path, base: base, apple: appleView,
                markdown: markdownView,
                resolution: { decisions.resolution(ofConflict: $0) }, aliases: aliases))
        for (field, alias) in aliases
        where ScalarField(rawValue: field).map({ ScalarField.key(appleView.scalars[$0]) == alias.observed }) == true {
            sync?.unapplyable.markAliasUsed(record: id, field: field)
        }
        sync?.conflicts += merge.conflicts
        plan.reviews += merge.conflicts.map(ReviewItem.conflict)
        if base.body == .unknown, let appleBody = appleView.body {
            noteBaseline(candidate, merge: merge, apple: appleBody, markdown: markdownView.body ?? "")
        }

        var (result, rename) = tools.materializer.apply(merge, to: existing, base: base)
        if let rename { sync?.renames[id] = rename }
        let plannedImage = applyImage(merge.markdownImage, to: &result, candidate: candidate, current: noteImage.state)
        result.sync = SyncMetadata(id: id, status: existing.sync.status, other: existing.sync.other)
        let imageData = merge.appleImage == nil ? nil : imageBytes(noteImage.path)
        planAppleWrites(
            candidate, merge: merge, imageData: imageData, writer: tools.writer, renamer: tools.renamer)
        sync?.states[id] = RecordSyncState(
            recordID: id, cardIDs: contact.cardIDs, stampID: contact.stampIDs.first, plannedNote: result,
            existingNote: existing, markdownImage: noteImage.state, plannedImage: plannedImage,
            previousBase: previous, apple: contact, title: candidate.title)
        return result
    }

    /// Applies an image change to the note (pulling Apple's photo writes the
    /// sidecar); returns the note's image state after the run.
    private mutating func applyImage(
        _ change: ImageChange?, to note: inout CanonicalContact, candidate: Candidate, current: ImageState
    ) -> ImageState {
        switch change {
        case .set?:
            guard let data = candidate.apple.imageData, let path = imagePath(for: candidate) else { return current }
            if (try? planner.fs.read(path).1.sha256) != FileStamp.hash(data) {
                plan.images.append(ImageWrite(path: path, recordID: candidate.recordID, data: data))
            }
            note.image = imageReference(for: candidate)
            return .hash(FileStamp.hash(data))
        case .remove?:
            note.image = nil
            return .none
        case nil:
            return current
        }
    }

    private mutating func planAppleWrites(
        _ candidate: Candidate, merge: MergeResult, imageData: Data?, writer: AppleWritePlanner,
        renamer: RelationRenamer
    ) {
        guard var sync else { return }
        let output = writer.plan(
            record: candidate.recordID, contact: candidate.apple, merge: merge, imageData: imageData,
            index: &sync.unapplyable, renamer: renamer)
        if !output.operations.isEmpty {
            sync.appleChanges.append(
                AppleRecordChange(
                    recordID: candidate.recordID, title: candidate.title, kind: .update,
                    operations: output.operations, fields: output.fields))
        }
        sync.blocked += output.blocked.map { "\(candidate.title): \($0)" }
        sync.newUnapplyable += output.newUnapplyable
        self.sync = sync
    }

    /// The stored base, without its body on the first sync with notes
    /// (`NotesStatus.freshStart`): bodies then merge by the first-bind rule.
    func notesBase(_ base: RecordBase?) -> RecordBase? {
        guard sync?.inputs.notes.freshStart == true else { return base }
        return base?.withoutBody()
    }

    /// Classifies a body merged without a base (the notes baseline summary).
    private mutating func noteBaseline(_ candidate: Candidate, merge: MergeResult, apple: String, markdown: String) {
        guard !(apple.isEmpty && markdown.isEmpty) else { return }
        let item = { (text: String) in
            NotesBaselineItem(recordID: candidate.recordID, title: candidate.title, path: candidate.path, text: text)
        }
        switch (merge.appleBody, merge.markdownBody) {
        case (let toApple?, nil): sync?.notesBaseline.toContacts.append(item(toApple ?? ""))
        case (nil, let toMarkdown?): sync?.notesBaseline.toMarkdown.append(item(toMarkdown ?? ""))
        case (let both?, _?): sync?.notesBaseline.keptBoth.append(item(both ?? ""))
        case (nil, nil):
            if merge.conflicts.contains(where: { $0.field == "body" }) {
                sync?.notesBaseline.conflicts.append(item(markdown))
            } else if apple == markdown {
                sync?.notesBaseline.adopted += 1
            }
        }
    }

    /// `to: "[[Old]]"` in other notes follows a regenerated title (§8).
    private func rewriteRenamedLinks(_ built: inout [BuiltNote], resolver: RelationResolver) {
        guard let renames = sync?.renames, !renames.isEmpty else { return }
        let byOldTitle = Dictionary(
            renames.map { (ComparisonKeys.name($0.value.oldTitle), ($0.key, $0.value.newTitle)) },
            uniquingKeysWith: { first, _ in first })
        for index in built.indices {
            for position in built[index].note.relationships.indices {
                guard case .wikilink(let inner)? = built[index].note.relationships[position].target,
                    let target = Wikilink.target(of: "[[\(inner)]]"),
                    let (record, newTitle) = byOldTitle[ComparisonKeys.name(target)],
                    resolver.record(named: target) == record
                else { continue }
                built[index].note.relationships[position].target = .wikilink(newTitle)
            }
        }
    }

    // MARK: - Verdicts

    mutating func finishSync() -> SyncPlan {
        guard let sync else { return SyncPlan(markdown: plan) }
        for id in sync.removed { plan.bindings[id] = nil }
        var result = SyncPlan(markdown: plan)
        result.apple = withStamps(sync.appleChanges, removed: sync.removed)
        result.conflicts = sync.conflicts
        result.trash = sync.trash
        result.blocked = sync.blocked
        result.awaitingDeleteConfirmation = sync.awaiting
        result.notes = sync.inputs.notes
        result.notesBaseline = sync.notesBaseline
        result.removedRecords = sync.removed
        result.titleRenames = sync.renames.map {
            TitleRename(recordID: $0.key, oldTitle: $0.value.oldTitle, newTitle: $0.value.newTitle)
        }
        .sorted { $0.oldTitle < $1.oldTitle }
        result.appleWritesEnabled = plan.config.appleWrites
        result.stampContacts = plan.config.stampContacts
        applyVerdicts(sync, to: &result)
        result.unapplyableKept = Array(sync.unapplyable.used) + sync.newUnapplyable
        result.newUnapplyable = sync.newUnapplyable
        result.vanished = sync.vanished
        result.imageHashes = sync.imageHashes
        result.records = sync.states
        result.context = sync.context
        return result
    }

    /// Stamps (only with `stamp_contacts`) join the record's update, else
    /// are their own change.
    private func withStamps(_ changes: [AppleRecordChange], removed: Set<UUID>) -> [AppleRecordChange] {
        guard plan.config.stampContacts else { return changes }
        var changes = changes
        for request in plan.stamps where !removed.contains(request.recordID) {
            let stamp = AppleWriteOperation.stamp(cardID: request.cardID, id: request.recordID)
            if let index = changes.firstIndex(where: { $0.recordID == request.recordID && $0.kind == .update }) {
                changes[index].operations.append(stamp)
                changes[index].fields.append("stamp")
            } else {
                changes.append(
                    AppleRecordChange(
                        recordID: request.recordID, title: request.title, kind: .stamp, operations: [stamp],
                        fields: ["stamp"]))
            }
        }
        return changes
    }

    /// Mass-vanish breaker, gating and blast radius, identity warning.
    private func applyVerdicts(_ sync: SyncRun, to result: inout SyncPlan) {
        let config = plan.config
        let total = max(records.records.count, 1)
        if !sync.options.allowMassVanish {
            if config.limits.tripsMassVanish(vanished: sync.newlyVanishedApple, total: total) {
                result.breaker = BreakerTrip(side: "apple", vanished: sync.newlyVanishedApple, total: total)
            } else if config.limits.tripsMassVanish(vanished: sync.newlyMissingNotes, total: total) {
                result.breaker = BreakerTrip(side: "markdown", vanished: sync.newlyMissingNotes, total: total)
            }
        }
        if !result.apple.isEmpty {
            let limit = sync.options.maxAppleChanges ?? config.limits.maxAppleChanges
            if !config.appleWrites {
                result.appleHold = .appleWritesDisabled
            } else if result.apple.count > limit {
                result.appleHold = .blastRadius(count: result.apple.count, limit: limit)
            }
        }
        let devices = Set(sync.inputs.deviceIDs)
        result.deviceCount = max(devices.count, 1)
        if devices.count > 1, !config.stampContacts {
            result.identityWarning =
                "\(devices.count) devices share this vault; enable stamp_contacts so devices agree on identity"
        }
    }
}
