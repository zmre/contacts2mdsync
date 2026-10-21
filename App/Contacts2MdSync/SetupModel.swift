import AppKit
import ContactModel
import Contacts
import Contacts2MdCLI
import ContactsAdapter
import Foundation
import Observation
import SyncEngine
import VaultIndex

/// Counts shown in the read-only preview (onboarding step 3).
struct PreviewSummary: Sendable, Equatable {
    var contactsRead: Int
    /// Card counts per account (`iCloud 1,031`, `Google 217`, …).
    var accounts: [AccountCount]
    var groups: Int
    var matched: Int
    var toAdopt: Int
    var toCreate: Int
    var markdownOnly: Int
    var duplicates: Int
    var possibleMatches: Int
    var otherReviews: Int
    var firstExport: Bool

    init(_ prepared: PreparedExport) {
        let plan = prepared.plan
        contactsRead = plan.appleContactCount
        let kinds = prepared.snapshot.contacts.flatMap(\.cards).map(\.accountKind.displayName)
        accounts = Dictionary(grouping: kinds, by: { $0 }).map { AccountCount(name: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
        groups = plan.config.groups.count
        matched = plan.unchanged + plan.updates.filter { $0.kind == .update || $0.kind == .pathFixup }.count
        toAdopt = plan.adoptions.count
        toCreate = plan.creates.count
        markdownOnly = plan.markdownOnly
        var duplicates = 0
        var matches = 0
        for review in plan.reviews {
            switch review {
            case .duplicateCluster, .mergeRecords: duplicates += 1
            case .possibleMatch: matches += 1
            default: break
            }
        }
        self.duplicates = duplicates
        possibleMatches = matches
        otherReviews = plan.reviews.count - duplicates - matches
        firstExport = prepared.firstExport
    }
}

/// Whether the Contacts notes field is readable (needs an Apple entitlement).
enum NotesAccess: Sendable {
    case checking
    case available
    case unavailable
    case unknown

    var description: String {
        switch self {
        case .checking: "Checking…"
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }
}

/// Cards in one account kind.
struct AccountCount: Sendable, Equatable, Hashable {
    var name: String
    var count: Int
}

/// What an export run did (onboarding step 5).
struct OutcomeSummary: Sendable, Equatable {
    var created: Int
    var adopted: Int
    var updated: Int
    var contactsBackup: String?
    var notesBackup: String?
    var failures: [String]
    var pendingReview: Int

    init(_ outcome: ExportOutcome, plan: ExportPlan) {
        created = outcome.result.created.count
        adopted = outcome.result.updated.filter { $0.kind == .adopt }.count
        updated = outcome.result.updated.count - adopted
        contactsBackup = outcome.backup?.url.path(percentEncoded: false)
        notesBackup = outcome.result.noteBackup?.path(percentEncoded: false)
        failures = outcome.result.failures.map { "\($0.path): \($0.message)" }
        pendingReview = plan.reviews.count
    }
}

/// Result of a quick folder scan (onboarding step 2).
struct FolderScan: Sendable, Equatable {
    var markdownFiles: Int
    var contactNotes: Int
    var configured: Bool
    var defaultFolder: String?
    /// This device's state for the vault (configured vaults only).
    var status: StoredStatus?
}

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
    private(set) var outcome: OutcomeSummary?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// `load()` finished at least once.
    private(set) var hasLoaded = false
    /// The saved folder could not be opened (moved, deleted, stale bookmark).
    private(set) var folderUnavailable: String?

    @ObservationIgnored private var resolvedRoot: ResolvedRoot?
    @ObservationIgnored private let bookmark = RootBookmark(directory: CLIEnvironment.live().stateDirectory)

    var isAuthorized: Bool { accessStatus == .authorized }
    var canRequestAccess: Bool { accessStatus == .notDetermined }
    var isConfigured: Bool { scan?.configured == true || outcome != nil }
    var canPreview: Bool { isAuthorized && rootURL != nil && folderError == nil && !isBusy }
    var canExport: Bool { canPreview && preview != nil }

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
        preview = nil
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
            preview = nil
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
            preview = try await Self.preview(root: rootURL, defaultFolder: defaultFolder)
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = String(describing: error)
        }
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
            preview = try? await Self.preview(root: rootURL, defaultFolder: defaultFolder)
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

    @concurrent
    nonisolated private static func preview(root: URL, defaultFolder: String) async throws -> PreviewSummary {
        let session = VaultSession(root: root, environment: environment())
        let prepared = try session.prepare(ExportRequest(defaultFolder: defaultFolder), forWriting: false)
        try session.recordPlan(prepared, command: "plan", startedAt: Date())
        return PreviewSummary(prepared)
    }

    /// Re-plans for writing and executes: vCard backup first, note backups,
    /// notes. Stamping stays off (it is opt-in via the CLI only).
    @concurrent
    nonisolated private static func export(root: URL, defaultFolder: String) async throws -> OutcomeSummary {
        let session = VaultSession(root: root, environment: environment())
        let prepared = try session.prepare(ExportRequest(defaultFolder: defaultFolder), forWriting: true)
        let outcome = try session.execute(
            prepared, backupContacts: true, stamp: false, command: "export", startedAt: Date())
        return OutcomeSummary(outcome, plan: prepared.plan)
    }
}
