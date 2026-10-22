public import ContactModel
public import Foundation
internal import MarkdownCodec
public import VaultIndex

/// Everything a plan is computed from.
public struct ExportInputs: Sendable {
    public var snapshot: AppleSnapshot
    public var index: VaultIndex
    public var records: RecordMap
    public var config: VaultConfig
    public var configText: String?
    public var decisions: DecisionSet
    /// Content hashes of non-contact problem files already reported.
    public var reportedProblems: Set<String>
    /// "Now", for card first-seen dates.
    public var now: Date

    /// Creates inputs.
    public init(
        snapshot: AppleSnapshot, index: VaultIndex, records: RecordMap, config: VaultConfig,
        configText: String?, decisions: DecisionSet = DecisionSet(), reportedProblems: Set<String> = [],
        now: Date = Date()
    ) {
        self.snapshot = snapshot
        self.index = index
        self.records = records
        self.config = config
        self.configText = configText
        self.decisions = decisions
        self.reportedProblems = reportedProblems
        self.now = now
    }
}

/// Plans a one-way Apple → markdown export (architecture §6, "What M1/M2
/// implement"). Pure apart from reading image sidecars; writes nothing. The
/// result is executed by `ExportExecutor`.
///
/// Identity of each Apple contact, in cascade order:
/// 1. its `x-c2mdsync:` stamp on any underlying card (several different
///    stamps → merge-records review, skipped);
/// 2. cached underlying card ids in the device state (trusted ids bind;
///    untrusted Google ids bind only when the record's base or note agrees);
/// 3. matching against notes nobody is bound to — hand-written notes without
///    an id (adoption) and orphaned notes whose record lost its cards
///    (relocation). Confidence ≥ 0.9 with no ambiguity binds automatically
///    for relocations and, on a first import, for adoptions; any other match
///    blocks creation and becomes a review item.
///
/// Unlinked duplicate clusters yield one note until resolved; recorded
/// decisions (`DecisionSet`) settle clusters, matches and copied notes.
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

    /// Plans the export of `snapshot` into the vault described by `index`
    /// (no decisions; M1-compatible entry point).
    public func plan(
        snapshot: AppleSnapshot,
        index: VaultIndex,
        records: RecordMap,
        config: VaultConfig,
        configText: String?
    ) throws -> ExportPlan {
        try plan(
            ExportInputs(snapshot: snapshot, index: index, records: records, config: config, configText: configText))
    }

    /// Plans an export.
    public func plan(_ inputs: ExportInputs) throws -> ExportPlan {
        var run = PlanningRun(planner: self, inputs: inputs)
        run.reportVaultProblems()
        run.resolveIdentities()
        run.blockDetached()
        run.applyExclusions()
        run.limitClustersToOneNote()
        run.matchUnboundContacts()
        run.chooseNotes()
        run.updateGroups()
        run.buildNotes()
        return run.plan
    }
}

/// The working state of one planning run, phase by phase.
struct PlanningRun {
    /// A contact chosen for export, before its note is built.
    struct Candidate {
        var apple: AppleContact
        var recordID: UUID
        var existing: VaultEntry?
        var title: String
        var path: String
        var kind: FileChangeKind
        var detail: String?
    }

    let planner: ExportPlanner
    let inputs: ExportInputs
    var plan: ExportPlan
    /// Apple contacts in deterministic order.
    let contacts: [AppleContact]
    /// Card-precedence values per contact (architecture §6).
    let values: [String: CanonicalContact]
    /// Unified id → record id, for contacts that already have one.
    var boundIDs: [String: UUID] = [:]
    /// How each binding was made (for output and trust bookkeeping).
    var adoptions: [String: (entry: VaultEntry, detail: String)] = [:]
    /// Unified ids that must not be exported this run.
    var blocked = Set<String>()
    /// Unified ids a cluster decision left out of sync (still clustered, so
    /// a re-reported cluster shows them with their earlier answer).
    var decisionExcluded = Set<String>()
    /// Record ids paused because their notes were copied (or have iCloud
    /// conflict versions, `pauseReasons`).
    var pausedIDs = Set<UUID>()
    /// Why a record is paused, when it is not a copied note.
    var pauseReasons: [UUID: String] = [:]
    /// Paths of copies ignored by a dup-id-keep decision.
    var ignoredCopies = Set<String>()
    /// New notes are held back (unknown iCloud placeholders).
    var holdCreates = false
    var candidates: [Candidate] = []
    var plannedStems = Set<String>()
    /// Records whose contact was bound by stamp, trusted id or corroboration.
    var corroborated = Set<UUID>()
    /// Records some contact still points at (stamp or card id), bound or not:
    /// never "deleted in Contacts" (Google churn, ambiguity, review).
    var claimedRecords = Set<UUID>()
    /// Ids of notes marked `c2mdsync.status: detached` (not synced).
    var detachedIDs = Set<UUID>()
    /// Note paths proposed as possible matches this run.
    var proposedPaths = Set<String>()
    /// Records merged into another by a merge-keep decision.
    var mergedAway: [UUID: MergedRecord] = [:]
    /// Two-way sync state (`nil` for a one-way export).
    var sync: SyncRun?

    var index: VaultIndex { inputs.index }
    var records: RecordMap { inputs.records }
    var decisions: DecisionSet { inputs.decisions }

    init(planner: ExportPlanner, inputs: ExportInputs) {
        self.planner = planner
        self.inputs = inputs
        self.plan = ExportPlan(config: inputs.config)
        self.contacts = inputs.snapshot.contacts.sorted { $0.sortKey < $1.sortKey }
        self.values = Dictionary(
            inputs.snapshot.contacts.map { ($0.unifiedID, $0.cardMergedContact(keyer: planner.keyer)) },
            uniquingKeysWith: { first, _ in first })
        self.plan.appleContactCount = inputs.snapshot.contacts.count
        switch planner.options.autoAdopt {
        case .firstImport: self.plan.autoAdopt = inputs.records.records.isEmpty
        case .always: self.plan.autoAdopt = true
        case .never: self.plan.autoAdopt = false
        }
    }

    func values(_ contact: AppleContact) -> CanonicalContact { values[contact.unifiedID] ?? contact.contact }

    func title(_ contact: AppleContact) -> String { TitleGenerator.title(for: values(contact)) }

    func ref(_ contact: AppleContact) -> ContactRef {
        ContactRef(cardIDs: contact.cardIDs, title: title(contact))
    }

    mutating func skip(_ contact: AppleContact, _ reason: String, needsReview: Bool = true) {
        plan.skipped.append(SkippedContact(title: title(contact), reason: reason, needsReview: needsReview))
    }

    // MARK: Phase 1: vault problems

    mutating func reportVaultProblems() {
        for entry in index.contacts where entry.contact?.sync.status == SyncMetadata.detached {
            if let id = entry.syncID { detachedIDs.insert(id) }
        }
        for entry in index.problems {
            if entry.problemIsContactRelated {
                plan.reviews.append(.unreadableFile(path: entry.path, problem: entry.problem ?? "unreadable"))
            } else if let sha = entry.sha256, !inputs.reportedProblems.contains(sha) {
                plan.newProblems.append(ProblemNotice(path: entry.path, problem: entry.problem ?? "", sha256: sha))
            } else {
                plan.knownProblemCount += 1
            }
        }
        for (id, paths) in index.duplicateIDs.sorted(by: { $0.value.sorted()[0] < $1.value.sorted()[0] }) {
            if let kept = decisions.keptPath(forDuplicate: id), paths.contains(kept) {
                ignoredCopies.formUnion(paths.filter { $0 != kept })
                plan.notes.append(
                    "copies of \(kept) ignored (decision): "
                        + paths.filter { $0 != kept }.sorted().joined(separator: ", ")
                )
            } else {
                pausedIDs.insert(id)
                plan.reviews.append(.duplicateSyncID(id: id, paths: paths.sorted()))
            }
        }
        planVersionConflicts()
        let undownloaded = index.undownloaded.map(\.path)
        if !undownloaded.isEmpty, !planner.options.allowUndownloaded {
            holdCreates = true
            plan.reviews.append(.undownloaded(paths: undownloaded))
        }
    }

    /// The note of record `id` (a kept copy wins over ignored ones).
    func note(of id: UUID) -> VaultEntry? {
        index.entries(withID: id).first { !ignoredCopies.contains($0.path) }
    }

    // MARK: Phase 2: identity (stamp, then cached card ids)

    mutating func resolveIdentities() {
        var claimedByStamp = Set<UUID>()
        var unstamped: [AppleContact] = []
        for contact in contacts {
            let stamps = contact.stampIDs
            if stamps.count > 1 {
                resolveSeveralStamps(contact, stamps: stamps)
                claimedByStamp.formUnion(stamps)
            } else if let id = stamps.first {
                boundIDs[contact.unifiedID] = id
                claimedByStamp.insert(id)
                corroborated.insert(id)
            } else {
                unstamped.append(contact)
            }
        }
        claimedRecords.formUnion(claimedByStamp)
        // Cached card ids: each record goes to its strongest claimant.
        let lookup = RecordMap.Lookup(records)
        var claims: [UUID: [(contact: AppleContact, hit: RecordMap.CardHit)]] = [:]
        for contact in unstamped {
            let allHits = lookup.hits(cardIDs: contact.cardIDs)
            claimedRecords.formUnion(allHits.map(\.recordID))
            let hits = allHits.filter { !claimedByStamp.contains($0.recordID) }
            let trusted = hits.filter(\.trusted)
            if trusted.count > 1 { continue }  // ambiguous: let the cascade decide
            let corroboratedHit = hits.first { corroborates(contact, record: $0.recordID) }
            guard let hit = trusted.first ?? corroboratedHit else { continue }
            if hit.trusted || corroboratedHit?.recordID == hit.recordID { corroborated.insert(hit.recordID) }
            claims[hit.recordID, default: []].append((contact, hit))
        }
        for (recordID, claimants) in claims {
            let ranked = claimants.sorted { lhs, rhs in
                (lhs.hit.trusted ? 0 : 1, lhs.hit.viaICloud ? 0 : 1, lhs.contact.sortKey)
                    < (rhs.hit.trusted ? 0 : 1, rhs.hit.viaICloud ? 0 : 1, rhs.contact.sortKey)
            }
            if ranked.count > 1, ranked[0].hit.trusted == ranked[1].hit.trusted,
                ranked[0].hit.viaICloud == ranked[1].hit.viaICloud
            {
                continue  // several contacts claim the record equally (unlinked?): cascade + clusters
            }
            boundIDs[ranked[0].contact.unifiedID] = recordID
        }
    }

    /// An untrusted (Google) cached id counts only when the record's base, or
    /// else its note, agrees on a name or strong key.
    func corroborates(_ contact: AppleContact, record id: UUID) -> Bool {
        let profile = MatchProfile(apple: values(contact), keyer: planner.keyer)
        if let base = records[id]?.base {
            let names = Set(base.keys("name"))
            let strong = Set(base.keys("emails").map { "email:" + $0 } + base.keys("phones").map { "phone:" + $0 })
            return !profile.names.isDisjoint(with: names) || !profile.strong.isDisjoint(with: strong)
        }
        guard let entry = note(of: id), let contactNote = entry.contact else { return false }
        let score = profile.score(against: MatchProfile(note: entry, contact: contactNote, keyer: planner.keyer))
        return score.map { !$0.advisory } ?? false
    }

    // MARK: Phase 3: cluster exclusions (sync-only, cluster-resolve)

    /// The contact's cluster role as this run applies it. A legacy sync-only
    /// decision only ever held back contacts without a note: one that has a
    /// note keeps syncing to it, a person of its own.
    func clusterRole(of contact: AppleContact) -> ClusterRole? {
        guard var role = decisions.clusterRole(of: contact) else { return nil }
        if role.kind == .syncOnly, role.isExcluded, boundIDs[contact.unifiedID] != nil { role.group = role.reference }
        return role
    }

    mutating func applyExclusions() {
        for contact in contacts where !blocked.contains(contact.unifiedID) {
            guard let role = clusterRole(of: contact), role.isExcluded else { continue }
            let id = boundIDs[contact.unifiedID]
            blocked.insert(contact.unifiedID)
            decisionExcluded.insert(contact.unifiedID)
            plan.excludedByDecision += 1
            if isSync, let id, let entry = note(of: id), records[id] != nil,
                plan.config.scope.onLeaveScope == "detach"
            {
                detach(entry, id: id, reason: "left out of sync in Duplicates")
            } else {
                let reason = role.kind == .syncOnly ? "a sync-only decision" : "a duplicates decision"
                skip(contact, "excluded by \(reason)", needsReview: false)
            }
        }
    }

    func notePath(of contact: AppleContact) -> String? {
        boundIDs[contact.unifiedID].flatMap { note(of: $0)?.path }
    }

    // MARK: Phase 6: existing note by id, or a new one

    mutating func chooseNotes() {
        for contact in contacts where !blocked.contains(contact.unifiedID) {
            if let id = boundIDs[contact.unifiedID] {
                chooseNote(for: contact, id: id)
            } else if holdCreates {
                skip(contact, "new note held back until iCloud finishes downloading notes")
            } else {
                addNewNote(for: contact, id: planner.ids.next())
            }
        }
    }

    /// The note of a bound contact: adopted, found by id, missing, or new.
    mutating func chooseNote(for contact: AppleContact, id: UUID) {
        if let adoption = adoptions[contact.unifiedID] {
            candidates.append(
                Candidate(
                    apple: contact, recordID: id, existing: adoption.entry, title: adoption.entry.title,
                    path: adoption.entry.path, kind: .adopt, detail: adoption.detail))
        } else if pausedIDs.contains(id) {
            skip(contact, pauseReasons[id] ?? "its note was copied; pick one first")
        } else if let entry = note(of: id) {
            useExisting(entry, for: contact, id: id)
        } else if records[id] != nil, !index.undownloaded.isEmpty {
            // Not found, but some notes are placeholders we cannot read:
            // never conclude "deleted" (architecture §9).
            skip(contact, "note not found; it may be one of the notes not downloaded from iCloud", needsReview: false)
        } else if records[id] != nil, !planner.options.restoreMissing, sync != nil {
            markdownDeleted(contact, id: id)
        } else if records[id] != nil, !planner.options.restoreMissing {
            // Missing only if *this* vault had it: a stamp from another
            // vault, or a fresh root, just means "not exported here yet".
            plan.reviews.append(.missingFile(title: title(contact), id: id, lastPath: records[id]?.path))
            skip(contact, "note was deleted; not re-created")
        } else if holdCreates {
            skip(contact, "new note held back until iCloud finishes downloading notes")
        } else {
            addNewNote(for: contact, id: id)
        }
    }

    mutating func useExisting(_ entry: VaultEntry, for contact: AppleContact, id: UUID) {
        guard !entry.isDataless else {
            skip(contact, "\(entry.path) is not downloaded from iCloud yet", needsReview: false)
            return
        }
        guard entry.contact != nil else { return }
        if let previous = records[id]?.path, previous != entry.path {
            plan.moves.append(NoteMove(recordID: id, oldPath: previous, newPath: entry.path))
        }
        candidates.append(
            Candidate(
                apple: contact, recordID: id, existing: entry, title: entry.title, path: entry.path, kind: .update))
    }

    mutating func addNewNote(for contact: AppleContact, id: UUID) {
        let title = title(contact)
        let taken = plannedStems
        let stem = Filenames.uniqueStem(title: title, company: values(contact).company?.name) {
            index.isStemTaken($0) || taken.contains($0)
        }
        plannedStems.insert(stem.lowercased())
        let path = VaultPath.join(plan.config.defaultFolder, stem + ".md")
        candidates.append(
            Candidate(apple: contact, recordID: id, existing: nil, title: title, path: path, kind: .create))
    }
}
