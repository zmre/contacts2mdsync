import Contacts2MdCLI
import Foundation
import Observation
import SyncTriggers

/// Hosts the `SyncCoordinator` for the open notes folder (architecture §10
/// "Hosting in the app"): the folder's security scope, own-write
/// suppression, the runner, the trigger sources, the status stream, the
/// per-Mac trigger settings and Pause Live Sync.
///
/// Started once the folder is configured and the first sync on this Mac is
/// done; shut down on folder change and on quit. Status interpretation
/// lives in `UILiveState` (Contacts2MdCLI) so it is unit-tested.
@MainActor
@Observable
final class LiveSyncController {
    /// The coordinator's status, folded for the toolbar and menu bar.
    private(set) var state = UILiveState()
    /// Saved settings (`<state>/triggers.json`).
    private(set) var settings: TriggerSettings
    /// Live sync is paused until this date (menu bar ▸ Pause Live Sync).
    private(set) var pausedUntil: Date?
    /// The folder the coordinator runs for (`nil`: not hosting).
    private(set) var hostedRoot: URL?
    /// Saving `triggers.json` failed.
    private(set) var settingsError: String?

    /// Called on the main actor after a run finished or was blocked:
    /// re-read stored data and run a dry run.
    @ObservationIgnored var onRunEnded: (@MainActor () async -> Void)?

    @ObservationIgnored private var coordinator: SyncCoordinator?
    @ObservationIgnored private var scope: ResolvedRoot?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var resumeTimer: Task<Void, Never>?
    /// Bumped by every `start`, so overlapping starts (folder changes) host once.
    @ObservationIgnored private var startTicket = 0
    @ObservationIgnored private let environment: CLIEnvironment
    @ObservationIgnored private let store: TriggerSettingsStore
    @ObservationIgnored private let defaults: UserDefaults

    /// UserDefaults key of the pause end.
    static let pauseKey = "livePausedUntil"

    init(environment: CLIEnvironment = .live(), defaults: UserDefaults = .standard) {
        var environment = environment
        // The runner replaces this per run with the kind (Live, Launch, …).
        environment.trigger = "GUI"
        self.environment = environment
        self.defaults = defaults
        store = TriggerSettingsStore(directory: environment.stateDirectory)
        settings = store.load()
        if let until = defaults.object(forKey: Self.pauseKey) as? Date, until > Date() {
            pausedUntil = until
        } else {
            defaults.removeObject(forKey: Self.pauseKey)
        }
    }

    var isHosting: Bool { hostedRoot != nil }

    /// The settings the coordinator runs with (live off while paused).
    var effectiveSettings: TriggerSettings {
        UILiveSettings.effective(settings, pausedUntil: pausedUntil, now: Date())
    }

    var isPaused: Bool { UILiveSettings.isPaused(settings, pausedUntil: pausedUntil, now: Date()) }

    /// `Live sync on`, `Live sync off`, `Live sync paused until …`.
    var liveLine: String { UILiveSettings.line(settings, pausedUntil: pausedUntil, now: Date()) }

    // MARK: - Hosting

    /// Starts the coordinator for `root` (no-op when it already runs for
    /// it). Returns `true` when it was started now: the launch catch-up
    /// then runs when live sync is on.
    @discardableResult
    func start(root: URL) async -> Bool {
        if hostedRoot == root { return false }
        startTicket += 1
        let ticket = startTicket
        await shutdown()
        guard ticket == startTicket, hostedRoot == nil else { return false }
        // 1. Keep the folder's security scope open while live sync runs (FSEvents needs it).
        let scope: ResolvedRoot
        do {
            scope = try RootBookmark(directory: environment.stateDirectory).open()
        } catch {
            state = UILiveState()
            state.apply(.blocked(.notRunnable("Can't open the notes folder: \(error)")))
            return false
        }
        hostedRoot = root
        self.scope = scope
        state = UILiveState()
        // 2–3. Own writes, runner, coordinator with this Mac's settings.
        let ownWrites = OwnWriteRegistry()
        let runner = VaultSyncRunner(root: root, environment: environment, ownWrites: ownWrites)
        let coordinator = SyncCoordinator(runner: runner, settings: effectiveSettings)
        self.coordinator = coordinator
        // 5. Status on the main actor (subscribed first, so the launch run is seen).
        let updates = await coordinator.statusUpdates()
        observer = Task { [weak self] in
            for await status in updates { self?.receive(status) }
        }
        // 4. Sources (the coordinator ignores live ones while live sync is off).
        await coordinator.start([
            LaunchCatchUp(), ContactsChangeSource(), VaultChangeSource(root: root, ownWrites: ownWrites),
            WakeSource(), SweepScheduler(),
        ])
        scheduleResume()
        return true
    }

    /// 8. Stops the sources, waits for a run in progress (at most
    /// `timeout`), then closes the folder's scope.
    func shutdown(timeout: Duration = .seconds(20)) async {
        guard let coordinator else { return }
        self.coordinator = nil
        hostedRoot = nil
        resumeTimer?.cancel()
        resumeTimer = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.shutdown() }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        observer?.cancel()
        observer = nil
        scope?.close()
        scope = nil
        state = UILiveState()
    }

    private func receive(_ status: SyncCoordinatorStatus) {
        guard state.apply(status) == .refresh, let onRunEnded else { return }
        Task { await onRunEnded() }
    }

    // MARK: - Requests

    /// 6. Sync Now: a full run, never debounced.
    func syncNow() async {
        await coordinator?.syncNow()
    }

    /// A full catch-up run (after live sync is turned on or a pause ends),
    /// recorded as `Launch`: events while it was off were not watched.
    private func catchUp(_ reason: String) async {
        await coordinator?.submit(SyncTrigger(.launch, reason: reason))
    }

    // MARK: - Settings (6. save, then update the coordinator)

    func setLiveSync(_ enabled: Bool) async {
        var changed = settings
        changed.liveSync = enabled
        if enabled { clearPause() }
        await save(changed)
        if enabled { await catchUp("live sync turned on") }
    }

    func setSweep(_ choice: UISweepChoice) async {
        var changed = settings
        changed.sweepInterval = choice.interval
        await save(changed)
    }

    private func save(_ changed: TriggerSettings) async {
        do {
            try store.save(changed)
            settings = changed
            settingsError = nil
        } catch {
            settingsError = "Could not save the live sync settings: \(error.localizedDescription)"
            return
        }
        await coordinator?.update(effectiveSettings)
    }

    // MARK: - Pause

    /// Turns live triggers off until `pause` ends (the sweep and Sync Now keep working).
    func pause(_ pause: UILivePause) async {
        let until = pause.until(from: Date())
        pausedUntil = until
        defaults.set(until, forKey: Self.pauseKey)
        await coordinator?.update(effectiveSettings)
        scheduleResume()
    }

    func resume() async {
        guard pausedUntil != nil else { return }
        clearPause()
        await coordinator?.update(effectiveSettings)
        if settings.liveSync { await catchUp("live sync resumed") }
    }

    private func clearPause() {
        pausedUntil = nil
        resumeTimer?.cancel()
        resumeTimer = nil
        defaults.removeObject(forKey: Self.pauseKey)
    }

    /// Restores live sync when the pause ends (ContinuousClock: counts sleep time).
    private func scheduleResume() {
        resumeTimer?.cancel()
        guard let until = pausedUntil, isHosting else { return }
        resumeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.resume()
        }
    }
}
