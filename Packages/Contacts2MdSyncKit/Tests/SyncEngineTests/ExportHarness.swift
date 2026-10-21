import ContactModel
import Foundation
import MarkdownCodec
import PhoneNumberKeys
import SyncEngine
import SyncTestSupport
import VaultIndex

/// Runs the planner + executor the way `VaultSession` does, against fakes:
/// decisions read from the vault, file cache and records from the state store.
final class ExportHarness: Sendable {
    static let vaultID = UUID(uuidString: "0d7c0000-0000-4000-8000-0000000000aa") ?? UUID()
    static let device = DeviceIdentity(id: "device-a", name: "Mac A")
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    let store: FakeContactStore
    let vault: InMemoryVault
    let records: InMemorySyncStateStore
    let ids: SequentialIDGenerator
    let keyer = PhoneNumberKitKeyer(defaultRegion: "US")
    private let clock = MovingClock(start: ExportHarness.start)

    init(store: FakeContactStore = Fixtures.store(), vault: InMemoryVault = InMemoryVault()) {
        self.store = store
        self.vault = vault
        self.records = InMemorySyncStateStore()
        self.ids = SequentialIDGenerator()
    }

    /// Advances the harness clock.
    func advance(minutes: Double) { clock.advance(minutes * 60) }

    var now: Date { clock.now }

    func plan(_ options: ExportOptions = ExportOptions()) throws -> ExportPlan {
        let loaded = try VaultConfig.load(from: vault)
        let config = loaded?.config ?? VaultConfig(vaultID: Self.vaultID, defaultRegion: "US")
        let index = try VaultIndex.scan(
            vault, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths,
            cache: try records.loadFileCache())
        try records.saveFileCache(index.fileCache)
        let plan = try ExportPlanner(fs: vault, keyer: keyer, ids: ids, options: options)
            .plan(
                ExportInputs(
                    snapshot: try store.snapshot(), index: index, records: try records.load(), config: config,
                    configText: loaded?.text, decisions: DecisionSet(try DecisionLog.readAll(vault).decisions),
                    reportedProblems: try records.reportedProblemHashes(), now: clock.now))
        try records.savePending(try records.loadPending().replacing(with: plan.reviews, at: clock.now))
        try records.markProblemsReported(
            Dictionary(plan.newProblems.map { ($0.sha256, $0.path) }, uniquingKeysWith: { first, _ in first }))
        return plan
    }

    @discardableResult
    func export(_ options: ExportOptions = ExportOptions()) throws -> (plan: ExportPlan, result: ExportResult) {
        let plan = try plan(options)
        let result = try ExportExecutor(fs: vault, records: records, clock: FixedClock(clock.now)).execute(plan)
        try records.saveFileCache(result.fileCache(updating: try records.loadFileCache()))
        return (plan, result)
    }

    /// Records `choice` for the pending item `id` (as `review decide` does).
    func decide(_ id: String, _ choice: String) throws {
        let item = try require(try records.loadPending().items.first { $0.id == id }?.item, "no pending item \(id)")
        try DecisionLog.append(
            try item.decisions(for: choice, device: Self.device, at: clock.now), deviceID: Self.device.id, fs: vault)
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

    /// Modifies the stored contact with `unifiedID` (as an edit in Contacts.app would).
    func editContact(_ unifiedID: String, _ edit: (inout AppleContact) -> Void) throws {
        var contacts = store.contacts
        let index = try require(contacts.firstIndex { $0.unifiedID == unifiedID }, "no contact \(unifiedID)")
        edit(&contacts[index])
        store.replaceContacts(contacts)
    }
}

/// A clock tests can advance.
final class MovingClock: SyncClock, Sendable {
    private let current: LockedDate

    init(start: Date) { current = LockedDate(start) }

    var now: Date { current.value }

    func advance(_ seconds: TimeInterval) { current.add(seconds) }
}

/// Minimal lock-protected date (keeps the test target free of Synchronization).
final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var value: Date { lock.withLock { date } }

    func add(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// `#require` outside a test function (throws instead of recording).
func require<T>(_ value: T?, _ message: String = "required value missing") throws -> T {
    guard let value else { throw HarnessError(message: message) }
    return value
}

struct HarnessError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
