public import ContactModel
public import Foundation
public import VaultIndex

/// What a sync run reads before planning, shared by `VaultSession` (CLI and
/// app) and the test harness so both take the same path.
public struct GatheredSync: Sendable {
    /// Counts `device` among the vault's devices (its own record is written
    /// only after its first sync).
    public func including(_ device: DeviceIdentity) -> GatheredSync {
        var copy = self
        copy.inputs.deviceIDs = Array(Set(inputs.deviceIDs + [device.id])).sorted()
        return copy
    }

    public var inputs: SyncInputs
    public var index: VaultIndex
    public var decisions: [Decision]
    /// Unreadable decision-log lines.
    public var decisionProblems: [String]
    /// How Apple Contacts was read (full snapshot or incremental), and what
    /// `AppleChangeTracker.commit` remembers after the run.
    public var apple: AppleRead
}

/// How `SyncPlanner.gather` reads Apple Contacts.
public enum AppleSource: Sendable {
    /// A plain full snapshot (no cache, no token).
    case snapshot(any ContactStore)
    /// Through the change tracker (history acceleration, architecture §10).
    case tracked(AppleReadRequest)

    /// The store read.
    public var store: any ContactStore {
        switch self {
        case .snapshot(let store): store
        case .tracked(let request): request.tracker.store
        }
    }
}

extension AppleSource {
    /// What a tracked read needs to choose between incremental and full
    /// (`nil` for a plain snapshot).
    func readContext(
        records: RecordMap, vaultTouched: Set<UUID>, settingsKey: String, vanished: [UUID: Date], now: Date
    ) -> AppleReadContext? {
        guard case .tracked(let request) = self else { return nil }
        return AppleReadContext(
            records: records, vaultTouchedRecords: vaultTouched, settingsKey: settingsKey, vanished: vanished,
            now: now, deleteConfirmInterval: request.deleteConfirmInterval,
            notesExpected: try? store.capabilities.notesAvailable)
    }
}

/// A tracked Apple read: the tracker, the mode, and why a full read was asked for.
public struct AppleReadRequest: Sendable {
    public var tracker: AppleChangeTracker
    public var mode: AppleReadMode
    public var fullReason: FullSnapshotReason
    /// The delete rail's confirmation interval (a due confirmation forces a full read).
    public var deleteConfirmInterval: TimeInterval

    /// Creates a request.
    public init(
        tracker: AppleChangeTracker, mode: AppleReadMode, fullReason: FullSnapshotReason = .requested,
        deleteConfirmInterval: TimeInterval = SyncOptions().deleteConfirmInterval
    ) {
        self.tracker = tracker
        self.mode = mode
        self.fullReason = fullReason
        self.deleteConfirmInterval = deleteConfirmInterval
    }
}

extension SyncPlanner {
    /// Scans the vault, snapshots Apple, and loads this device's state.
    public static func gather(
        fs: any VaultFS, store: any ContactStore, state: any SyncStateStore,
        config loaded: (config: VaultConfig, text: String?), now: Date
    ) throws -> GatheredSync {
        try gather(fs: fs, state: state, config: loaded, now: now, apple: .snapshot(store))
    }

    /// Scans the vault, reads Apple as `apple` says (history-accelerated
    /// through a tracker, architecture §10, or a plain full snapshot), and
    /// loads this device's state.
    ///
    /// `notes` says how this run handles Contacts notes (`source` set: the
    /// store reads them); `freshStart` is filled in from this device's
    /// state, and a run whose notes read failed is turned into a skipped one.
    ///
    /// Accounts this device saw with cards that are not visible now (turned
    /// off, removed, or in a partial state) are put back as last seen
    /// (`AccountGuard`, architecture §9) before anything is planned; `keyer`
    /// lets returned cards be matched by phone as well as by email.
    ///
    /// `progress` hears each phase as it starts (with last run's counts);
    /// `timer` measures them (`decisions`, `scan`, `state`, `contacts`,
    /// `contact-notes`, `accounts`, `files`).
    public static func gather(
        fs: any VaultFS, state: any SyncStateStore, config loaded: (config: VaultConfig, text: String?), now: Date,
        apple: AppleSource, notes: NotesStatus = .off, keyer: (any PhoneKeyer)? = nil,
        progress: @Sendable (SyncPhase) -> Void = { _ in }, timer: PhaseTimer = PhaseTimer()
    ) throws -> GatheredSync {
        let (config, configText) = loaded
        let store = apple.store
        let (decisions, problems) = try timer.measure("decisions") { try DecisionLog.readAll(fs) }
        let previousCache = try state.loadFileCache()
        progress(.scanningNotes(count: previousCache.isEmpty ? nil : previousCache.count))
        let index = try timer.measure("scan") {
            try VaultIndex.scan(
                fs, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths, cache: previousCache)
        }
        var records = try timer.measure("state") { try state.load() }
        let vanished = try state.loadVanished()
        let previousAccounts = AccountGuard.load(from: state)
        var context = apple.readContext(
            records: records, vaultTouched: changedRecords(before: previousCache, after: index.fileCache),
            settingsKey: AppleChangeTracker.settingsKey(configText: configText, decisions: decisions),
            vanished: vanished, now: now)
        context?.exemptRecords = AccountGuard.frozenRecords(previousAccounts, records: records)
        var read = try readApple(apple, context: context, state: state, progress: progress, timer: timer)
        // The mirror is read only when an account newly went missing (its
        // cards are frozen from it); it is still the one before this run.
        let tracker = AppleChangeTracker(store: store, state: state, deviceID: "")
        let (accounts, augmented) = try timer.measure("accounts") {
            try guardAccounts(
                &read, apple: apple, context: context,
                observation: AccountObservation(
                    snapshot: read.snapshot, previous: previousAccounts, records: records,
                    mirror: { tracker.loadCache() }, decisions: DecisionSet(decisions), now: now, keyer: keyer))
        }
        records = accounts.rebind(records)
        let snapshot = read.snapshot
        let writable = ((try? store.capabilities.writableContainerIDs) ?? snapshot.containers.map(\.id)).filter(
            accounts.isWritable)
        var export = ExportInputs(
            snapshot: snapshot, index: index, records: records, config: config, configText: configText,
            decisions: DecisionSet(decisions), reportedProblems: try state.reportedProblemHashes(), now: now)
        export.knownGroups = try state.loadGroups()
        var inputs = SyncInputs(
            export: export, unapplyable: try state.loadUnapplyable(), vanished: vanished,
            knownMissingNotes: try knownMissingNotes(state), writableContainerIDs: writable,
            deviceIDs: DeviceRecord.deviceIDs(fs: fs))
        inputs.files = try timer.measure("files") { try nonNoteFiles(fs) }
        inputs.imageHashes = try state.loadImageHashes()
        inputs.appleSnapshotComplete = read.isComplete
        inputs.notes = NotesSyncState.status(notes, read: snapshot, state: state)
        inputs.accounts = accounts
        inputs.frozenCardIDs = augmented.frozenCardIDs
        inputs.ghostRecords = augmented.ghostRecords
        inputs.frozenContacts = augmented.frozenContacts
        return GatheredSync(
            inputs: inputs, index: index, decisions: decisions, decisionProblems: problems, apple: read)
    }

    /// `readApple`, reported (with last run's card count) and timed; the
    /// Contacts notes read inside it is its own phase.
    private static func readApple(
        _ apple: AppleSource, context: AppleReadContext?, state: any SyncStateStore,
        progress: @Sendable (SyncPhase) -> Void, timer: PhaseTimer
    ) throws -> AppleRead {
        progress(.readingContacts(cards: try state.lastCardCount()))
        let bridge = apple.store as? NotesBridgedStore
        let notesBefore = bridge?.log.readSeconds ?? 0
        let read = try withoutActuallyEscaping(progress) { progress in
            bridge?.onNotesRead = { progress(.readingContactNotes) }
            defer { bridge?.onNotesRead = nil }
            return try timer.measure("contacts") { try readApple(apple, context: context) }
        }
        timer.split("contact-notes", seconds: (bridge?.log.readSeconds ?? 0) - notesBefore, outOf: "contacts")
        try state.saveLastCardCount(read.snapshot.contacts.reduce(0) { $0 + $1.cards.count })
        return read
    }

    /// Apple Contacts as `apple` says: a plain full snapshot, or through the tracker.
    private static func readApple(_ apple: AppleSource, context: AppleReadContext?) throws -> AppleRead {
        switch apple {
        case .snapshot(let store):
            return .full(try store.snapshot())
        case .tracked(let request):
            guard let context else { return .full(try request.tracker.store.snapshot()) }
            return try request.tracker.read(mode: request.mode, context: context, fullReason: request.fullReason)
        }
    }

    /// The unavailable-accounts guard (architecture §9): evaluated on the
    /// read (re-read in full when an account went missing, came back or was
    /// forgotten on an incremental read), with frozen cards put back into
    /// `read.snapshot` (the mirror keeps what Contacts really holds).
    private static func guardAccounts(
        _ read: inout AppleRead, apple: AppleSource, context: AppleReadContext?, observation: AccountObservation
    ) throws -> (AccountGuard, AugmentedSnapshot) {
        var observation = observation
        var accounts = AccountGuard.evaluate(observation)
        if accounts.transitioned, !read.isComplete, case .tracked(let request) = apple, let context {
            read = try request.tracker.read(mode: .full, context: context, fullReason: .accountsChanged)
            observation.snapshot = read.snapshot
            accounts = AccountGuard.evaluate(observation)
        }
        let augmented = accounts.augment(read.snapshot)
        if accounts.isActive || !accounts.hiddenCardIDs.isEmpty {
            read.mirrorSnapshot = read.snapshot
            read.snapshot = augmented.snapshot
        }
        return (accounts, augmented)
    }

    /// Records whose note was already missing (not counted again by the
    /// breaker): queued as "note deleted", or remembered by an earlier run.
    private static func knownMissingNotes(_ state: any SyncStateStore) throws -> Set<UUID> {
        try state.loadKnownMissingNotes().union(
            try state.loadPending().items.compactMap { entry -> UUID? in
                switch entry.item {
                case .markdownDeleted(_, let id, _, _), .missingFile(_, let id, _): id
                default: nil
                }
            })
    }

    /// Non-markdown files (images) by path.
    private static func nonNoteFiles(_ fs: any VaultFS) throws -> [String: FileEntry] {
        let isNote = { (path: String) in
            path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".markdown")
        }
        return Dictionary(
            try fs.enumerate().filter { !isNote($0.path) }.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Records whose note changed (content, new, or gone) since the cached scan.
    static func changedRecords(before: [String: FileCacheEntry], after: [String: FileCacheEntry]) -> Set<UUID> {
        var ids = Set<UUID>()
        for path in Set(before.keys).union(after.keys) {
            let (old, new) = (before[path], after[path])
            guard old?.sha256 != new?.sha256 || old?.syncID != new?.syncID else { continue }
            if let id = old?.syncID { ids.insert(id) }
            if let id = new?.syncID { ids.insert(id) }
        }
        return ids
    }

    /// `true` when the plan would create a note for a contact whose image
    /// was not re-read (incremental runs): re-plan on a full snapshot so the
    /// note gets its image.
    public static func needsImages(_ plan: SyncPlan, read: AppleRead) -> Bool {
        guard !read.isComplete, !read.maskedCards.isEmpty else { return false }
        return plan.markdown.creates.contains { change in
            plan.markdown.bindings[change.recordID]?.cards.contains { read.maskedCards.contains($0.id) } ?? false
        }
    }

    /// Saves what planning observed: the review queue, the file cache, the
    /// notes known missing and the problems now reported.
    ///
    /// A run stopped by the breaker leaves the review queue (and, for its
    /// side, the notes known missing) as they were: the records it saw
    /// vanish are neither queued for a decision nor treated as already
    /// known by the next run.
    public static func recordObservations(
        _ plan: SyncPlan, index: VaultIndex, state: any SyncStateStore, now: Date,
        written: [String: FileCacheEntry] = [:]
    ) throws {
        try state.saveFileCache(index.fileCache.merging(written) { _, new in new })
        try state.saveImageHashes(plan.imageHashes)
        try plan.accountGuard.save(executed: false, in: state)
        if let known = plan.knownMissingNotes { try state.saveKnownMissingNotes(known) }
        if plan.breaker == nil {
            try state.savePending(try state.loadPending().replacing(with: plan.markdown.reviews, at: now))
        }
        try state.markProblemsReported(
            Dictionary(
                plan.markdown.newProblems.map { ($0.sha256, $0.path) }, uniquingKeysWith: { first, _ in first }))
    }
}

extension SyncEngine {
    /// `com.zmre.contacts2mdsync.<deviceID>`: the `transactionAuthor` of our
    /// Apple writes (excluded from change history in M5).
    public static func transactionAuthor(deviceID: String) -> String { transactionAuthorPrefix + deviceID }
}

/// Where a sync run is (for status displays), with the counts known when
/// the phase starts (from this device's previous run).
public enum SyncPhase: Hashable, Sendable {
    /// Waiting for another run on this Mac (local lock) or taking the lease.
    case waitingForLock
    /// Starting: reading the folder's settings and this Mac's state.
    case scanning
    /// Scanning the notes folder (`count`: notes seen last time).
    case scanningNotes(count: Int?)
    /// Reading Apple Contacts (`cards`: cards seen last time).
    case readingContacts(cards: Int?)
    /// Reading Contacts notes through Contacts.app scripting.
    case readingContactNotes
    case planning
    /// Backing up, writing Contacts and notes.
    case writing

    /// `scanning-notes`, `reading-contacts`, … (the `watch` status line).
    public var name: String {
        switch self {
        case .waitingForLock: "waiting-for-lock"
        case .scanning: "scanning"
        case .scanningNotes: "scanning-notes"
        case .readingContacts: "reading-contacts"
        case .readingContactNotes: "reading-contact-notes"
        case .planning: "planning"
        case .writing: "writing"
        }
    }

    /// "Reading Contacts (3,781 cards)…", "Scanning notes (2,447)…", …
    public var text: String {
        switch self {
        case .waitingForLock: "Waiting for the current sync to finish…"
        case .scanning: "Reading…"
        case .scanningNotes(let count): "Scanning notes\(Self.count(count, nil))…"
        case .readingContacts(let cards): "Reading Contacts\(Self.count(cards, "cards"))…"
        case .readingContactNotes: "Reading notes from Contacts…"
        case .planning: "Planning…"
        case .writing: "Writing…"
        }
    }

    private static func count(_ count: Int?, _ noun: String?) -> String {
        guard let count, count > 0 else { return "" }
        return " (\(count.formatted())\(noun.map { " \($0)" } ?? ""))"
    }
}
