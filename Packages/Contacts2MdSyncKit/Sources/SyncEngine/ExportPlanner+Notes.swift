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
        followGroupChanges()
        let groups = inputs.snapshot.groups.sorted { $0.name < $1.name }
        for group in groups where plan.config.tag(forGroup: group.name) == nil {
            plan.config.groups.append(GroupTag(group: group.name, tag: VaultConfig.defaultTag(forGroup: group.name)))
        }
        if plan.config != original || inputs.configText == nil {
            plan.configText = plan.config.render(patching: inputs.configText)
        }
    }

    /// Apple group renames and deletions since this device's last run, by
    /// CN group id (architecture §8). A rename moves the `groups:` entry to
    /// the new name; a tag that was the default for the old name becomes the
    /// default for the new one (a custom tag is kept), and synced notes get
    /// the new tag. A deleted group's entry is removed, so its tag is no
    /// longer managed: it stays in the notes and nothing is removed from them.
    mutating func followGroupChanges() {
        guard !inputs.knownGroups.isEmpty else { return }
        let current = Dictionary(inputs.snapshot.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentNames = Set(inputs.snapshot.groups.map(\.name))
        var handled = Set<String>()
        for known in inputs.knownGroups.sorted(by: { ($0.name, $0.groupID) < ($1.name, $1.groupID) }) {
            guard !currentNames.contains(known.name), !handled.contains(known.name),
                let index = plan.config.groups.firstIndex(where: { $0.group == known.name })
            else { continue }
            let entry = plan.config.groups[index]
            if let group = current[known.groupID] {
                handled.insert(known.name)
                renameGroup(entry, at: index, to: group.name)
            } else if !inputs.knownGroups.contains(where: { $0.name == known.name && current[$0.groupID] != nil }) {
                handled.insert(known.name)
                plan.config.groups.remove(at: index)
                plan.groupChanges.append(GroupChange(kind: .deleted, group: known.name, tag: entry.tag))
            }
        }
    }

    private mutating func renameGroup(_ entry: GroupTag, at index: Int, to name: String) {
        let oldKey = ComparisonKeys.tag(entry.tag)
        let sharedTag = plan.config.groups.indices.contains {
            $0 != index && ComparisonKeys.tag(plan.config.groups[$0].tag) == oldKey
        }
        let newTag: String
        if let mapped = plan.config.tag(forGroup: name) {
            // The new name is mapped already (another device followed the rename first).
            newTag = mapped
            plan.config.groups.remove(at: index)
        } else {
            newTag =
                oldKey == VaultConfig.defaultTag(forGroup: entry.group) && !sharedTag
                ? VaultConfig.defaultTag(forGroup: name) : entry.tag
            plan.config.groups[index] = GroupTag(group: name, tag: newTag)
        }
        if ComparisonKeys.tag(newTag) != oldKey, !sharedTag { tagRenames[oldKey] = newTag }
        plan.groupChanges.append(
            GroupChange(kind: .renamed, group: entry.group, newGroup: name, tag: entry.tag, newTag: newTag))
    }

    /// Tags renamed with their Apple group (§8), in place, without repeats.
    func renamingTags(_ tags: [String]) -> [String] {
        guard !tagRenames.isEmpty else { return tags }
        var seen = Set<String>()
        return tags.map { tagRenames[ComparisonKeys.tag($0)] ?? $0 }.filter {
            seen.insert(ComparisonKeys.tag($0)).inserted
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
            let note = MarkdownCodec.normalize(projection.project(exportInputs(for: candidate, resolver: resolver)))
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

    func exportInputs(for candidate: Candidate, resolver: NameResolver) -> ExportProjection.Inputs {
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
    func imageReference(for candidate: Candidate) -> ImageRef? {
        guard let path = imagePath(for: candidate) else { return nil }
        return ImageRef(path: VaultPath.relative(path, fromDirectory: VaultPath.directory(of: candidate.path)))
    }

    func imagePath(for candidate: Candidate) -> String? {
        guard let data = candidate.apple.imageData else { return nil }
        let name = "\(candidate.recordID.uuidString.lowercased()).\(ImageFormat.fileExtension(for: data))"
        return VaultPath.join(plan.config.imagesFolder, name)
    }

    mutating func record(_ candidate: Candidate, note: CanonicalContact, data: Data, writeImage: Bool = true) {
        let contact = candidate.apple
        if writeImage, let imagePath = imagePath(for: candidate), let imageData = contact.imageData,
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
        let corroborated = self.corroborated.contains(candidate.recordID)
        let cards = contact.cards.map { card in
            let known = previous[card.id]
            let settled = known.map { inputs.now.timeIntervalSince($0.firstSeen) >= BoundCard.settleInterval } ?? false
            return BoundCard(
                id: card.id, containerID: card.containerID, accountKind: card.accountKind,
                firstSeen: known?.firstSeen ?? inputs.now,
                stampSeen: card.stampID == candidate.recordID || (known?.stampSeen ?? false),
                confirmed: (known?.confirmed ?? false) || (corroborated && settled))
        }
        return RecordBinding(
            unifiedID: contact.unifiedID, cards: cards, path: path,
            base: BaseKeys(keyer: planner.keyer).base(of: values(contact)))
    }
}
