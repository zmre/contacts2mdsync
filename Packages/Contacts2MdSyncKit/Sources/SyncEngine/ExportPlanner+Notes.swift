internal import ContactModel
internal import Foundation
internal import MarkdownCodec
internal import VaultIndex

/// Phases 7–8 of `PlanningRun`: groups, then building, emitting and
/// validating every note, and the bindings to persist.
extension PlanningRun {
    // MARK: Phase 7: Apple groups → managed tags

    mutating func updateGroups() {
        let original = plan.config
        let groups = inputs.snapshot.groups.sorted { $0.name < $1.name }
        for group in groups where plan.config.tag(forGroup: group.name) == nil {
            plan.config.groups.append(GroupTag(group: group.name, tag: VaultConfig.defaultTag(forGroup: group.name)))
        }
        if plan.config != original || inputs.configText == nil {
            plan.configText = plan.config.render(patching: inputs.configText)
        }
    }

    // MARK: Phase 8: build, emit and validate each note

    mutating func buildNotes() {
        let resolver = NameResolver(
            candidates: candidates.map {
                NamedNote(contact: $0.apple, values: values($0.apple), title: $0.title, path: $0.path)
            },
            index: index)
        let projection = ExportProjection(keyer: planner.keyer, notesAvailable: inputs.snapshot.notesAvailable)
        var pathsByTitle: [String: Set<String>] = [:]
        for entry in index.entries where entry.isContactNote {
            pathsByTitle[ComparisonKeys.name(entry.title), default: []].insert(entry.path)
        }
        for candidate in candidates {
            let note = MarkdownCodec.normalize(projection.project(inputs(for: candidate, resolver: resolver)))
            pathsByTitle[ComparisonKeys.name(note.title), default: []].insert(candidate.path)
            do {
                let data = Data(try MarkdownCodec.encode(note, patching: candidate.existing?.note).utf8)
                record(candidate, note: note, data: data)
            } catch {
                plan.skipped.append(SkippedContact(title: note.title, reason: String(describing: error)))
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

    private func inputs(for candidate: Candidate, resolver: NameResolver) -> ExportProjection.Inputs {
        let contact = candidate.apple
        let contactValues = values(contact)
        let groupNames = Dictionary(
            inputs.snapshot.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ExportProjection.Inputs(
            apple: contact,
            values: contactValues,
            existing: candidate.existing?.contact,
            base: records[candidate.recordID]?.base,
            recordID: candidate.recordID,
            title: candidate.title,
            company: resolver.company(for: contactValues, existing: candidate.existing?.contact?.company),
            relationships: contactValues.relationships.map(resolver.resolve),
            appleTags: contact.groupIDs.compactMap { groupNames[$0] }.compactMap(plan.config.tag(forGroup:)),
            managedTagKeys: plan.config.managedTagKeys,
            image: imageReference(for: candidate),
            managedImagePrefix: candidate.recordID.uuidString.lowercased()
        )
    }

    /// The `image:` path for the candidate's photo. The sidecar write is
    /// queued by `record` unless identical bytes are already there.
    private func imageReference(for candidate: Candidate) -> ImageRef? {
        guard let path = imagePath(for: candidate) else { return nil }
        return ImageRef(path: VaultPath.relative(path, fromDirectory: VaultPath.directory(of: candidate.path)))
    }

    private func imagePath(for candidate: Candidate) -> String? {
        guard let data = candidate.apple.imageData else { return nil }
        let name = "\(candidate.recordID.uuidString.lowercased()).\(ImageFormat.fileExtension(for: data))"
        return VaultPath.join(plan.config.imagesFolder, name)
    }

    private mutating func record(_ candidate: Candidate, note: CanonicalContact, data: Data) {
        let contact = candidate.apple
        if let imagePath = imagePath(for: candidate), let imageData = contact.imageData,
            (try? planner.fs.read(imagePath).1.sha256) != FileStamp.hash(imageData)
        {
            plan.images.append(ImageWrite(path: imagePath, recordID: candidate.recordID, data: imageData))
        }
        plan.bindings[candidate.recordID] = binding(for: candidate, path: candidate.path)
        if let card = contact.stampTargetCard, card.stampID != candidate.recordID {
            plan.stamps.append(StampRequest(cardID: card.id, recordID: candidate.recordID, title: note.title))
        }
        guard let existing = candidate.existing, let stamp = existing.stamp else {
            plan.creates.append(
                FileChange(
                    path: candidate.path, recordID: candidate.recordID, title: note.title, data: data,
                    expecting: .absent, changedFields: [], kind: .create, detail: nil))
            return
        }
        if stamp.sha256 == FileStamp.hash(data) {
            plan.unchanged += 1
            return
        }
        let fields = existing.contact.map { MarkdownCodec.differingKeys(MarkdownCodec.normalize($0), note) } ?? []
        var kind = candidate.kind
        let moved = records[candidate.recordID].map { $0.path != candidate.path } ?? false
        if kind == .update, moved, fields == ["image"] { kind = .pathFixup }
        plan.updates.append(
            FileChange(
                path: candidate.path, recordID: candidate.recordID, title: note.title, data: data,
                expecting: .unchanged(stamp), changedFields: fields, kind: kind, detail: candidate.detail))
    }

    /// The record's new binding: cards as seen now, keeping first-seen dates
    /// and stamp sightings of cards already bound.
    private func binding(for candidate: Candidate, path: String) -> RecordBinding {
        let contact = candidate.apple
        let previous = Dictionary(
            (records[candidate.recordID]?.cards ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cards = contact.cards.map { card in
            BoundCard(
                id: card.id, containerID: card.containerID, accountKind: card.accountKind,
                firstSeen: previous[card.id]?.firstSeen ?? inputs.now,
                stampSeen: card.stampID == candidate.recordID || (previous[card.id]?.stampSeen ?? false))
        }
        return RecordBinding(
            unifiedID: contact.unifiedID, cards: cards, path: path,
            base: BaseKeys(keyer: planner.keyer).base(of: values(contact)))
    }
}
