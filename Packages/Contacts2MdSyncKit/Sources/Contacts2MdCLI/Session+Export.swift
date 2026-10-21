internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

extension Session {
    /// Everything a planned export needs to execute.
    struct PlannedExport {
        let fs: any VaultFS
        let store: any ContactStore
        let records: any RecordMapStore
        let plan: ExportPlan
    }

    /// `plan` (write: false) and `export` (write: true).
    func export(write: Bool, stamp: Bool, restoreMissing: Bool) -> CLIExitCode {
        run {
            let planned = try prepare(restoreMissing: restoreMissing)
            let plan = planned.plan
            guard write else {
                report.plan(plan, stamping: stamp)
                report.summary(plan: plan, result: nil, stamped: 0, seconds: elapsed)
                report.note("dry run: nothing written; run `contacts2md export --yes --root \(options.root)` to write")
                return plan.needsReview ? .needsReview : .success
            }
            // Backup comes first: if it fails, nothing at all is written.
            let receipt = stamp && !plan.stamps.isEmpty ? try backup(planned.store) : nil
            let result = try ExportExecutor(fs: planned.fs, records: planned.records, clock: environment.clock)
                .execute(plan)
            report.result(result, of: plan)
            let stamping = try receipt.map { try self.stamp(planned, result: result, backup: $0) }
            report.summary(plan: plan, result: result, stamped: stamping?.applied ?? 0, seconds: elapsed)
            if !result.failures.isEmpty { return .error }
            return plan.needsReview || (stamping?.failed ?? 0) > 0 ? .needsReview : .success
        }
    }

    /// Opens everything and plans.
    private func prepare(restoreMissing: Bool) throws -> PlannedExport {
        let fs = try openVault()
        let store = try environment.makeStore()
        let loaded = try VaultConfig.load(from: fs)
        let config = try configuredVault(loaded?.config)
        let records = recordStore(for: config)
        let planner = ExportPlanner(
            fs: fs,
            keyer: environment.makeKeyer(config.defaultRegion ?? environment.fallbackRegion),
            ids: environment.ids,
            options: ExportOptions(restoreMissing: restoreMissing)
        )
        var plan = try planner.plan(
            snapshot: try store.snapshot(),
            index: try VaultIndex.scan(fs, excludedFolders: [config.imagesFolder]),
            records: loaded == nil ? RecordMap() : try records.load(),
            config: config,
            configText: loaded?.text
        )
        // Command-line options changed the config even if groups did not.
        if let loaded, config != loaded.config, plan.configText == nil {
            plan.configText = plan.config.render(patching: loaded.text)
        }
        return PlannedExport(fs: fs, store: store, records: records, plan: plan)
    }

    /// The vault config with command-line overrides applied (new vault: fresh id).
    private func configuredVault(_ existing: VaultConfig?) throws -> VaultConfig {
        var config = existing ?? VaultConfig(vaultID: environment.ids.next())
        if let folder = options.defaultFolder {
            try VaultPath.validate(folder)
            config.defaultFolder = folder
        }
        if let region = options.region { config.defaultRegion = region.uppercased() }
        if config.defaultRegion == nil { config.defaultRegion = environment.fallbackRegion.uppercased() }
        return config
    }

    private struct BackupFailed: Error, CustomStringConvertible {
        let underlying: any Error
        var description: String { "vCard backup failed (\(underlying)); nothing written, no contacts stamped" }
    }

    private func backup(_ store: any ContactStore) throws -> BackupReceipt {
        do {
            let receipt = try VCardBackup(
                directory: stateDirectory.appending(path: "backups"), clock: environment.clock
            )
            .backup(store)
            report.item("backup", "apple", "\(receipt.url.path(percentEncoded: false))  (\(receipt.byteCount) bytes)")
            return receipt
        } catch {
            throw BackupFailed(underlying: error)
        }
    }

    /// Stamps the cards of records whose note is in place (written or unchanged).
    private func stamp(
        _ planned: PlannedExport, result: ExportResult, backup: BackupReceipt
    ) throws -> (
        applied: Int, failed: Int
    ) {
        let written = Set(planned.plan.bindings.keys).subtracting(result.failedRecordIDs(in: planned.plan))
        let requests = planned.plan.stamps.filter { written.contains($0.recordID) }
        let outcome = try Stamper.stamp(
            requests, in: planned.store, backup: backup, author: SyncEngine.transactionAuthorPrefix + "cli")
        let applied = Set(outcome.applied)
        var count = 0
        for request in requests where applied.contains(.stamp(cardID: request.cardID, id: request.recordID)) {
            report.item("stamped", "apple", request.title)
            count += 1
        }
        for failure in outcome.failed { report.warning("stamp", "\(failure.operation) failed: \(failure.message)") }
        return (count, outcome.failed.count)
    }
}

extension ExportPlan {
    /// Whether anything was skipped or needs a decision.
    var needsReview: Bool { !reviews.isEmpty || !skipped.isEmpty }
}

extension ExportResult {
    /// Record ids whose note write failed.
    func failedRecordIDs(in plan: ExportPlan) -> Set<UUID> {
        let failedPaths = Set(failures.map(\.path))
        return Set((plan.creates + plan.updates).filter { failedPaths.contains($0.path) }.map(\.recordID))
    }
}
