public import ContactModel
public import Foundation
internal import MarkdownCodec
public import VaultIndex

/// Plans a one-way Apple → markdown export: the M1 subset of the first-import
/// planner (architecture §6). Pure apart from reading the vault; writes
/// nothing. The result is executed by `ExportExecutor`.
///
/// Identity of each Apple contact, in order: its `x-mdsync:` stamp, then the
/// per-device `RecordMap` (unified id or any card id). A bound contact's note
/// is found by `mdsync.id` wherever it lives under the root and updated in
/// place. An unbound contact gets a new id and a new note, unless:
/// - it is a non-primary member of a duplicate cluster (one note per cluster
///   until the user resolves it), or
/// - it matches an existing note nobody is bound to (create gate: reported
///   for review, not created).
public struct ExportPlanner: Sendable {
    public let fs: any VaultFS
    public let keyer: any PhoneKeyer
    public let ids: any IDGenerator
    public let options: ExportOptions

    /// Creates a planner.
    public init(fs: any VaultFS, keyer: any PhoneKeyer, ids: any IDGenerator, options: ExportOptions = ExportOptions())
    {
        self.fs = fs
        self.keyer = keyer
        self.ids = ids
        self.options = options
    }

    /// Plans the export of `snapshot` into the vault described by `index`.
    public func plan(
        snapshot: AppleSnapshot,
        index: VaultIndex,
        records: RecordMap,
        config: VaultConfig,
        configText: String?
    ) throws -> ExportPlan {
        var run = PlanningRun(
            planner: self, snapshot: snapshot, index: index, records: records, plan: ExportPlan(config: config))
        run.reportVaultProblems()
        run.resolveIdentities()
        run.limitClustersToOneNote()
        run.chooseNotes()
        run.updateGroups(configText: configText)
        run.buildNotes()
        return run.plan
    }

    /// The member that gets the cluster's one note: iCloud-backed first, then
    /// local, then lowest unified id.
    static func primary(of members: [AppleContact]) -> AppleContact? {
        func rank(_ contact: AppleContact) -> Int {
            if contact.isICloudBacked { return 0 }
            if contact.cards.contains(where: { $0.accountKind == .local }) { return 1 }
            return 2
        }
        return members.min { (rank($0), $0.unifiedID) < (rank($1), $1.unifiedID) }
    }
}

/// The working state of one planning run, phase by phase.
private struct PlanningRun {
    /// A contact chosen for export, before its note is built.
    struct Candidate {
        var apple: AppleContact
        var recordID: UUID
        var existing: VaultEntry?
        var title: String
        var path: String
    }

    let planner: ExportPlanner
    let snapshot: AppleSnapshot
    let index: VaultIndex
    let records: RecordMap
    var plan: ExportPlan
    /// Apple contacts, sorted by unified id for deterministic output.
    let contacts: [AppleContact]
    /// Unified id → record id, for contacts that already have one.
    var boundIDs: [String: UUID] = [:]
    /// Unified ids that must not be exported this run.
    var blocked = Set<String>()
    var candidates: [Candidate] = []
    var plannedStems = Set<String>()

    init(planner: ExportPlanner, snapshot: AppleSnapshot, index: VaultIndex, records: RecordMap, plan: ExportPlan) {
        self.planner = planner
        self.snapshot = snapshot
        self.index = index
        self.records = records
        self.plan = plan
        self.contacts = snapshot.contacts.sorted { $0.unifiedID < $1.unifiedID }
        self.plan.appleContactCount = snapshot.contacts.count
        self.plan.markdownOnly = index.unlinkedContacts.count
    }

    private func title(_ contact: AppleContact) -> String { TitleGenerator.title(for: contact.contact) }

    private mutating func skip(_ contact: AppleContact, _ reason: String) {
        plan.skipped.append(SkippedContact(title: title(contact), reason: reason))
    }

    // MARK: Phase 1: vault problems

    mutating func reportVaultProblems() {
        for entry in index.problems where entry.note == nil {
            plan.reviews.append(.unreadableFile(path: entry.path, problem: entry.problem ?? "unreadable"))
        }
        for (id, paths) in index.duplicateIDs.sorted(by: { $0.value[0] < $1.value[0] }) {
            plan.reviews.append(.duplicateSyncID(id: id, paths: paths.sorted()))
        }
    }

    // MARK: Phase 2: identity (stamp, then record map)

    mutating func resolveIdentities() {
        let lookup = RecordMap.Lookup(records)
        for contact in contacts {
            let stamps = contact.stampIDs
            if stamps.count > 1 {
                plan.reviews.append(.multipleStamps(title: title(contact), ids: stamps))
                skip(contact, "carries several sync stamps (linked cards)")
                blocked.insert(contact.unifiedID)
            } else if let id = stamps.first
                ?? lookup.recordID(unifiedID: contact.unifiedID, cardIDs: contact.cards.map(\.id))
            {
                boundIDs[contact.unifiedID] = id
            }
        }
    }

    // MARK: Phase 3: duplicate clusters → at most one note each

    mutating func limitClustersToOneNote() {
        let byUnifiedID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.unifiedID, $0) })
        for cluster in Clustering.clusters(of: contacts, keyer: planner.keyer) {
            let members = cluster.memberIDs.compactMap { byUnifiedID[$0] }
            let alreadyExported = members.contains { notePath(of: $0) != nil }
            let primary = alreadyExported ? nil : ExportPlanner.primary(of: members)
            for member in members where boundIDs[member.unifiedID] == nil && member.unifiedID != primary?.unifiedID {
                blocked.insert(member.unifiedID)
                skip(member, "possible duplicate; review before export")
            }
            let described = members.map { member in
                ClusterMember(
                    unifiedID: member.unifiedID, title: title(member), accounts: member.cards.map(\.accountKind),
                    path: notePath(of: member))
            }
            plan.reviews.append(.duplicateCluster(members: described, reasons: cluster.reasons))
        }
    }

    private func notePath(of contact: AppleContact) -> String? {
        boundIDs[contact.unifiedID].flatMap { index.entries(withID: $0).first?.path }
    }

    // MARK: Phase 4: existing note by id, or a new one past the create gate

    mutating func chooseNotes() {
        let gate = CreateGate(index: index, records: records, snapshot: snapshot, keyer: planner.keyer)
        let duplicateIDs = index.duplicateIDs
        for contact in contacts where !blocked.contains(contact.unifiedID) {
            guard let id = boundIDs[contact.unifiedID] else {
                if let match = gate.match(contact) {
                    plan.reviews.append(.possibleMatch(title: title(contact), path: match.path, reason: match.reason))
                    skip(contact, "may already exist as \(match.path)")
                } else {
                    addNewNote(for: contact, id: planner.ids.next())
                }
                continue
            }
            if duplicateIDs[id] != nil {
                skip(contact, "its note was copied; pick one first")
            } else if let entry = index.entries(withID: id).first {
                candidates.append(
                    Candidate(apple: contact, recordID: id, existing: entry, title: entry.title, path: entry.path))
            } else if records[id] != nil, !planner.options.restoreMissing {
                // Missing only if *this* vault had it: a stamp from another
                // vault, or a fresh root, just means "not exported here yet".
                plan.reviews.append(.missingFile(title: title(contact), id: id, lastPath: records[id]?.path))
                skip(contact, "note was deleted; not re-created")
            } else {
                addNewNote(for: contact, id: id)
            }
        }
    }

    private mutating func addNewNote(for contact: AppleContact, id: UUID) {
        let title = title(contact)
        let taken = plannedStems
        let stem = Filenames.uniqueStem(title: title, company: contact.contact.company?.name) {
            index.isStemTaken($0) || taken.contains($0)
        }
        plannedStems.insert(stem.lowercased())
        let path = VaultPath.join(plan.config.defaultFolder, stem + ".md")
        candidates.append(Candidate(apple: contact, recordID: id, existing: nil, title: title, path: path))
    }

    // MARK: Phase 5: Apple groups → managed tags

    mutating func updateGroups(configText: String?) {
        let original = plan.config
        let groups = snapshot.groups.sorted { $0.name < $1.name }
        for group in groups where plan.config.tag(forGroup: group.name) == nil {
            plan.config.groups.append(GroupTag(group: group.name, tag: VaultConfig.defaultTag(forGroup: group.name)))
        }
        if plan.config != original || configText == nil {
            plan.configText = plan.config.render(patching: configText)
        }
    }

    // MARK: Phase 6: build, emit and validate each note

    mutating func buildNotes() {
        let resolver = NameResolver(
            candidates: candidates.map { NamedNote(contact: $0.apple, title: $0.title, path: $0.path) }, index: index)
        let projection = ExportProjection(keyer: planner.keyer, notesAvailable: snapshot.notesAvailable)
        var pathsByTitle: [String: [String]] = [:]
        for candidate in candidates {
            let note = MarkdownCodec.normalize(projection.project(inputs(for: candidate, resolver: resolver)))
            pathsByTitle[ComparisonKeys.name(note.title), default: []].append(candidate.path)
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
    }

    private mutating func inputs(for candidate: Candidate, resolver: NameResolver) -> ExportProjection.Inputs {
        let contact = candidate.apple
        let groupNames = Dictionary(snapshot.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ExportProjection.Inputs(
            apple: contact,
            existing: candidate.existing?.contact,
            recordID: candidate.recordID,
            title: candidate.title,
            company: resolver.company(for: contact.contact, existing: candidate.existing?.contact?.company),
            relationships: contact.contact.relationships.map(resolver.resolve),
            appleTags: contact.groupIDs.compactMap { groupNames[$0] }.compactMap(plan.config.tag(forGroup:)),
            managedTagKeys: plan.config.managedTagKeys,
            image: imageReference(for: candidate),
            managedImagePrefix: candidate.recordID.uuidString.lowercased()
        )
    }

    /// The `image:` path for the candidate's photo; queues the sidecar write
    /// unless identical bytes are already there.
    private mutating func imageReference(for candidate: Candidate) -> ImageRef? {
        guard let data = candidate.apple.imageData else { return nil }
        let name = "\(candidate.recordID.uuidString.lowercased()).\(ImageFormat.fileExtension(for: data))"
        let imagePath = VaultPath.join(plan.config.imagesFolder, name)
        if (try? planner.fs.read(imagePath).1.sha256) != FileStamp.hash(data) {
            plan.images.append(ImageWrite(path: imagePath, recordID: candidate.recordID, data: data))
        }
        return ImageRef(path: VaultPath.relative(imagePath, fromDirectory: VaultPath.directory(of: candidate.path)))
    }

    private mutating func record(_ candidate: Candidate, note: CanonicalContact, data: Data) {
        let contact = candidate.apple
        plan.bindings[candidate.recordID] = RecordBinding(
            unifiedID: contact.unifiedID, cardIDs: contact.cards.map(\.id), path: candidate.path)
        if let card = contact.stampTargetCard, card.stampID != candidate.recordID {
            plan.stamps.append(StampRequest(cardID: card.id, recordID: candidate.recordID, title: note.title))
        }
        guard let existing = candidate.existing, let stamp = existing.stamp else {
            plan.creates.append(
                FileChange(
                    path: candidate.path, recordID: candidate.recordID, title: note.title, data: data,
                    expecting: .absent, changedFields: []))
            return
        }
        if stamp.sha256 == FileStamp.hash(data) {
            plan.unchanged += 1
            return
        }
        let fields = existing.contact.map { MarkdownCodec.differingKeys(MarkdownCodec.normalize($0), note) } ?? []
        plan.updates.append(
            FileChange(
                path: candidate.path, recordID: candidate.recordID, title: note.title, data: data,
                expecting: .unchanged(stamp), changedFields: fields))
    }
}
