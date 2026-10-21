public import ContactModel
public import Foundation
public import SyncEngine
public import VaultIndex

/// What to plan or export.
public struct ExportRequest: Hashable, Sendable {
    /// Folder for new notes (saved into `.c2mdsync/config.yaml`).
    public var defaultFolder: String?
    /// Region for phone numbers without a country code (saved into the config).
    public var region: String?
    public var restoreMissing: Bool
    /// See `ExportOptions.autoAdopt`.
    public var autoAdopt: AutoAdopt
    public var allowUndownloaded: Bool

    /// Creates a request.
    public init(
        defaultFolder: String? = nil, region: String? = nil, restoreMissing: Bool = false,
        autoAdopt: AutoAdopt = .firstImport,
        allowUndownloaded: Bool = false
    ) {
        self.defaultFolder = defaultFolder
        self.region = region
        self.restoreMissing = restoreMissing
        self.autoAdopt = autoAdopt
        self.allowUndownloaded = allowUndownloaded
    }
}

/// A plan plus everything needed to execute it.
public struct PreparedExport: Sendable {
    public let fs: any VaultFS
    public let store: any ContactStore
    public let state: any SyncStateStore
    /// `false` for a dry run on a vault that was never exported to (the
    /// state is in memory and discarded).
    public let statePersistent: Bool
    public let stateDirectory: URL
    public let snapshot: AppleSnapshot
    public let index: VaultIndex
    public let decisions: [Decision]
    public let decisionProblems: [String]
    public let plan: ExportPlan
    /// `true` when the vault had no `.c2mdsync/config.yaml` yet.
    public let firstExport: Bool
}

/// What executing a prepared export did.
public struct ExportOutcome: Sendable {
    public var result: ExportResult
    public var backup: BackupReceipt?
    /// Stamps that were saved.
    public var stampedRequests: [StampRequest] = []
    public var stampFailures: [String] = []

    /// Number of contacts stamped.
    public var stamped: Int { stampedRequests.count }
}

/// What this device's state says about a configured vault (no Contacts access needed).
public struct StoredStatus: Hashable, Sendable {
    /// Last export or sync on this device.
    public var lastExport: Date?
    public var records: Int
    /// Pending items that need a decision (markdown-only notes excluded).
    public var pendingReview: Int
    /// When the pending queue was computed.
    public var pendingAsOf: Date?
    /// `apple_writes: enabled` in the vault config.
    public var appleWritesEnabled = false
    /// `stamp_contacts: true` in the vault config.
    public var stampContacts = false
    /// Devices that ever synced this vault.
    public var deviceCount = 1
    /// Set when several devices share the vault without stamps.
    public var identityWarning: String?
    /// Open field conflicts.
    public var conflicts = 0
    /// Queued deletions (deleted in Contacts + notes deleted).
    public var pendingDeletes = 0
    /// Markdown-only notes awaiting review (informational).
    public var markdownOnly = 0
    /// The current vault lease, if any.
    public var lease: VaultLease?
}

/// One planning/export run against a notes root, shared by the CLI and the
/// app so both follow exactly the same path (architecture §15 "Shared
/// engine guarantees").
public struct VaultSession: Sendable {
    public let root: URL
    public let environment: CLIEnvironment

    /// Creates a session for `root`.
    public init(root: URL, environment: CLIEnvironment) {
        self.root = root
        self.environment = environment
    }

    /// Opens the vault, Contacts and the device state, scans, and plans.
    /// With `forWriting == false` on a never-exported vault nothing is
    /// created on disk (not even the state database).
    public func prepare(_ request: ExportRequest, forWriting: Bool) throws -> PreparedExport {
        let fs = environment.makeVault(root)
        let store = try environment.makeStore()
        let loaded = try VaultConfig.load(from: fs)
        let config = try configuredVault(loaded?.config, request: request)
        let stateDirectory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        let persistent = loaded != nil || forWriting
        let state: any SyncStateStore =
            persistent ? try environment.makeStateStore(stateDirectory) : InMemorySyncStateStore()
        let (decisions, decisionProblems) = try DecisionLog.readAll(fs)
        if persistent { try state.saveDecisionMirror(decisions) }
        let index = try VaultIndex.scan(
            fs, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths,
            cache: try state.loadFileCache())
        let keyer = environment.makeKeyer(config.defaultRegion ?? environment.fallbackRegion)
        let planner = ExportPlanner(
            fs: fs, keyer: keyer, ids: environment.ids,
            options: ExportOptions(
                restoreMissing: request.restoreMissing, autoAdopt: request.autoAdopt,
                allowUndownloaded: request.allowUndownloaded))
        let snapshot = try store.snapshot()
        var plan = try planner.plan(
            ExportInputs(
                snapshot: snapshot, index: index, records: try state.load(), config: config,
                configText: loaded?.text, decisions: DecisionSet(decisions),
                reportedProblems: try state.reportedProblemHashes(), now: environment.clock.now))
        // Command-line options changed the config even if groups did not.
        if let loaded, config != loaded.config, plan.configText == nil {
            plan.configText = plan.config.render(patching: loaded.text)
        }
        return PreparedExport(
            fs: fs, store: store, state: state, statePersistent: persistent, stateDirectory: stateDirectory,
            snapshot: snapshot, index: index, decisions: decisions, decisionProblems: decisionProblems, plan: plan,
            firstExport: loaded == nil)
    }

    /// Last export, record count and pending review items for the vault at
    /// the root, or `nil` when it was never exported to (nothing is created).
    public func storedStatus() throws -> StoredStatus? {
        let fs = environment.makeVault(root)
        guard let config = try VaultConfig.load(from: fs)?.config else { return nil }
        let directory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return StoredStatus(lastExport: nil, records: 0, pendingReview: 0, pendingAsOf: nil)
        }
        let state = try environment.makeStateStore(directory)
        let records = try state.load()
        let pending = try state.loadPending()
        var status = StoredStatus(
            lastExport: records.lastExport, records: records.records.count,
            pendingReview: pending.items.filter(\.item.needsDecision).count, pendingAsOf: pending.computedAt)
        status.appleWritesEnabled = config.appleWrites
        status.stampContacts = config.stampContacts
        let devices = DeviceRecord.deviceIDs(fs: fs)
        status.deviceCount = max(devices.count, 1)
        if devices.count > 1, !config.stampContacts {
            status.identityWarning =
                "\(devices.count) devices share this vault; enable stamp_contacts so devices agree on identity"
        }
        for entry in pending.items {
            switch entry.item {
            case .conflict: status.conflicts += 1
            case .appleDeleted, .markdownDeleted, .missingFile: status.pendingDeletes += 1
            case .markdownOnly: status.markdownOnly += 1
            default: break
            }
        }
        if let device = try? environment.device() {
            status.lease = LeaseManager(fs: fs, device: device, clock: environment.clock).read()
        }
        return status
    }

    /// Records what a dry run found: pending review queue, file cache, and
    /// problems now reported (no-op for in-memory state).
    public func recordPlan(_ prepared: PreparedExport, command: String, startedAt: Date) throws {
        guard prepared.statePersistent else { return }
        try saveObservations(prepared)
        try prepared.state.appendSession(
            session(prepared, command: command, startedAt: startedAt, result: nil, stamped: 0))
    }

    /// Writes the plan: optional vCard backup (required for stamping), note
    /// pre-image backups, notes, then stamps when asked; then saves state.
    public func execute(
        _ prepared: PreparedExport, backupContacts: Bool, stamp: Bool, command: String, startedAt: Date,
        onBackup: (BackupReceipt) -> Void = { _ in }
    ) throws -> ExportOutcome {
        let plan = prepared.plan
        let backups = prepared.stateDirectory.appending(path: "backups")
        // Backup comes first: if it fails, nothing at all is written.
        var receipt: BackupReceipt?
        if backupContacts || (stamp && !plan.stamps.isEmpty) {
            do {
                receipt = try VCardBackup(directory: backups, clock: environment.clock).backup(prepared.store)
            } catch {
                throw BackupFailed(underlying: error)
            }
            receipt.map(onBackup)
        }
        let result = try ExportExecutor(
            fs: prepared.fs, records: prepared.state, clock: environment.clock,
            noteBackups: NoteBackup(directory: backups, clock: environment.clock)
        )
        .execute(plan)
        var outcome = ExportOutcome(result: result, backup: receipt)
        if stamp, let receipt {
            let written = Set(plan.bindings.keys).subtracting(result.failedRecordIDs(in: plan))
            let requests = plan.stamps.filter { written.contains($0.recordID) }
            let applied = try Stamper.stamp(
                requests, in: prepared.store, backup: receipt, author: SyncEngine.transactionAuthorPrefix + "cli")
            let done = Set(applied.applied)
            outcome.stampedRequests = requests.filter { done.contains(.stamp(cardID: $0.cardID, id: $0.recordID)) }
            outcome.stampFailures = applied.failed.map { "\($0.operation) failed: \($0.message)" }
        }
        try saveObservations(prepared, writtenCache: result.writtenCache)
        try prepared.state.saveGroups(
            prepared.snapshot.groups.map {
                GroupBinding(
                    groupID: $0.id, containerID: $0.containerID, name: $0.name, tag: plan.config.tag(forGroup: $0.name))
            })
        try prepared.state.appendSession(
            session(prepared, command: command, startedAt: startedAt, result: result, stamped: outcome.stamped))
        return outcome
    }

    private func saveObservations(_ prepared: PreparedExport, writtenCache: [String: FileCacheEntry] = [:]) throws {
        let state = prepared.state
        try state.saveFileCache(prepared.index.fileCache.merging(writtenCache) { _, written in written })
        try state.savePending(
            try state.loadPending().replacing(with: prepared.plan.reviews, at: environment.clock.now))
        try state.markProblemsReported(
            Dictionary(prepared.plan.newProblems.map { ($0.sha256, $0.path) }, uniquingKeysWith: { first, _ in first }))
    }

    private func session(
        _ prepared: PreparedExport, command: String, startedAt: Date, result: ExportResult?, stamped: Int
    ) -> SessionRecord {
        let plan = prepared.plan
        let adopted = result?.updated.filter { $0.kind == .adopt }.count ?? plan.adoptions.count
        return SessionRecord(
            startedAt: startedAt, finishedAt: environment.clock.now, command: command, trigger: environment.trigger,
            deviceID: (try? environment.device().id) ?? "", created: result?.created.count ?? 0,
            updated: (result?.updated.count ?? 0) - (result == nil ? 0 : adopted), adopted: result == nil ? 0 : adopted,
            unchanged: plan.unchanged, skipped: plan.skipped.count, pendingReview: plan.reviews.count,
            stamped: stamped, failures: result?.failures.count ?? 0)
    }

    /// The vault config with request overrides applied (new vault: fresh id).
    private func configuredVault(_ existing: VaultConfig?, request: ExportRequest) throws -> VaultConfig {
        var config = existing ?? VaultConfig(vaultID: environment.ids.next())
        let settings = RootBookmark(directory: environment.stateDirectory).loadSettings()
        if let folder = request.defaultFolder ?? (existing == nil ? settings.defaultFolder : nil) {
            try VaultPath.validate(folder)
            config.defaultFolder = folder
        }
        if let region = request.region { config.defaultRegion = region.uppercased() }
        if config.defaultRegion == nil { config.defaultRegion = environment.fallbackRegion.uppercased() }
        return config
    }
}

/// The vCard backup failed; nothing was written.
public struct BackupFailed: Error, CustomStringConvertible {
    public let underlying: any Error
    public var description: String { "vCard backup failed (\(underlying)); nothing written, no contacts stamped" }
}

extension ExportResult {
    /// Record ids whose note write failed.
    func failedRecordIDs(in plan: ExportPlan) -> Set<UUID> {
        let failedPaths = Set(failures.map(\.path))
        return Set((plan.creates + plan.updates).filter { failedPaths.contains($0.path) }.map(\.recordID))
    }
}
