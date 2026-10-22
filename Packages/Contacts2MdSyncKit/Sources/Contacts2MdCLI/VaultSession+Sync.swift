public import ContactModel
public import Foundation
public import SyncEngine
public import VaultIndex

/// What to sync.
public struct SyncRequest: Hashable, Sendable {
    /// Overrides `limits.max_apple_changes_without_approval` for this run.
    public var maxAppleChanges: Int?
    /// Proceed although the mass-vanish breaker would trip (deletes are still only queued).
    public var allowMassVanish: Bool
    /// Create new notes although some notes are undownloaded iCloud placeholders.
    public var allowUndownloaded: Bool
    /// Take the vault lease from another device.
    public var takeOverLease: Bool
    public var policy: DecisionPolicy
    /// `.incremental` (default): use the Contacts change-history token when
    /// it is valid, else a full snapshot. `.full`: always a full snapshot.
    public var appleMode: AppleReadMode

    /// Creates a request.
    public init(
        maxAppleChanges: Int? = nil, allowMassVanish: Bool = false, allowUndownloaded: Bool = false,
        takeOverLease: Bool = false, policy: DecisionPolicy = .headless, appleMode: AppleReadMode = .incremental
    ) {
        self.maxAppleChanges = maxAppleChanges
        self.allowMassVanish = allowMassVanish
        self.allowUndownloaded = allowUndownloaded
        self.takeOverLease = takeOverLease
        self.policy = policy
        self.appleMode = appleMode
    }
}

/// A two-way plan plus everything needed to execute it.
public struct PreparedSync: Sendable {
    public let fs: any VaultFS
    public let store: any ContactStore
    public let state: any SyncStateStore
    public let stateDirectory: URL
    public let index: VaultIndex
    public let decisions: [Decision]
    public let decisionProblems: [String]
    public let config: VaultConfig
    public let plan: SyncPlan
    /// How Apple Contacts was read (full snapshot or history-incremental).
    public let apple: AppleRead
    let tracker: AppleChangeTracker
    /// The notes side of the run (provider session, bridge log).
    public let notes: NotesRunHandle

    /// The Apple snapshot the plan was made from (read-only; no second read
    /// of Contacts needed for review details). After an incremental read it
    /// is the cached snapshot patched with the re-read contacts, and images
    /// of contacts that were not re-read have no bytes (`imageUnavailable`).
    public var snapshot: AppleSnapshot { apple.snapshot }
}

/// How many records' bodies moved in a run.
struct NotesCounts {
    var toContacts: Int
    var toMarkdown: Int

    init(_ result: SyncResult) {
        toContacts = result.apple.filter { $0.kind == .update && $0.fields.contains("body") }.count
        toMarkdown = result.markdown.updated.filter { $0.changedFields.contains("body") }.count
    }

    init(planned plan: SyncPlan) {
        toContacts =
            plan.appleWritesAllowed ? plan.apple.filter { $0.kind == .update && $0.fields.contains("body") }.count : 0
        toMarkdown = plan.markdown.updates.filter { $0.changedFields.contains("body") }.count
    }
}

/// Why a sync did not start.
public enum SyncGate: Sendable {
    /// Lock and lease are ours; call `release()` on the lock when done.
    case ready(LocalLock, VaultLease)
    /// Another run on this Mac holds the local lock (waited `lockWait`).
    case localRunInProgress
    /// Another device leads this vault.
    case leaseHeldElsewhere(VaultLease)
}

/// The vault has not been exported/synced on this device yet (exit 3).
public struct VaultNotReady: Error, CustomStringConvertible {
    public let description: String
}

extension VaultSession {
    /// The vault's config and this device's state folder (throws `VaultNotReady`).
    struct ConfiguredVault {
        var config: VaultConfig
        var text: String
        var directory: URL
    }

    func configured(_ fs: any VaultFS) throws -> ConfiguredVault {
        guard let (config, text) = try VaultConfig.load(from: fs) else {
            throw VaultNotReady(
                description:
                    "not configured: run the first sync in Contacts2MdSync (or `contacts2md export --yes`) once")
        }
        let directory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        return ConfiguredVault(config: config, text: text, directory: directory)
    }

    /// Takes the local run lock (waiting up to `environment.lockWait`) and
    /// the vault lease (architecture §11, §15).
    public func beginSync(takeOver: Bool = false) throws -> SyncGate {
        let fs = environment.makeVault(root)
        let directory = try configured(fs).directory
        guard
            let lock = try LocalLock.acquire(
                at: directory.appending(path: "sync.lock"), wait: environment.lockWait, sleep: environment.sleep)
        else { return .localRunInProgress }
        let device = try environment.device()
        let others = DeviceRecord.deviceIDs(fs: fs).contains { $0 != device.id }
        let leases = LeaseManager(
            fs: fs, device: device, clock: environment.clock, settle: environment.leaseSettle,
            sleep: environment.sleep)
        switch try leases.acquire(takeOver: takeOver, otherDevicesKnown: others) {
        case .acquired(let lease): return .ready(lock, lease)
        case .heldElsewhere(let lease):
            lock.release()
            return .leaseHeldElsewhere(lease)
        }
    }

    /// Scans, snapshots and plans a two-way sync. Requires a vault exported
    /// or synced on this device before (`VaultNotReady` otherwise).
    public func prepareSync(
        _ request: SyncRequest, progress: @Sendable (SyncPhase) -> Void = { _ in }
    ) throws -> PreparedSync {
        progress(.scanning)
        let fs = environment.makeVault(root)
        let vault = try configured(fs)
        let (config, text, directory) = (vault.config, vault.text, vault.directory)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw VaultNotReady(
                description:
                    "first sync not done on this Mac: run it in Contacts2MdSync (or `contacts2md export --yes`) once")
        }
        let notes = notesSetup(for: try environment.makeStore(), backups: directory.appending(path: "backups"))
        let store = notes.store
        let state = try environment.makeStateStore(directory)
        guard try state.load().lastExport != nil else {
            throw VaultNotReady(
                description:
                    "first sync not done on this Mac: run it in Contacts2MdSync (or `contacts2md export --yes`) once")
        }
        let device = try environment.device()
        let tracker = AppleChangeTracker(store: store, state: state, deviceID: device.id)
        let keyer = environment.makeKeyer(config.defaultRegion ?? environment.fallbackRegion)
        let options = SyncOptions(
            export: ExportOptions(autoAdopt: .never, allowUndownloaded: request.allowUndownloaded),
            policy: request.policy, maxAppleChanges: request.maxAppleChanges,
            allowMassVanish: request.allowMassVanish)
        var mode = request.appleMode
        var fullReason = FullSnapshotReason.requested
        while true {
            var gathered = try SyncPlanner.gather(
                fs: fs, state: state, config: (config, text), now: environment.clock.now,
                apple: .tracked(
                    AppleReadRequest(
                        tracker: tracker, mode: mode, fullReason: fullReason,
                        deleteConfirmInterval: options.deleteConfirmInterval)),
                notes: notes.status)
            if gathered.inputs.notes.skipped != nil, let log = notes.handle.bridge?.log {
                gathered.inputs.notes.skipped = Self.skipWarning(log) ?? gathered.inputs.notes.skipped
            }
            try state.saveDecisionMirror(gathered.decisions)
            progress(.planning)
            let plan = try SyncPlanner(fs: fs, keyer: keyer, ids: environment.ids, options: options).plan(
                gathered.including(device).inputs)
            if SyncPlanner.needsImages(plan, read: gathered.apple) {
                (mode, fullReason) = (.full, .imagesNeeded)
                continue
            }
            return PreparedSync(
                fs: fs, store: store, state: state, stateDirectory: directory, index: gathered.index,
                decisions: gathered.decisions, decisionProblems: gathered.decisionProblems, config: config,
                plan: plan, apple: gathered.apple, tracker: tracker, notes: notes.handle)
        }
    }

    /// When a sync on this device was last planned on a full Apple snapshot
    /// (by the app or the CLI); `nil` when never or not configured.
    public func lastFullCompare() -> Date? {
        let fs = environment.makeVault(root)
        guard let directory = try? configured(fs).directory,
            FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)),
            let state = try? environment.makeStateStore(directory)
        else { return nil }
        return AppleChangeTracker.lastFullCompare(in: state)
    }

    /// Records what a dry run found (review queue, file cache). The Apple
    /// mirror advances too (it describes Contacts, not what was synced),
    /// unless a breaker tripped.
    public func recordSyncPlan(_ prepared: PreparedSync, command: String, startedAt: Date) throws {
        defer { prepared.notes.finish() }
        try SyncPlanner.recordObservations(
            prepared.plan, index: prepared.index, state: prepared.state, now: environment.clock.now)
        if prepared.plan.breaker == nil {
            try prepared.tracker.commit(prepared.apple, postWrite: nil, compared: false, now: environment.clock.now)
        }
        try prepared.state.appendSession(
            syncSession(prepared, command: command, startedAt: startedAt, result: nil))
    }

    /// Executes a prepared sync: vCard backup (only when Apple writes
    /// happen), Apple batch, markdown writes, state. Throws
    /// `SyncError.breakerTripped` (nothing written) or `BackupFailed`.
    public func executeSync(
        _ prepared: PreparedSync, command: String, startedAt: Date, onBackup: (BackupReceipt) -> Void = { _ in }
    ) throws -> SyncResult {
        defer { prepared.notes.finish() }
        let device = try environment.device()
        let backups = prepared.stateDirectory.appending(path: "backups")
        let executor = SyncExecutor(
            fs: prepared.fs, store: prepared.store, state: prepared.state, clock: environment.clock,
            noteBackups: NoteBackup(directory: backups, clock: environment.clock),
            author: SyncEngine.transactionAuthor(deviceID: device.id))
        let result = try executor.execute(prepared.plan) {
            let receipt: BackupReceipt
            do {
                receipt = try VCardBackup(directory: backups, clock: environment.clock).backup(prepared.store)
            } catch {
                throw BackupFailed(underlying: error)
            }
            onBackup(receipt)
            return receipt
        }
        try SyncPlanner.recordObservations(
            prepared.plan, index: prepared.index, state: prepared.state, now: environment.clock.now,
            written: result.markdown.writtenCache)
        try prepared.tracker.commit(
            prepared.apple, postWrite: result.postWriteSnapshot.map { ($0, result.postWriteHistoryToken) },
            compared: prepared.apple.isComplete, now: environment.clock.now)
        let changes = SessionChange.log(result)
        let record = syncSession(prepared, command: command, startedAt: startedAt, result: result)
        try prepared.state.appendSession(record, changes: changes)
        try prepared.state.rememberRenames(prepared.plan, result: result)
        let summary =
            "apple \(result.apple.count) changes, md \(result.markdown.created.count + result.markdown.updated.count) "
            + "writes, \(prepared.plan.markdown.reviews.filter(\.needsDecision).count) pending review"
        try? DeviceRecord.write(
            DeviceRecord(
                deviceID: device.id, deviceName: device.name, lastSync: environment.clock.now, summary: summary),
            fs: prepared.fs)
        _ = try? LeaseManager(fs: prepared.fs, device: device, clock: environment.clock).heartbeat()
        // Only this device writes its decision log: fold in iCloud conflict versions of it.
        try? DecisionLog.mergeConflictVersions(deviceID: device.id, fs: prepared.fs)
        return result
    }

    private func syncSession(
        _ prepared: PreparedSync, command: String, startedAt: Date, result: SyncResult?
    ) -> SessionRecord {
        let plan = prepared.plan
        var record = SessionRecord(
            startedAt: startedAt, finishedAt: environment.clock.now, command: command, trigger: environment.trigger,
            deviceID: (try? environment.device().id) ?? "",
            created: (result?.markdown.created.count ?? 0) + (result?.apple.filter { $0.kind == .create }.count ?? 0),
            updated: (result?.markdown.updated.count ?? 0) + (result?.apple.filter { $0.kind == .update }.count ?? 0),
            adopted: result?.markdown.updated.filter { $0.kind == .adopt }.count ?? 0,
            unchanged: plan.markdown.unchanged, skipped: plan.markdown.skipped.count,
            pendingReview: plan.markdown.reviews.filter(\.needsDecision).count,
            stamped: result?.apple.filter { $0.kind == .stamp }.count ?? 0,
            failures: (result?.markdown.failures.count ?? 0) + (result?.appleFailures.count ?? 0))
        let apple = result?.apple ?? []
        record.sides = SessionSides(
            appleCreated: apple.filter { $0.kind == .create }.count,
            appleUpdated: apple.filter { $0.kind != .create && $0.kind != .delete }.count,
            appleDeleted: apple.filter { $0.kind == .delete }.count,
            markdownCreated: result?.markdown.created.count ?? 0,
            markdownUpdated: result?.markdown.updated.count ?? 0,
            markdownDeleted: result?.trashed.count ?? 0,
            held: plan.appleHold == nil ? 0 : plan.apple.count, heldReason: plan.appleHold?.reason,
            appleRead: prepared.apple.isComplete ? "full" : "incremental")
        record.sides?.notes = plan.notes.source?.rawValue ?? (plan.notes.skipped == nil ? nil : "skipped")
        if plan.notes.isActive, let result {
            let counts = NotesCounts(result)
            record.sides?.notesToContacts = counts.toContacts
            record.sides?.notesToMarkdown = counts.toMarkdown
        }
        return record
    }

    // MARK: - Settings the app and `contacts2md config` change

    /// Changes the vault's sync switches (`apple_writes`, `stamp_contacts`)
    /// in `.c2mdsync/config.yaml`; every other key stays byte-for-byte.
    ///
    ///     try session.updateSettings { $0.appleWrites = true }
    @discardableResult
    public func updateSettings(_ change: (inout VaultConfig) -> Void) throws -> VaultConfig {
        let fs = environment.makeVault(root)
        let vault = try configured(fs)
        var config = vault.config
        change(&config)
        let rendered = config.render(patching: vault.text)
        let text = vault.text
        if rendered != text { _ = try fs.write(Data(rendered.utf8), to: VaultConfig.path, expecting: .any) }
        return config
    }
}
