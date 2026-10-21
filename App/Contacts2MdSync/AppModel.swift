import AppKit
import Contacts2MdCLI
import Foundation
import Observation

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
        /// Sync Now (or the first export on this Mac).
        case syncing
    }

    let setup = SetupModel()
    let source: any ReviewDataSource
    /// Start of "This Session" on the Overview.
    let sessionStart = Date()

    private(set) var data: UIVaultData?
    private(set) var plan: UIPlanSummary?
    private(set) var queues: UIReviewQueues?
    private(set) var libraryRows: [UILibraryRow] = []
    private(set) var phase = Phase.idle
    /// What the last finished Sync Now did.
    private(set) var lastSync: UISyncSummary?
    /// How the last Sync Now ended (lease, lock and breaker banners).
    private(set) var lastOutcome: UISyncOutcome?
    private(set) var snoozed: Set<String> = []
    var errorMessage: String?
    var selection: SidebarItem? = .overview
    var inspected: InspectorItem?
    var isInspectorPresented = false

    @ObservationIgnored private var loadedRoot: URL?
    /// Rescan when the app becomes active again (after Open in Contacts to Link).
    @ObservationIgnored private var rescanOnActivate = false

    init(source: any ReviewDataSource = LiveReviewDataSource()) {
        self.source = source
    }

    var rootURL: URL? { setup.rootURL }
    var capabilities: ReviewCapabilities { source.capabilities }
    var isConfigured: Bool { setup.isConfigured && setup.rootURL != nil }

    /// `Sync Now` once two-way sync exists, `Export Now` before.
    var syncTitle: String { capabilities.twoWaySync ? "Sync Now" : "Export Now" }

    var counts: UIReviewCounts { queues?.counts ?? UIReviewCounts() }

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

    /// Loads stored data, then runs a dry run (when Contacts access is granted).
    func start() async {
        guard let root = rootURL, isConfigured else { return }
        if loadedRoot != root {
            loadedRoot = root
            data = nil
            plan = nil
            queues = nil
            lastSync = nil
            lastOutcome = nil
            libraryRows = []
            snoozed = []
            inspected = nil
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
        guard let root = rootURL, setup.isAuthorized, phase == .idle else { return }
        phase = .checking
        do {
            let result = try await source.plan(root: root)
            phase = .idle
            guard root == rootURL else { return }
            plan = result
            await reload()
        } catch {
            phase = .idle
            errorMessage = Self.describe(error)
        }
    }

    /// Sync Now (⌘R): local lock and lease, plan, vCard backup before any
    /// Apple write, then Contacts and notes. `request` carries the overrides
    /// the banners offer (Apply Anyway, Resume Anyway, Take Over), each
    /// confirmed by the user first.
    func syncNow(_ request: UISyncRequest = UISyncRequest()) async {
        guard let root = rootURL, setup.isAuthorized, phase == .idle else { return }
        phase = .syncing
        snoozed = []
        do {
            let outcome = try await source.sync(request, root: root)
            phase = .idle
            guard root == rootURL else { return }
            lastOutcome = outcome
            if let summary = outcome.summary {
                lastSync = summary
                if !summary.failures.isEmpty {
                    errorMessage = "Some changes could not be written:\n" + summary.failures.joined(separator: "\n")
                }
            }
            await reload()
            await check()
        } catch {
            phase = .idle
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Decisions

    /// Records answers in the decision log; `true` on success.
    @discardableResult
    func decide(_ answers: [UIReviewDecision]) async -> Bool {
        guard let root = rootURL, !answers.isEmpty else { return false }
        do {
            try await source.record(answers, root: root)
            await reload()
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

    func pickSurvivingFile(itemID: String, path: String) async {
        await perform { try await self.source.pickSurvivingFile(itemID: itemID, path: path, root: $0) }
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

    // MARK: - Finder and Contacts

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

    /// Engine errors describe themselves; Cocoa errors use their localized text.
    static func describe(_ error: any Error) -> String {
        let domain = (error as NSError).domain
        if domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain || domain == NSURLErrorDomain {
            return error.localizedDescription
        }
        return String(describing: error)
    }
}
