import AppKit
import ContactModel
import Contacts
import Contacts2MdCLI
import ContactsAdapter
import Foundation
import Observation
import SyncEngine
import VaultIndex

/// Drives onboarding: Contacts access, notes folder (security-scoped
/// bookmark), read-only preview, and the first export (never stamps).
///
/// All Contacts and file-system work runs off the main actor.
@MainActor
@Observable
final class SetupModel {
    private(set) var accessStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    private(set) var notesAccess = NotesAccess.checking
    private(set) var rootURL: URL?
    var defaultFolder = "Inbox"
    private(set) var folderError: String?
    private(set) var scan: FolderScan?
    private(set) var preview: PreviewSummary?
    /// Step 4: the preview's duplicate clusters (cluster partition).
    private(set) var duplicates: [UIDuplicateGroup] = []
    /// Clusters skipped one by one, or all of them (Skip for Now): each
    /// yields one note until answered in Review.
    private(set) var skippedDuplicates: Set<String> = []
    private(set) var duplicatesSkipped = false
    private(set) var outcome: OutcomeSummary?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// `load()` finished at least once.
    private(set) var hasLoaded = false
    /// The saved folder could not be opened (moved, deleted, stale bookmark).
    private(set) var folderUnavailable: String?

    /// The preview's review items (answers are recorded against them).
    @ObservationIgnored private var previewItems: [ReviewItem] = []
    @ObservationIgnored private var resolvedRoot: ResolvedRoot?
    @ObservationIgnored private let bookmark = RootBookmark(directory: CLIEnvironment.live().stateDirectory)

    var isAuthorized: Bool { accessStatus == .authorized }
    var canRequestAccess: Bool { accessStatus == .notDetermined }
    var isConfigured: Bool { scan?.configured == true || outcome != nil }
    var canPreview: Bool { isAuthorized && rootURL != nil && folderError == nil && !isBusy }
    var canExport: Bool { canPreview && preview != nil && duplicatesSettled }

    /// Clusters still waiting for an answer in step 4.
    var openDuplicates: [UIDuplicateGroup] {
        duplicatesSkipped ? [] : duplicates.filter { !skippedDuplicates.contains($0.id) }
    }

    /// Step 4 is done: no clusters, every one answered or skipped.
    var duplicatesSettled: Bool { openDuplicates.isEmpty }

    /// The binary that also runs the command line.
    var cliPath: String { Bundle.main.executablePath ?? "Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync" }

    var accessDescription: String {
        switch accessStatus {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Off"
        case .authorized: "Granted"
        case .limited: "Limited"
        @unknown default: "Unknown"
        }
    }

    // MARK: - Startup

    /// Refreshes access, reopens the saved folder.
    func load() async {
        accessStatus = CNContactStore.authorizationStatus(for: .contacts)
        if isAuthorized { notesAccess = await Self.probeNotes() }
        if rootURL == nil, bookmark.exists {
            do {
                adopt(try bookmark.open())
                folderUnavailable = nil
            } catch {
                folderUnavailable = bookmark.loadSettings().rootPath ?? "the notes folder"
                errorMessage = String(describing: error)
            }
        }
        if let folder = bookmark.loadSettings().defaultFolder { defaultFolder = folder }
        await rescan()
        hasLoaded = true
    }

    /// Re-reads access status (e.g. after returning from System Settings).
    func refreshAccess() async {
        let before = accessStatus
        accessStatus = CNContactStore.authorizationStatus(for: .contacts)
        if accessStatus != before, isAuthorized { notesAccess = await Self.probeNotes() }
    }

    // MARK: - Step 1: access

    func requestAccess() async {
        do {
            _ = try await CNContactStore().requestAccess(for: .contacts)
        } catch {
            errorMessage = error.localizedDescription
        }
        await load()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 2: folders

    func chooseRoot() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for contact notes (existing files are scanned, never moved)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try bookmark.save(url)
            adopt(try bookmark.open())
            errorMessage = nil
            folderUnavailable = nil
        } catch {
            errorMessage = "Could not remember this folder: \(error.localizedDescription)"
        }
        clearPreview()
        outcome = nil
        await rescan()
    }

    /// Validates and saves the folder for new notes.
    func commitDefaultFolder() {
        let folder = defaultFolder.trimmingCharacters(in: .whitespaces)
        do {
            try VaultPath.validate(folder)
            folderError = nil
            var settings = bookmark.loadSettings()
            settings.defaultFolder = folder
            try bookmark.saveSettings(settings)
            defaultFolder = folder
            clearPreview()
        } catch {
            folderError = "Use a folder path inside the notes root, like Inbox or People/New."
        }
    }

    private func adopt(_ root: ResolvedRoot) {
        resolvedRoot?.close()
        resolvedRoot = root
        rootURL = root.url
    }

    private func rescan() async {
        guard let rootURL else {
            scan = nil
            return
        }
        let result = await Self.scanFolder(rootURL)
        scan = result
        if let folder = result?.defaultFolder, result?.configured == true { defaultFolder = folder }
    }

    // MARK: - Step 3: preview

    func runPreview() async {
        guard let rootURL, canPreview else { return }
        commitDefaultFolder()
        guard folderError == nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await Self.preview(root: rootURL, defaultFolder: defaultFolder))
            errorMessage = nil
        } catch {
            preview = nil
            duplicates = []
            previewItems = []
            errorMessage = String(describing: error)
        }
    }

    private func clearPreview() {
        preview = nil
        duplicates = []
        previewItems = []
        skippedDuplicates = []
        duplicatesSkipped = false
    }

    private func apply(_ result: PreviewResult) {
        preview = result.summary
        duplicates = result.duplicates
        previewItems = result.items
        skippedDuplicates.formIntersection(result.duplicates.map(\.id))
    }

    // MARK: - Step 4: duplicates

    /// Records a cluster answer (the folder may have no config yet), then
    /// previews again so the answer shows in the counts.
    func recordDuplicate(_ answers: [UIReviewDecision]) async -> Bool {
        guard let rootURL else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Self.record(answers, items: previewItems, root: rootURL)
            apply(try await Self.preview(root: rootURL, defaultFolder: defaultFolder))
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// Skips one cluster: it yields one note and waits in Review.
    func skipDuplicate(_ id: String) { skippedDuplicates.insert(id) }

    /// Skip for Now: every cluster yields one note and waits in Review.
    func skipAllDuplicates() { duplicatesSkipped = true }

    /// Opens cards in Contacts (Link Selected Cards there, then Refresh Preview).
    func openInContacts(_ cardIDs: [String]) {
        for url in UIFormat.contactsURLs(cardIDs: cardIDs) { NSWorkspace.shared.open(url) }
    }

    func revealInFinder(_ path: String) {
        guard let rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([rootURL.appending(path: path)])
    }

    // MARK: - Step 5: export

    func runExport() async {
        guard let rootURL, canExport else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            outcome = try await Self.export(root: rootURL, defaultFolder: defaultFolder)
            errorMessage = nil
            await rescan()
            if let result = try? await Self.preview(root: rootURL, defaultFolder: defaultFolder) { apply(result) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Off the main actor

    nonisolated private static func environment() -> CLIEnvironment {
        var environment = CLIEnvironment.live()
        environment.trigger = "GUI"
        environment.output = .capturing()
        return environment
    }

    @concurrent
    nonisolated private static func probeNotes() async -> NotesAccess {
        guard let available = try? CNContactStoreAdapter().capabilities.notesAvailable else { return .unknown }
        return available ? .available : .unavailable
    }

    @concurrent
    nonisolated private static func scanFolder(_ root: URL) async -> FolderScan? {
        let fs = LocalVaultFS(root: root)
        let config = try? VaultConfig.load(from: fs)?.config
        guard
            let index = try? VaultIndex.scan(
                fs, excludedFolders: [config?.imagesFolder ?? "_images"], excludeGlobs: config?.excludePaths ?? [])
        else { return nil }
        let status = try? VaultSession(root: root, environment: environment()).storedStatus()
        return FolderScan(
            markdownFiles: index.entries.count, contactNotes: index.entries.filter(\.isContactNote).count,
            configured: config != nil, defaultFolder: config?.defaultFolder, status: status)
    }

    /// What a preview found.
    struct PreviewResult: Sendable {
        var summary: PreviewSummary
        var duplicates: [UIDuplicateGroup]
        var items: [ReviewItem]
    }

    @concurrent
    nonisolated private static func preview(root: URL, defaultFolder: String) async throws -> PreviewResult {
        let session = VaultSession(root: root, environment: environment())
        let prepared = try session.prepare(ExportRequest(defaultFolder: defaultFolder), forWriting: false)
        try session.recordPlan(prepared, command: "plan", startedAt: Date())
        return PreviewResult(
            summary: PreviewSummary(prepared), duplicates: UIOnboardingDuplicates.groups(prepared, now: Date()),
            items: prepared.plan.reviews)
    }

    @concurrent
    nonisolated private static func record(_ answers: [UIReviewDecision], items: [ReviewItem], root: URL) async throws {
        try UIVaultReader(root: root, environment: environment()).recordPreview(answers, items: items)
    }

    /// Re-plans for writing, takes the local lock and the vault lease, and
    /// executes: vCard backup first, note backups, notes. Stamping stays off
    /// (it is opt-in via the CLI only). While another device leads, nothing
    /// is written and `ExportBlocked` explains why.
    @concurrent
    nonisolated private static func export(root: URL, defaultFolder: String) async throws -> OutcomeSummary {
        let session = VaultSession(root: root, environment: environment())
        // Plan first (reads Contacts, writes nothing to the folder), then lock and lease.
        let prepared = try session.prepare(ExportRequest(defaultFolder: defaultFolder), forWriting: true)
        let lock: LocalLock
        switch try session.beginExport() {
        case .localRunInProgress: throw ExportBlocked.localRunInProgress
        case .leaseHeldElsewhere(let lease): throw ExportBlocked.leaderElsewhere(lease, now: Date())
        case .ready(let acquired, _): lock = acquired
        }
        defer { lock.release() }
        let outcome = try session.execute(
            prepared, backupContacts: true, stamp: false, command: "export", startedAt: Date())
        return OutcomeSummary(outcome, plan: prepared.plan)
    }
}
