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
    public static func gather(
        fs: any VaultFS, state: any SyncStateStore, config loaded: (config: VaultConfig, text: String?), now: Date,
        apple: AppleSource, notes: NotesStatus = .off, keyer: (any PhoneKeyer)? = nil
    ) throws -> GatheredSync {
        let (config, configText) = loaded
        let store = apple.store
        let (decisions, problems) = try DecisionLog.readAll(fs)
        let previousCache = try state.loadFileCache()
        let index = try VaultIndex.scan(
            fs, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths, cache: previousCache)
        var records = try state.load()
        let vanished = try state.loadVanished()
        let previousAccounts = AccountGuard.load(from: state)
        var context: AppleReadContext?
        if case .tracked(let request) = apple {
            var tracked = AppleReadContext(
                records: records,
                vaultTouchedRecords: changedRecords(before: previousCache, after: index.fileCache),
                settingsKey: AppleChangeTracker.settingsKey(configText: configText, decisions: decisions),
                vanished: vanished, now: now, deleteConfirmInterval: request.deleteConfirmInterval,
                notesExpected: try? store.capabilities.notesAvailable)
            tracked.exemptRecords = AccountGuard.frozenRecords(previousAccounts, records: records)
            context = tracked
        }
        var read = try readApple(apple, context: context)
        // The mirror is read only when an account newly went missing (its
        // cards are frozen from it); it is still the one before this run.
        let tracker = AppleChangeTracker(store: store, state: state, deviceID: "")
        let (accounts, augmented) = try guardAccounts(
            &read, apple: apple, context: context,
            observation: AccountObservation(
                snapshot: read.snapshot, previous: previousAccounts, records: records,
                mirror: { tracker.loadCache() }, decisions: DecisionSet(decisions), now: now, keyer: keyer))
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
        inputs.files = try nonNoteFiles(fs)
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

    /// Records already queued as "note deleted" (not counted again by the breaker).
    private static func knownMissingNotes(_ state: any SyncStateStore) throws -> Set<UUID> {
        Set(
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

    /// Saves what planning observed: the review queue, the file cache and
    /// the problems now reported.
    public static func recordObservations(
        _ plan: SyncPlan, index: VaultIndex, state: any SyncStateStore, now: Date,
        written: [String: FileCacheEntry] = [:]
    ) throws {
        try state.saveFileCache(index.fileCache.merging(written) { _, new in new })
        try state.saveImageHashes(plan.imageHashes)
        try plan.accountGuard.save(executed: false, in: state)
        try state.savePending(try state.loadPending().replacing(with: plan.markdown.reviews, at: now))
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

/// Where a sync run is (for status displays).
public enum SyncPhase: String, Hashable, Sendable, Codable {
    /// Waiting for another run on this Mac (local lock) or taking the lease.
    case waitingForLock = "waiting-for-lock"
    /// Scanning the vault and reading Apple Contacts.
    case scanning
    case planning
    /// Backing up, writing Contacts and notes.
    case writing
}
