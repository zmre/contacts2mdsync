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
    /// What the user just started (Sync Now, a banner action), shown at
    /// once in its button and the toolbar until it ends (docs/ui.md §3).
    private(set) var feedback: UIRunFeedback?
    /// The phase of the app's own run (a check or a direct Sync Now).
    private(set) var runProgress: SyncPhase?
    /// A vault switch change being saved (the switch shows it at once).
    private(set) var pendingOptions: UIPendingOptions?
    /// Renamed contacts still linked by their old title from other notes (Overview).
    var renamedLinks: [UIRenamedLinks] = []
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
    @ObservationIgnored var rescanOnActivate = false
    /// A check was asked for while one ran: run another when it ends.
    @ObservationIgnored private var recheckRequested = false

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
    var canSync: Bool {
        isConfigured && setup.isAuthorized && phase == .idle && !live.state.isRunning && feedback == nil
    }

    var overview: UIOverview? {
        data.map { UIOverview(data: $0, plan: plan, counts: counts, sessionStart: sessionStart) }
    }

    var conflicts: [UIConflictRecord] { queues?.conflicts ?? [] }

    /// Both deletion queues.
    var deletions: [UIDeletionRow] { queues?.deletions ?? [] }

    /// `apple_writes` / `stamp_contacts` (`nil` until the folder is read).
    var vaultOptions: UIVaultOptions? { capabilities.vaultOptions ? data?.options : nil }

    /// The switches as shown: a change being saved shows at once.
    var displayedOptions: UIVaultOptions? {
        UIPendingOptions.displayed(stored: vaultOptions, pending: pendingOptions)
    }

    /// The toolbar's view of the app's own run (the action, its phase, waiting).
    var runFeedback: UIRunFeedback? {
        guard var feedback else { return nil }
        feedback.phase = runProgress ?? feedback.phase
        return feedback
    }

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
        let finished = live.state.lastSummary.map { $0 != handledSummary } ?? false
        if finished, let summary = live.state.lastSummary {
            // A run finished (not just blocked): Ignore for Now lasts until the next sync.
            handledSummary = summary
            lastFailures = summary.failures
            snoozed = []
            if summary.kind == .manual, !summary.failures.isEmpty {
                errorMessage = "Some changes could not be written:\n" + summary.failures.joined(separator: "\n")
            }
        }
        await reload()
        if finished { await refreshRenamedLinks() }
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

    /// Ignore for Now: hidden until the next sync or relaunch.
    func snooze(_ itemID: String) {
        snoozed.insert(itemID)
        rebuildQueues()
    }

    private func rebuildQueues() {
        queues = data.map { UIReviewQueues(data: $0, plan: plan, snoozed: snoozed) }
    }

    /// Engine errors describe themselves; Cocoa errors use their localized text.
    static func describe(_ error: any Error) -> String { UIFormat.message(for: error) }
}

// MARK: - Checks, Sync Now, Take Over, vault switches

extension AppModel {
    /// Dry run: what the next sync would do; refreshes the review queue.
    /// Asked for while a check runs, another follows it (the counts may
    /// predate a change just made). `action`: Check Again on a banner.
    func check(action: UIUserAction? = nil) async {
        guard let root = rootURL, setup.isAuthorized else { return }
        // Never next to a coordinator run: it re-checks when the run ends.
        guard !live.state.isRunning else { return }
        guard phase == .idle else {
            if phase == .checking { recheckRequested = true }
            return
        }
        phase = .checking
        if let action { feedback = UIRunFeedback(action) }
        defer { if let action, feedback?.action == action { feedback = nil } }
        runProgress = nil
        do {
            let result = try await source.plan(root: root, progress: progressHandler())
            phase = .idle
            runProgress = nil
            guard root == rootURL else { return }
            plan = result
            // Following another device: this plan is a fresher follower check.
            if let planned = result.planned { live.recheck(planned) }
            await reload()
        } catch {
            phase = .idle
            runProgress = nil
            errorMessage = Self.describe(error)
        }
        if recheckRequested {
            recheckRequested = false
            await check()
        }
    }

    /// Sync Now (⌘R): local lock and lease, plan, vCard backup before any
    /// Apple write, then Contacts and notes. Once live sync is hosted, plain
    /// Sync Now goes through the coordinator (`syncNow()`: full, never
    /// debounced, serialized with live runs). `request` carries the
    /// overrides the banners offer (Apply Anyway, Resume Anyway, Take
    /// Over), each confirmed by the user first; those, and the first export
    /// on this Mac, run directly.
    ///
    /// `action` shows at once (its banner button turns into “Resuming…”,
    /// the toolbar follows the run's phases). While a check or another sync
    /// runs on this Mac, the request waits for it (“Waiting for the current
    /// sync to finish…”) instead of being dropped.
    func syncNow(_ request: UISyncRequest = UISyncRequest(), action: UIUserAction = .syncNow) async {
        // One user action at a time (a Check Again in progress is waited for).
        let busy = feedback.map { $0.action != .checkAgain } ?? false
        guard let root = rootURL, setup.isAuthorized, phase != .syncing, !busy else { return }
        feedback = UIRunFeedback(action)
        defer { feedback = nil }
        if request == UISyncRequest(), live.isHosting {
            lastOutcome = nil
            await live.syncNow()
            return
        }
        guard await waitUntilIdle(), root == rootURL else { return }
        phase = .syncing
        runProgress = nil
        snoozed = []
        do {
            let outcome = try await source.sync(request, root: root, progress: progressHandler())
            phase = .idle
            runProgress = nil
            guard root == rootURL else { return }
            lastOutcome = outcome
            if let summary = outcome.summary {
                lastSync = summary
                lastFailures = summary.failures
                if !summary.failures.isEmpty {
                    errorMessage = "Some changes could not be written:\n" + summary.failures.joined(separator: "\n")
                }
            }
            feedback = nil
            await reload()
            await refreshRenamedLinks()
            // The first export makes this Mac ready for live sync.
            let catchingUp = await hostLiveSync() && live.effectiveSettings.liveSync
            if !catchingUp { await check() }
        } catch {
            phase = .idle
            runProgress = nil
            errorMessage = Self.describe(error)
        }
    }

    /// Waits while a check or a coordinator run is in progress (shown as
    /// waiting); `false` when cancelled.
    private func waitUntilIdle() async -> Bool {
        while phase != .idle || live.state.isRunning {
            feedback?.isWaiting = true
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return false }
        }
        feedback?.isWaiting = false
        return true
    }

    /// Progress from a run off the main actor, published on it.
    private func progressHandler() -> @Sendable (SyncPhase) -> Void {
        { [weak self] phase in
            Task { @MainActor in
                guard let self, self.phase != .idle else { return }
                self.runProgress = phase
            }
        }
    }

    // MARK: - Lease

    /// Take Over (confirmed in the UI). With live sync hosted, the
    /// coordinator takes the lease (write, ~60 s settle, re-read) and syncs
    /// at once; otherwise Sync Now runs with `takeOver` (the first export
    /// too), which takes the lease the same way.
    func takeOver() async {
        guard rootURL != nil, setup.isAuthorized, feedback == nil else { return }
        guard live.isHosting else {
            await syncNow(UISyncRequest(takeOver: true), action: .takeOver)
            return
        }
        feedback = UIRunFeedback(.takeOver)
        defer { feedback = nil }
        guard await waitUntilIdle() else { return }
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

    /// Writes the vault's sync switches at once (a small edit of
    /// config.yaml; it never waits for a sync or a recount). The switch
    /// shows the new position while saving; the re-check (held counts
    /// change) runs afterwards in the background, shown in the toolbar.
    func setVaultOptions(_ options: UIVaultOptions) async {
        guard let root = rootURL else { return }
        pendingOptions = UIPendingOptions(options)
        defer { pendingOptions = nil }
        do {
            try await source.setVaultOptions(options, root: root)
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        guard root == rootURL else { return }
        data?.config.appleWrites = options.appleWrites
        data?.config.stampContacts = options.stampContacts
        Task {
            await self.reload()
            await self.check()
        }
    }
}
