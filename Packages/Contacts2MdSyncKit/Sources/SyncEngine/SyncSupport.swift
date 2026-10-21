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
}

extension SyncPlanner {
    /// Scans the vault, snapshots Apple, and loads this device's state.
    public static func gather(
        fs: any VaultFS, store: any ContactStore, state: any SyncStateStore,
        config loaded: (config: VaultConfig, text: String?), now: Date
    ) throws -> GatheredSync {
        let (config, configText) = loaded
        let (decisions, problems) = try DecisionLog.readAll(fs)
        let index = try VaultIndex.scan(
            fs, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths,
            cache: try state.loadFileCache())
        let snapshot = try store.snapshot()
        let writable = (try? store.capabilities.writableContainerIDs) ?? snapshot.containers.map(\.id)
        let knownMissing = Set(
            try state.loadPending().items.compactMap { entry -> UUID? in
                switch entry.item {
                case .markdownDeleted(_, let id, _, _), .missingFile(_, let id, _): id
                default: nil
                }
            })
        let export = ExportInputs(
            snapshot: snapshot, index: index, records: try state.load(), config: config, configText: configText,
            decisions: DecisionSet(decisions), reportedProblems: try state.reportedProblemHashes(), now: now)
        var inputs = SyncInputs(
            export: export, unapplyable: try state.loadUnapplyable(), vanished: try state.loadVanished(),
            knownMissingNotes: knownMissing, writableContainerIDs: writable,
            deviceIDs: DeviceRecord.deviceIDs(fs: fs))
        let isNote = { (path: String) in
            path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".markdown")
        }
        inputs.files = Dictionary(
            try fs.enumerate().filter { !isNote($0.path) }.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first })
        inputs.imageHashes = try state.loadImageHashes()
        return GatheredSync(inputs: inputs, index: index, decisions: decisions, decisionProblems: problems)
    }

    /// Saves what planning observed: the review queue, the file cache and
    /// the problems now reported.
    public static func recordObservations(
        _ plan: SyncPlan, index: VaultIndex, state: any SyncStateStore, now: Date,
        written: [String: FileCacheEntry] = [:]
    ) throws {
        try state.saveFileCache(index.fileCache.merging(written) { _, new in new })
        try state.saveImageHashes(plan.imageHashes)
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
