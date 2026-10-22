import AppKit
import Contacts2MdCLI
import Foundation
import Observation
import SyncEngine
import SyncTriggers

/// The main window's state: stored data, the latest dry run, review queues
/// and every user action. Engine work runs off the main actor in the data source.
@MainActor
@Observable
final class AppModel {
    /// What is running.
    enum Phase: Equatable {
        case idle
        /// Reading stored state for the first time.
        case loading
        /// A dry run (reads Contacts).
        case checking
        /// Sync Now with overrides, or the first export on this Mac (runs
        /// through the coordinator are `live.state.isRunning`).
        case syncing
    }

    let setup = SetupModel()
    let source: any ReviewDataSource
    /// The live-sync coordinator for the open folder (after the first sync).
    let live: LiveSyncController
    /// Start of "This Session" on the Overview.
    let sessionStart = Date()

    private(set) var data: UIVaultData?
    private(set) var plan: UIPlanSummary?
    private(set) var queues: UIReviewQueues?
    private(set) var libraryRows: [UILibraryRow] = []
    private(set) var phase = Phase.idle
    /// What the last finished Sync Now did.
    private(set) var lastSync: UISyncSummary?
    /// Changes the last run (Sync Now or a live run) could not write.
    private(set) var lastFailures: [String] = []
    /// How the last Sync Now ended (lease, lock and breaker banners).
    private(set) var lastOutcome: UISyncOutcome?
    private(set) var snoozed: Set<String> = []
    var errorMessage: String?
    var selection: SidebarItem? = .overview
    var inspected: InspectorItem?
    var isInspectorPresented = false

    @ObservationIgnored private var loadedRoot: URL?
    /// `start()` in progress for this folder (the window and launch both call it).
    @ObservationIgnored private var startingRoot: URL?
    @ObservationIgnored private var launched = false
    /// The coordinator run `liveRunEnded` last handled.
    @ObservationIgnored private var handledSummary: SyncRunSummary?
    /// Rescan when the app becomes active again (after Open in Contacts to Link).
    @ObservationIgnored private var rescanOnActivate = false

    init(source: any ReviewDataSource = LiveReviewDataSource(), live: LiveSyncController = LiveSyncController()) {
        self.source = source
        self.live = live
        live.onRunEnded = { [weak self] in await self?.liveRunEnded() }
    }

    var rootURL: URL? { setup.rootURL }
    var capabilities: ReviewCapabilities { source.capabilities }
    var isConfigured: Bool { setup.isConfigured && setup.rootURL != nil }

    /// `Sync Now` once two-way sync exists, `Export Now` before.
    var syncTitle: String { capabilities.twoWaySync ? "Sync Now" : "Export Now" }

    var counts: UIReviewCounts { queues?.counts ?? UIReviewCounts() }

    /// A sync is in progress (Sync Now with overrides, first export, or a coordinator run).
    var isSyncing: Bool { phase == .syncing || live.state.isRunning }

    /// Sync Now / Check for Changes can start.
    var canSync: Bool { isConfigured && setup.isAuthorized && phase == .idle && !live.state.isRunning }

    var overview: UIOverview? {
        data.map { UIOverview(data: $0, plan: plan, counts: counts, sessionStart: sessionStart) }
    }

    var conflicts: [UIConflictRecord] { queues?.conflicts ?? [] }

    /// Both deletion queues.
    var deletions: [UIDeletionRow] { queues?.deletions ?? [] }

    /// `apple_writes` / `stamp_contacts` (`nil` until the folder is read).
    var vaultOptions: UIVaultOptions? { capabilities.vaultOptions ? data?.options : nil }

    /// The two-way part of the latest dry run.
    var syncPlan: UISyncPlanSummary? { plan?.sync }

    /// Breaker, blast radius, held changes, lease and identity banners.
    var banners: [UIBanner] {
        guard let data else { return [] }
        return UIBanner.banners(
            status: data.status, plan: syncPlan, outcome: lastOutcome, deviceID: data.device.id, now: Date())
    }

    var activityRows: [UIActivityRow] {
        guard let data else { return [] }
        return UIActivityRow.rows(data.sessions, device: data.device, details: data.sessionDetails)
    }

    // MARK: - Loading

    /// App launch (also when only the menu bar is shown): access, the saved
    /// folder, then `start()`.
    func launch() async {
        guard !launched else {
            await setup.refreshAccess()
            return
        }
        launched = true
        await setup.load()
        await start()
    }

    /// Loads stored data, hosts live sync once this Mac has synced, then
    /// runs a dry run (when Contacts access is granted). With live sync on,
    /// a newly started coordinator runs the launch catch-up instead; the
    /// dry run follows when it finishes.
    func start() async {
        guard let root = rootURL, isConfigured, startingRoot != root else { return }
        startingRoot = root
        defer { startingRoot = nil }
        if loadedRoot != root {
            if loadedRoot != nil { await live.shutdown() }
            loadedRoot = root
            data = nil
            plan = nil
            queues = nil
            lastSync = nil
            lastOutcome = nil
            lastFailures = []
            libraryRows = []
            snoozed = []
            inspected = nil
        }
        await reload()
        let catchingUp = await hostLiveSync() && live.effectiveSettings.liveSync
        if !catchingUp { await check() }
    }

    /// Starts the coordinator once the folder is configured, Contacts access
    /// is granted and this Mac has synced (a two-way run needs a merge base).
    /// Returns `true` when it was started now.
    @discardableResult
    private func hostLiveSync() async -> Bool {
        guard let root = rootURL, root == loadedRoot, setup.isAuthorized, data?.hasSynced == true else { return false }
        return await live.start(root: root)
    }

    /// Stops live sync (quit).
    func shutdown() async { await live.shutdown() }

    /// A coordinator run finished or was blocked: fresh stored data, then a dry run.
    private func liveRunEnded() async {
        if let summary = live.state.lastSummary, summary != handledSummary {
            // A run finished (not just blocked): Ignore for Now lasts until the next sync.
            handledSummary = summary
            lastFailures = summary.failures
            snoozed = []
            if summary.kind == .manual, !summary.failures.isEmpty {
                errorMessage = "Some changes could not be written:\n" + summary.failures.joined(separator: "\n")
            }
        }
        await reload()
        await check()
    }

    /// Re-reads stored state, the decision log and the folder (no Contacts access).
    func reload() async {
        guard let root = rootURL else { return }
        if data == nil { phase = .loading }
        defer { if phase == .loading { phase = .idle } }
        do {
            let loaded = try await source.load(root: root)
            guard root == rootURL else { return }
            data = loaded
            libraryRows = loaded.map(UILibraryRow.rows) ?? []
            rebuildQueues()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Dry run: what the next sync would do; refreshes the review queue.
    func check() async {
        // Never next to a coordinator run: it re-checks when the run ends.
        guard let root = rootURL, setup.isAuthorized, phase == .idle, !live.state.isRunning else { return }
        phase = .checking
        do {
            let result = try await source.plan(root: root)
            phase = .idle
            guard root == rootURL else { return }
            plan = result
            // Following another device: this plan is a fresher follower check.
            if let planned = result.planned { live.recheck(planned) }
            await reload()
        } catch {
            phase = .idle
            errorMessage = Self.describe(error)
        }
    }

    /// Sync Now (⌘R): local lock and lease, plan, vCard backup before any
    /// Apple write, then Contacts and notes. Once live sync is hosted, plain
    /// Sync Now goes through the coordinator (`syncNow()`: full, never
    /// debounced, serialized with live runs). `request` carries the
    /// overrides the banners offer (Apply Anyway, Resume Anyway, Take
    /// Over), each confirmed by the user first; those, and the first export
    /// on this Mac, run directly.
    func syncNow(_ request: UISyncRequest = UISyncRequest()) async {
        guard let root = rootURL, setup.isAuthorized, phase == .idle else { return }
        if request == UISyncRequest(), live.isHosting {
            lastOutcome = nil
            await live.syncNow()
            return
        }
        phase = .syncing
        snoozed = []
        do {
            let outcome = try await source.sync(request, root: root)
            phase = .idle
            guard root == rootURL else { return }
            lastOutcome = outcome
            if let summary = outcome.summary {
                lastSync = summary
                lastFailures = summary.failures
                if !summary.failures.isEmpty {
                    errorMessage = "Some changes could not be written:\n" + summary.failures.joined(separator: "\n")
                }
            }
            await reload()
            // The first export makes this Mac ready for live sync.
            let catchingUp = await hostLiveSync() && live.effectiveSettings.liveSync
            if !catchingUp { await check() }
        } catch {
            phase = .idle
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Lease

    /// Take Over (confirmed in the UI). With live sync hosted, the
    /// coordinator takes the lease (write, ~60 s settle, re-read) and syncs
    /// at once; otherwise Sync Now runs with `takeOver` (the first export
    /// too), which takes the lease the same way.
    func takeOver() async {
        guard rootURL != nil, setup.isAuthorized, phase == .idle else { return }
        guard live.isHosting else {
            await syncNow(UISyncRequest(takeOver: true))
            return
        }
        phase = .syncing
        lastOutcome = nil
        do {
            if let status = try await live.takeOver(), status.role != .leader {
                errorMessage =
                    "\(status.holder?.deviceName ?? "Another device") took the lease at the same moment and kept it. "
                    + "This Mac keeps following."
            }
        } catch {
            errorMessage = Self.describe(error)
        }
        phase = .idle
        await reload()
    }

    // MARK: - Decisions

    /// Records answers in the decision log; `true` on success.
    @discardableResult
    func decide(_ answers: [UIReviewDecision]) async -> Bool {
        guard let root = rootURL, !answers.isEmpty else { return false }
        do {
            try await source.record(answers, root: root)
            await reload()
            // Following another device: what it still has to apply changed
            // (the leader carries the answers out); count it again.
            if live.state.isFollowing { await check() }
            return true
        } catch {
            errorMessage = Self.describe(error)
            await reload()
            return false
        }
    }

    /// Ignore for Now: hidden until the next sync or relaunch.
    func snooze(_ itemID: String) {
        snoozed.insert(itemID)
        rebuildQueues()
    }

    /// Records conflict resolutions; the next sync applies each one while
    /// both sides still hold the values it was made against.
    @discardableResult
    func resolve(_ choices: [UIConflictChoice]) async -> Bool {
        await decide(choices.map(\.decision))
    }

    /// Records deletion decisions; the next sync carries them out.
    @discardableResult
    func applyDeletions(_ choices: [UIDeletionChoice]) async -> Bool {
        await decide(choices.map(\.decision))
    }

    /// Records "create a contact from this note" for each path.
    @discardableResult
    func addToContacts(paths: [String]) async -> Bool {
        await decide(paths.map { .addContact(path: $0) })
    }

    /// Writes the vault's sync switches, then re-checks (held counts change).
    func setVaultOptions(_ options: UIVaultOptions) async {
        await perform { try await self.source.setVaultOptions(options, root: $0) }
        await check()
    }

    /// Changes the folder for new notes; `nil` on success, else the message.
    func setDefaultFolder(_ folder: String) async -> String? {
        guard let root = rootURL else { return "No notes folder is open." }
        do {
            try await source.setDefaultFolder(folder, root: root)
            await reload()
            return nil
        } catch {
            return "Use a folder path inside the notes root, like Inbox or People/New. (\(Self.describe(error)))"
        }
    }

    private func perform(_ work: @escaping (URL) async throws -> Void) async {
        guard let root = rootURL else { return }
        do {
            try await work(root)
            await reload()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func rebuildQueues() {
        queues = data.map { UIReviewQueues(data: $0, plan: plan, snoozed: snoozed) }
    }

    /// Engine errors describe themselves; Cocoa errors use their localized text.
    static func describe(_ error: any Error) -> String { UIFormat.message(for: error) }
}

// MARK: - Finder and Contacts

extension AppModel {
    /// Opens each card in Contacts.app; rescans when the app is active again.
    func openInContacts(cardIDs: [String]) {
        let urls = UIFormat.contactsURLs(cardIDs: cardIDs)
        guard !urls.isEmpty else { return }
        rescanOnActivate = true
        for url in urls { NSWorkspace.shared.open(url) }
    }

    /// Called when the app becomes active.
    func didBecomeActive() async {
        guard rescanOnActivate else { return }
        rescanOnActivate = false
        await check()
    }

    /// Selects `path` (root-relative) in Finder.
    func revealInFinder(path: String) {
        guard let root = rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: path)])
    }

    func revealRoot() {
        guard let root = rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func revealBackups() {
        guard let folder = data?.backupsDirectory else { return }
        let target = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) ? folder : nil
        NSWorkspace.shared.activateFileViewerSelecting([target ?? folder.deletingLastPathComponent()])
    }

    /// Shows `item` in the inspector (opening it when asked).
    func inspect(_ item: InspectorItem?, open: Bool = false) {
        inspected = item
        if open, item != nil { isInspectorPresented = true }
    }
}
