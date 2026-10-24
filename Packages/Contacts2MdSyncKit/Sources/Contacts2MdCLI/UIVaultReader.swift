internal import ContactModel
public import Foundation
public import SyncEngine
internal import VaultIndex

/// The app's entry point into a vault: reads stored state, plans, exports,
/// and records review decisions — the same code paths as the CLI.
public struct UIVaultReader: Sendable {
    public let root: URL
    public let environment: CLIEnvironment

    /// Creates a reader for `root` (already opened through the bookmark).
    public init(root: URL, environment: CLIEnvironment) {
        self.root = root
        self.environment = environment
    }

    /// Stored state, the decision log and a scan of the folder; `nil` when the
    /// folder was never exported to. Creates nothing on disk.
    public func read() throws -> UIVaultData? {
        let fs = environment.makeVault(root)
        guard let config = try VaultConfig.load(from: fs)?.config else { return nil }
        let directory = stateDirectory(config)
        let device = try environment.device()
        let (decisions, decisionProblems) = try DecisionLog.readAll(fs)
        var records = RecordMap()
        var pending = PendingReviews()
        var sessions: [SessionRecord] = []
        var details: [UISessionDetail] = []
        var cache: [String: FileCacheEntry] = [:]
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            let state = try environment.makeStateStore(directory)
            records = try state.load()
            pending = try state.loadPending()
            sessions = try state.recentSessions(limit: 200)
            details = UISessionDetail.load(state)
            cache = try state.loadFileCache()
        }
        // Sync switches, devices, lease and per-queue counts (as `contacts2md status`).
        let status =
            try VaultSession(root: root, environment: environment).storedStatus()
            ?? StoredStatus(
                lastExport: records.lastExport, records: records.records.count, pendingReview: 0, pendingAsOf: nil)
        let index = try VaultIndex.scan(
            fs, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths, cache: cache)
        let devices = ((try? fs.list(DecisionLog.devicesFolder)) ?? []).filter { !$0.hasPrefix(".") }
        return UIVaultData(
            rootPath: root.path(percentEncoded: false), config: config, status: status, pending: pending,
            decisions: decisions, decisionProblems: decisionProblems, records: records,
            sessions: sessions,
            notes: index.entries.filter(\.isContactNote).map(UINoteSummary.init).sorted { $0.path < $1.path },
            invalidContactNotes: index.problems.filter(\.problemIsContactRelated).map {
                UIProblemNote(path: $0.path, problem: $0.problem ?? "unreadable")
            },
            undownloaded: index.undownloaded.count, device: device, vaultDevices: devices.sorted(),
            stateDirectory: directory, readAt: environment.clock.now, sessionDetails: details)
    }

    /// A dry run (reads Contacts): refreshes the pending review queue and
    /// records a `plan` session, exactly like `contacts2md plan`: the
    /// two-way plan once this Mac has synced or exported, else the export plan.
    ///
    /// `progress` hears each phase as it starts (toolbar status).
    public func plan(progress: @Sendable (SyncPhase) -> Void = { _ in }) throws -> UIPlanSummary {
        let startedAt = environment.clock.now
        let session = VaultSession(root: root, environment: environment)
        guard try hasSynced(session) else {
            progress(.scanning)
            let prepared = try session.prepare(ExportRequest(), forWriting: false)
            try session.recordPlan(prepared, command: "plan", startedAt: startedAt)
            return UIPlanSummary(prepared, computedAt: environment.clock.now)
        }
        let prepared = try session.prepareSync(SyncRequest(policy: .gui), progress: progress)
        try session.recordSyncPlan(prepared, command: "plan", startedAt: startedAt)
        return UIPlanSummary(prepared, computedAt: environment.clock.now)
    }

    /// Sync Now: local lock and vault lease, plan, then the vCard backup (only
    /// when Contacts is written), Apple and markdown writes, exactly like
    /// `contacts2md sync`. Before the first sync on this Mac it runs the
    /// first export instead (a two-way sync needs a merge base), behind the
    /// same lock and lease: while another device leads, nothing is written
    /// and the outcome is `.leaseHeldElsewhere`.
    ///
    /// `progress` hears each phase as it starts (`waitingForLock` while
    /// another run on this Mac holds the lock).
    public func sync(
        _ request: UISyncRequest = UISyncRequest(), progress: @Sendable (SyncPhase) -> Void = { _ in }
    ) throws -> UISyncOutcome {
        let startedAt = environment.clock.now
        let session = VaultSession(root: root, environment: environment)
        guard try hasSynced(session) else {
            progress(.waitingForLock)
            switch try gatedExport(takeOver: request.takeOver) {
            case .exported(let summary): return .synced(UISyncSummary(export: summary))
            case .localRunInProgress: return .localRunInProgress
            case .leaseHeldElsewhere(let lease): return .leaseHeldElsewhere(lease)
            }
        }
        let lock: LocalLock
        let timer = PhaseTimer()
        progress(.waitingForLock)
        switch try timer.measure("lock", { try session.beginSync(takeOver: request.takeOver) }) {
        case .localRunInProgress: return .localRunInProgress
        case .leaseHeldElsewhere(let lease): return .leaseHeldElsewhere(lease)
        case .ready(let acquired, _): lock = acquired
        }
        defer { lock.release() }
        let prepared = try session.prepareSync(
            SyncRequest(
                maxAppleChanges: request.maxAppleChanges, allowMassVanish: request.allowMassVanish,
                takeOverLease: request.takeOver, policy: .gui),
            progress: progress, timer: timer)
        if let trip = prepared.plan.breaker {
            try session.recordSyncPlan(prepared, command: "sync", startedAt: startedAt)
            return .breaker(trip)
        }
        // The session records its Apple / markdown split itself (`SessionRecord.sides`).
        progress(.writing)
        let result = try session.executeSync(prepared, command: "sync", startedAt: startedAt)
        return .synced(UISyncSummary(result, plan: prepared.plan))
    }

    /// Release Lease (Settings ▸ Advanced) while live sync is not running:
    /// gives this Mac's lease up so another device can lead at once. Returns
    /// the lease as seen afterwards.
    @discardableResult
    public func releaseLease() throws -> LeaseStatus {
        let session = VaultSession(root: root, environment: environment)
        try session.releaseLease()
        return try session.leaseStatus()
    }

    /// The lease as this Mac sees it now (reads one file).
    public func leaseStatus() throws -> LeaseStatus {
        try VaultSession(root: root, environment: environment).leaseStatus()
    }

    /// Changes `apple_writes` / `stamp_contacts` in `.c2mdsync/config.yaml`
    /// (every other key stays byte-for-byte); returns what is now in effect.
    @discardableResult
    public func setOptions(_ options: UIVaultOptions) throws -> UIVaultOptions {
        let config = try VaultSession(root: root, environment: environment).updateSettings { config in
            config.appleWrites = options.appleWrites
            config.stampContacts = options.stampContacts
        }
        return UIVaultOptions(config)
    }

    private func hasSynced(_ session: VaultSession) throws -> Bool {
        try session.storedStatus()?.lastExport != nil
    }

    /// Exports (vCard backup first, never stamps), like the app's first
    /// export, behind the local lock and the vault lease. Throws
    /// `ExportBlocked` (nothing written) while another device leads or
    /// another run on this Mac holds the lock.
    public func export(takeOver: Bool = false) throws -> UIExportSummary {
        switch try gatedExport(takeOver: takeOver) {
        case .exported(let summary): return summary
        case .leaseHeldElsewhere(let lease): throw ExportBlocked.leaderElsewhere(lease, now: environment.clock.now)
        case .localRunInProgress: throw ExportBlocked.localRunInProgress
        }
    }

    /// Plans (reads Contacts, writes nothing to the vault), then takes the
    /// local lock and the vault lease, then writes. A run that cannot read
    /// Contacts leaves no lease behind.
    private enum GatedExport {
        case exported(UIExportSummary)
        case localRunInProgress
        case leaseHeldElsewhere(VaultLease)
    }

    private func gatedExport(takeOver: Bool) throws -> GatedExport {
        let startedAt = environment.clock.now
        let session = VaultSession(root: root, environment: environment)
        let prepared = try session.prepare(ExportRequest(), forWriting: true)
        let lock: LocalLock
        switch try session.beginExport(takeOver: takeOver) {
        case .localRunInProgress: return .localRunInProgress
        case .leaseHeldElsewhere(let lease): return .leaseHeldElsewhere(lease)
        case .ready(let acquired, _): lock = acquired
        }
        defer { lock.release() }
        let outcome = try session.execute(
            prepared, backupContacts: true, stamp: false, command: "export", startedAt: startedAt)
        let adopted = outcome.result.updated.filter { $0.kind == .adopt }.count
        let export = UIExportSummary(
            created: outcome.result.created.count, adopted: adopted, updated: outcome.result.updated.count - adopted,
            contactsBackup: outcome.backup?.url.path(percentEncoded: false),
            notesBackup: outcome.result.noteBackup?.path(percentEncoded: false),
            failures: outcome.result.failures.map { "\($0.path): \($0.message)" },
            pendingReview: prepared.plan.reviews.count)
        return .exported(export)
    }

    /// Appends the decisions to this device's log. They take effect on the
    /// next plan or export. Returns the number of log entries written.
    @discardableResult
    public func record(_ answers: [UIReviewDecision]) throws -> Int {
        guard !answers.isEmpty else { return 0 }
        let fs = environment.makeVault(root)
        guard let config = try VaultConfig.load(from: fs)?.config else { throw UIReviewError.notConfigured }
        let directory = stateDirectory(config)
        let hasState = FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
        let state = hasState ? try environment.makeStateStore(directory) : nil
        let pending = try state?.loadPending().items ?? []
        let device = try environment.device()
        let now = environment.clock.now
        var decisions: [Decision] = []
        for answer in answers {
            switch answer {
            case .choice(let itemID, let choice):
                guard let entry = pending.first(where: { $0.id == itemID }) else {
                    throw UIReviewError.itemNotFound(itemID)
                }
                decisions += try entry.item.decisions(for: choice, device: device, at: now)
            case .ignoreNote(let path):
                decisions.append(Decision(kind: .ignoreCandidate, createdAt: now, device: device, path: path))
            case .addContact(let path):
                let item = pending.first { entry in
                    if case .markdownOnly(let notePath, _) = entry.item { return notePath == path }
                    return false
                }
                decisions +=
                    try item?.item.decisions(for: "add", device: device, at: now)
                    ?? [Decision(kind: .createContact, createdAt: now, device: device, path: path)]
            }
        }
        try DecisionLog.append(decisions, deviceID: device.id, fs: fs)
        try state?.saveDecisionMirror(try DecisionLog.readAll(fs).decisions)
        return decisions.count
    }

    /// Changes the folder for new notes in `.c2mdsync/config.yaml`
    /// (compare-and-swap: a concurrent edit is never overwritten).
    public func setDefaultFolder(_ folder: String) throws {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        try VaultPath.validate(folder)
        let fs = environment.makeVault(root)
        guard fs.exists(VaultConfig.path) else { throw UIReviewError.notConfigured }
        let (_, stamp) = try fs.read(VaultConfig.path)
        guard let loaded = try VaultConfig.load(from: fs) else { throw UIReviewError.notConfigured }
        var config = loaded.config
        guard config.defaultFolder != folder else { return }
        config.defaultFolder = folder
        _ = try fs.write(
            Data(config.render(patching: loaded.text).utf8), to: VaultConfig.path, expecting: .unchanged(stamp))
        let bookmark = RootBookmark(directory: environment.stateDirectory)
        var settings = bookmark.loadSettings()
        settings.defaultFolder = folder
        try? bookmark.saveSettings(settings)
    }

    private func stateDirectory(_ config: VaultConfig) -> URL {
        environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
    }
}
