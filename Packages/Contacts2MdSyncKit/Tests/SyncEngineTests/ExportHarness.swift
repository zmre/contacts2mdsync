import ContactModel
import Foundation
import MarkdownCodec
import PhoneNumberKeys
import SyncEngine
import SyncTestSupport
import VaultIndex

/// Runs the planner + executor the way the CLI does, against fakes.
final class ExportHarness: Sendable {
    static let vaultID = UUID(uuidString: "0d7c0000-0000-4000-8000-0000000000aa") ?? UUID()

    let store: FakeContactStore
    let vault: InMemoryVault
    let records: InMemoryRecordMapStore
    let ids: SequentialIDGenerator
    let keyer = PhoneNumberKitKeyer(defaultRegion: "US")

    init(store: FakeContactStore = Fixtures.store(), vault: InMemoryVault = InMemoryVault()) {
        self.store = store
        self.vault = vault
        self.records = InMemoryRecordMapStore()
        self.ids = SequentialIDGenerator()
    }

    func plan(_ options: ExportOptions = ExportOptions()) throws -> ExportPlan {
        let loaded = try VaultConfig.load(from: vault)
        let config = loaded?.config ?? VaultConfig(vaultID: Self.vaultID, defaultRegion: "US")
        let index = try VaultIndex.scan(vault, excludedFolders: [config.imagesFolder])
        return try ExportPlanner(fs: vault, keyer: keyer, ids: ids, options: options)
            .plan(
                snapshot: try store.snapshot(), index: index, records: try records.load(), config: config,
                configText: loaded?.text)
    }

    @discardableResult
    func export(_ options: ExportOptions = ExportOptions()) throws -> (plan: ExportPlan, result: ExportResult) {
        let plan = try plan(options)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let result = try ExportExecutor(fs: vault, records: records, clock: clock).execute(plan)
        return (plan, result)
    }

    /// Every file in the vault (including `.c2mdsync/`), path → bytes.
    var files: [String: Data] {
        Dictionary(uniqueKeysWithValues: vault.paths.compactMap { path in vault.data(path).map { (path, $0) } })
    }

    /// The note at `path`, parsed.
    func contact(at path: String) throws -> CanonicalContact? {
        guard let text = vault.text(path) else { return nil }
        return try MarkdownCodec.parse(text).contact
    }
}
