import AppKit
import Contacts2MdCLI
import SwiftUI
import SyncEngine
import SyncTriggers

/// Onboarding until the folder is configured, then the main window.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.setup.hasLoaded {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isConfigured {
                MainView(model: model)
            } else if let folder = model.setup.folderUnavailable {
                ContentUnavailableView {
                    Label("Can't Open the Notes Folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Can't open \(folder). It may have moved.")
                } actions: {
                    Button("Locate…") { Task { await model.setup.chooseRoot() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minWidth: 560, minHeight: 420)
            } else {
                SetupView(model: model.setup)
                    .frame(minWidth: 560, minHeight: 520)
            }
        }
        .task { await model.launch() }
    }
}

/// The main window (docs/ui.md §1): sidebar, detail, toolbar, inspector.
struct MainView: View {
    @Bindable var model: AppModel
    @State private var confirming: SyncOverride?

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { banners }
                .inspector(isPresented: $model.isInspectorPresented) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
        }
        .toolbar { toolbar }
        .frame(minWidth: 820, minHeight: 480)
        .task(id: model.rootURL) { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.setup.refreshAccess()
                await model.didBecomeActive()
            }
        }
        .onChange(of: model.selection) { model.inspect(nil) }
        .confirmationDialog(
            confirming?.title ?? "", isPresented: isConfirming, titleVisibility: .visible, presenting: confirming
        ) { override in
            Button(override.button, role: override.isRisky ? .destructive : nil) {
                Task {
                    if case .takeOver = override {
                        await model.takeOver()
                    } else {
                        await model.syncNow(override.request)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { override in
            Text(override.message)
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    @ViewBuilder private var detail: some View {
        let item = model.selection ?? .overview
        if !model.setup.isAuthorized && item != .allContacts && item != .activity {
            NoAccessView(setup: model.setup)
        } else if model.data == nil {
            FirstScanView(phase: model.phase)
        } else {
            switch item {
            case .overview: OverviewView(model: model)
            case .conflicts: ConflictsView(model: model)
            case .markdownOnly: MarkdownOnlyView(model: model)
            case .deletions: DeletionsView(model: model)
            case .duplicates: DuplicatesView(model: model)
            case .allContacts: LibraryView(model: model)
            case .activity: ActivityView(model: model)
            }
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                Banner(.error, message) {
                    Button("Dismiss") { model.errorMessage = nil }
                }
            }
            if let undownloaded = model.data?.undownloaded, undownloaded > 0 {
                Banner(
                    .info,
                    "\(undownloaded.formatted()) files are still in iCloud. New notes wait until they download.")
            }
            if let problems = model.data?.decisionProblems, !problems.isEmpty {
                Banner(.warning, "\(problems.count) saved decisions could not be read: \(problems[0])")
            }
            ForEach(model.banners) { banner in
                Banner(.init(banner.severity), banner.message) {
                    bannerActions(banner)
                }
            }
        }
    }

    /// Every override is confirmed first (docs/ui.md §3, §12).
    @ViewBuilder private func bannerActions(_ banner: UIBanner) -> some View {
        let busy = !model.canSync
        switch banner {
        case .breaker(let trip):
            Button("Check Again") { Task { await model.check() } }
                .disabled(busy)
            Button("Resume Anyway…") { confirming = .resumeAnyway(trip) }
                .disabled(busy)
        case .blastRadius(let count, let limit):
            Button("Apply Anyway…") { confirming = .applyAnyway(count: count, limit: limit) }
                .disabled(busy)
        case .appleWritesDisabled, .identity, .notesSkipped:
            SettingsLink { Text("Open Settings…") }
        case .waitingForDevice(let name, _, let expires), .leaderElsewhere(let name, let expires, _):
            Button("Take Over…") { confirming = .takeOver(device: name, expires: expires) }
                .disabled(busy)
        case .localRunInProgress:
            EmptyView()
        }
    }

    /// On: live sync on and not paused. Turning it on also ends a pause.
    private var liveBinding: Binding<Bool> {
        Binding(
            get: { model.live.settings.liveSync && !model.live.isPaused },
            set: { enabled in
                Task {
                    if enabled, model.live.settings.liveSync {
                        await model.live.resume()
                    } else {
                        await model.live.setLiveSync(enabled)
                    }
                }
            })
    }

    private var liveHelp: String {
        let line = model.live.liveLine
        return model.live.isHosting
            ? "\(line): watch Contacts and the notes folder and sync on changes"
            : "\(line). Starts after the first sync on this Mac."
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            StatusIndicator(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: liveBinding) {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
            }
            .help(liveHelp)
            Button {
                Task { await model.syncNow() }
            } label: {
                Label(model.syncTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .help("\(model.syncTitle) (⌘R)")
            .disabled(!model.canSync)
            Button {
                model.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

/// Sidebar with review badges.
private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        let counts = model.counts
        List(selection: $model.selection) {
            row(.overview)
            Section("Review") {
                ForEach(SidebarItem.review) { item in
                    row(item, badge: item.queue.map { counts[$0] } ?? 0)
                }
            }
            Section("Library") {
                row(.allContacts, badge: model.libraryRows.count)
            }
            Section("History") {
                row(.activity)
            }
        }
    }

    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .badge(badge)
            .tag(item)
    }
}

/// Toolbar status: the coordinator's status (Scheduled, Syncing… phase,
/// Waiting for *device*, Paused: safety breaker, Failed), else reading /
/// checking, else Idle or the review count (orange).
private struct StatusIndicator: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if let live = model.live.state.display() {
                if live.tone == .busy {
                    ProgressView().controlSize(.small)
                } else {
                    MeaningDot(color: live.tone == .error ? .red : .gray)
                }
                Text(live.text)
            } else {
                switch model.phase {
                case .loading, .checking:
                    ProgressView().controlSize(.small)
                    Text(model.phase == .loading ? "Reading…" : "Checking…")
                case .syncing:
                    ProgressView().controlSize(.small)
                    Text(model.data?.hasSynced == false ? "Exporting…" : "Syncing…")
                case .idle:
                    MeaningDot(color: color)
                    Text(text)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
        .help(model.live.state.display()?.detail ?? "")
    }

    private var color: Color {
        if model.errorMessage != nil { return .red }
        return model.counts.total > 0 ? .orange : .gray
    }

    private var text: String {
        if model.errorMessage != nil { return "Error" }
        let total = model.counts.total
        return total > 0 ? "\(total.formatted()) to review" : "Idle"
    }
}

/// Centered progress for the first read (docs/ui.md §12).
private struct FirstScanView: View {
    let phase: AppModel.Phase

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(phase == .checking ? "Reading Contacts… Matching…" : "Scanning files…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-pane "no Contacts access" (docs/ui.md §12).
private struct NoAccessView: View {
    let setup: SetupModel

    var body: some View {
        ContentUnavailableView {
            Label("Contacts Access Is Off", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("Contacts2MdSync needs access to Contacts to compare it with your notes.")
        } actions: {
            if setup.canRequestAccess {
                Button("Allow Access…") { Task { await setup.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open System Settings") { setup.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A Sync Now override offered by a banner, with its confirmation.
private enum SyncOverride: Identifiable {
    case applyAnyway(count: Int, limit: Int)
    case resumeAnyway(BreakerTrip)
    case takeOver(device: String, expires: Date)

    var id: String {
        switch self {
        case .applyAnyway: "apply"
        case .resumeAnyway: "resume"
        case .takeOver: "take-over"
        }
    }

    var request: UISyncRequest {
        switch self {
        case .applyAnyway(let count, _): UISyncRequest(maxAppleChanges: count)
        case .resumeAnyway: UISyncRequest(allowMassVanish: true)
        case .takeOver: UISyncRequest(takeOver: true)
        }
    }

    var title: String {
        switch self {
        case .applyAnyway(let count, _): "Write \(count) changes to Apple Contacts?"
        case .resumeAnyway: "Resume syncing anyway?"
        case .takeOver(let device, _): "Take over syncing from \(device)?"
        }
    }

    var button: String {
        switch self {
        case .applyAnyway(let count, _): "Apply \(count) Changes"
        case .resumeAnyway: "Resume Anyway"
        case .takeOver: "Take Over"
        }
    }

    var isRisky: Bool {
        if case .takeOver = self { return false }
        return true
    }

    var message: String {
        switch self {
        case .applyAnyway(let count, let limit):
            "This sync changes \(count) contacts, more than the \(limit) allowed without approval. "
                + "A vCard backup of all contacts is saved first. Only this sync is approved, and only up "
                + "to \(count) changes; if more turn up, they are held again."
        case .resumeAnyway(let trip):
            "\(trip.vanished) of \(trip.total) synced \(trip.side == "apple" ? "contacts" : "notes") are missing. "
                + "If an account was turned off or the folder is unavailable, fix that instead. "
                + "Resuming does not delete anything: each missing one waits in Deletions for your decision."
        case .takeOver(let device, let expires):
            "Only take over if \(device) is off or stuck; its turn ends by itself at "
                + "\(UIFormat.relativeDay(expires)). This Mac waits about a minute so other devices see "
                + "the change, then syncs."
        }
    }
}

extension Banner.Style {
    init(_ severity: UIBanner.Severity) {
        switch severity {
        case .info: self = .info
        case .warning: self = .warning
        case .error: self = .error
        }
    }
}
