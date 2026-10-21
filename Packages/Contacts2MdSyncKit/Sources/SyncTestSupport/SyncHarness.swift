public import ContactModel
public import Foundation
internal import MarkdownCodec
internal import PhoneNumberKeys
public import SyncEngine
internal import Synchronization
public import VaultIndex

/// A clock tests can advance.
public final class TestClock: SyncClock {
    private let current: Mutex<Date>

    /// Starts at `start`.
    public init(start: Date) { current = Mutex(start) }

    public var now: Date { current.withLock { $0 } }

    /// Moves time forward.
    public func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

/// Scenario DSL for two-way sync: a `FakeContactStore`, an `InMemoryVault`
/// and in-memory device state, driven exactly like `VaultSession` drives
/// the engine (gather → plan → record observations → execute).
///
/// ```swift
/// let world = SyncHarness(contacts: [...])
/// try world.export()                       // first import (M2 one-way)
/// world.editNote("Inbox/Ann One.md") { $0.jobTitle = "CTO" }
/// world.store.editCard("ann:icloud") { $0.emails.append(...) }
/// let run = try world.sync()               // two-way
/// #expect(try world.sync().plan.isEmpty)   // fixpoint
/// ```
public final class SyncHarness: Sendable {
    public static let vaultID = UUID(uuidString: "0d7c0000-0000-4000-8000-0000000000bb") ?? UUID()
    public static let device = DeviceIdentity(id: "device-a", name: "Mac A")
    public static let start = Date(timeIntervalSince1970: 1_800_000_000)

    public let store: FakeContactStore
    public let vault: InMemoryVault
    public let state: InMemorySyncStateStore
    public let ids: SequentialIDGenerator
    public let keyer: any PhoneKeyer
    public let clock: TestClock
    /// vCard backups go here (a temp folder, removed on deinit).
    public let backupDirectory: URL
    /// The device this harness syncs as.
    public let device: DeviceIdentity

    /// Creates a world whose vault is configured with `apple_writes` and
    /// `stamp_contacts` as given (the vault id and region are fixed).
    public init(
        store: FakeContactStore, vault: InMemoryVault = InMemoryVault(), appleWrites: Bool = true,
        stampContacts: Bool = false, device: DeviceIdentity = SyncHarness.device,
        state: InMemorySyncStateStore = InMemorySyncStateStore(), clock: TestClock? = nil,
        ids: SequentialIDGenerator = SequentialIDGenerator(start: 1)
    ) {
        self.store = store
        self.vault = vault
        self.state = state
        self.ids = ids
        self.keyer = PhoneNumberKitKeyer(defaultRegion: "US")
        self.clock = clock ?? TestClock(start: Self.start)
        self.device = device
        backupDirectory = FileManager.default.temporaryDirectory.appending(path: "c2m-sync-\(UUID().uuidString)")
        if !vault.exists(VaultConfig.path) {
            var config = VaultConfig(vaultID: Self.vaultID, defaultRegion: "US")
            config.appleWrites = appleWrites
            config.stampContacts = stampContacts
            vault.seed(VaultConfig.path, Data(config.render().utf8))
        }
    }

    /// A world over `contacts` (default containers and fixture groups).
    public convenience init(
        contacts: [AppleContact], groups: [AppleGroup] = Fixtures.groups, notesEntitled: Bool = true,
        appleWrites: Bool = true, stampContacts: Bool = false
    ) {
        self.init(
            store: FakeContactStore(
                contacts: contacts, containers: Fixtures.containers, groups: groups, notesEntitled: notesEntitled),
            appleWrites: appleWrites, stampContacts: stampContacts)
    }

    deinit { try? FileManager.default.removeItem(at: backupDirectory) }

    // MARK: - Config

    /// The vault configuration.
    public var config: VaultConfig {
        get throws {
            guard let config = try VaultConfig.load(from: vault)?.config else {
                throw HarnessFailure("vault has no config")
            }
            return config
        }
    }

    /// Edits the config file as a user would (raw text replace or append).
    public func setConfig(_ edit: (inout VaultConfig) -> Void) throws {
        guard let (config, text) = try VaultConfig.load(from: vault) else { throw HarnessFailure("no config") }
        var updated = config
        edit(&updated)
        vault.seed(VaultConfig.path, Data(updated.render(patching: text).utf8))
    }

    /// Appends raw YAML to the config (scope, limits).
    public func appendConfig(_ yaml: String) {
        let text = vault.text(VaultConfig.path) ?? ""
        vault.seed(VaultConfig.path, Data((text + yaml).utf8))
    }

    // MARK: - Runs

    /// One-way export (the M2 first import).
    @discardableResult
    public func export(_ options: ExportOptions = ExportOptions()) throws -> ExportPlan {
        let loaded = try VaultConfig.load(from: vault)
        let config = try self.config
        let index = try VaultIndex.scan(
            vault, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths,
            cache: try state.loadFileCache())
        let plan = try ExportPlanner(fs: vault, keyer: keyer, ids: ids, options: options).plan(
            ExportInputs(
                snapshot: try store.snapshot(), index: index, records: try state.load(), config: config,
                configText: loaded?.text, decisions: DecisionSet(try DecisionLog.readAll(vault).decisions),
                reportedProblems: try state.reportedProblemHashes(), now: clock.now))
        let result = try ExportExecutor(fs: vault, records: state, clock: FixedClock(clock.now)).execute(plan)
        try state.saveFileCache(result.fileCache(updating: index.fileCache))
        try state.savePending(try state.loadPending().replacing(with: plan.reviews, at: clock.now))
        return plan
    }

    /// Gathers and plans a sync (writes only the observations, like `plan`).
    public func plan(_ options: SyncOptions = SyncOptions()) throws -> (plan: SyncPlan, index: VaultIndex) {
        let loaded = try VaultConfig.load(from: vault)
        let gathered = try SyncPlanner.gather(
            fs: vault, store: store, state: state, config: (try config, loaded?.text), now: clock.now)
        let plan = try SyncPlanner(fs: vault, keyer: keyer, ids: ids, options: options).plan(
            gathered.including(device).inputs)
        try SyncPlanner.recordObservations(plan, index: gathered.index, state: state, now: clock.now)
        return (plan, gathered.index)
    }

    /// The outcome of one sync.
    public struct Run: Sendable {
        public var plan: SyncPlan
        /// `nil` when a breaker stopped the run.
        public var result: SyncResult?
    }

    /// Plans and executes one sync.
    @discardableResult
    public func sync(_ options: SyncOptions = SyncOptions()) throws -> Run {
        let (plan, index) = try self.plan(options)
        guard plan.breaker == nil else { return Run(plan: plan, result: nil) }
        let executor = SyncExecutor(
            fs: vault, store: store, state: state, clock: clock,
            noteBackups: NoteBackup(directory: backupDirectory, clock: clock),
            author: SyncEngine.transactionAuthor(deviceID: device.id))
        let backups = VCardBackup(directory: backupDirectory, clock: clock)
        let result = try executor.execute(plan) { try backups.backup(store) }
        try state.saveFileCache(index.fileCache.merging(result.markdown.writtenCache) { _, new in new })
        try DeviceRecord.write(
            DeviceRecord(deviceID: device.id, deviceName: device.name, lastSync: clock.now, summary: "test"),
            fs: vault)
        return Run(plan: plan, result: result)
    }

    /// Records `choice` for the pending review item `id` (as `review decide` does).
    public func decide(_ id: String, _ choice: String) throws {
        guard let item = try state.loadPending().items.first(where: { $0.id == id })?.item else {
            throw HarnessFailure("no pending item \(id)")
        }
        try DecisionLog.append(
            try item.decisions(for: choice, device: device, at: clock.now), deviceID: device.id, fs: vault)
    }

    /// Pending review items of a kind prefix (`conflict`, `deleted`, `missing`, …).
    public func pending(_ prefix: String) throws -> [ReviewItem] {
        try state.loadPending().items.map(\.item).filter { $0.id.hasPrefix(prefix + "-") }
    }

    /// Moves the clock.
    public func advance(minutes: Double) { clock.advance(minutes * 60) }

    // MARK: - Notes

    /// The parsed contact at `path`.
    public func note(_ path: String) throws -> CanonicalContact? {
        guard let text = vault.text(path) else { return nil }
        return try MarkdownCodec.parse(text).contact
    }

    /// Every contact note path (sorted).
    public var notePaths: [String] {
        vault.paths.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") && (try? note($0)) != nil }
    }

    /// Edits the note at `path` as a user would (not counted as our write).
    public func editNote(_ path: String, _ edit: (inout CanonicalContact) -> Void) throws {
        guard let text = vault.text(path) else { throw HarnessFailure("no note \(path)") }
        let parsed = try MarkdownCodec.parse(text)
        guard var contact = parsed.contact else { throw HarnessFailure("\(path) is not a contact") }
        edit(&contact)
        vault.seed(path, Data(try MarkdownCodec.encode(contact, patching: parsed).utf8))
    }

    /// Replaces a note's text (raw edit).
    public func writeNote(_ path: String, _ text: String) { vault.seed(path, Data(text.utf8)) }
}

/// A harness misuse.
public struct HarnessFailure: Error, CustomStringConvertible {
    public let description: String

    /// Creates a failure.
    public init(_ description: String) { self.description = description }
}
