import AppKit
import SwiftUI

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
        .task { await model.setup.load() }
    }
}

/// The main window (docs/ui.md §1): sidebar, detail, toolbar, inspector.
struct MainView: View {
    @Bindable var model: AppModel

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
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            StatusIndicator(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: .constant(false)) {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(true)
            .help("Live sync arrives in M5")
            Button {
                Task { await model.syncNow() }
            } label: {
                Label(model.syncTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .help("\(model.syncTitle) (⌘R)")
            .disabled(model.phase != .idle || !model.setup.isAuthorized)
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

/// Toolbar status: idle / checking / exporting, orange when review waits.
private struct StatusIndicator: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .loading, .checking:
                ProgressView().controlSize(.small)
                Text(model.phase == .loading ? "Reading…" : "Checking…")
            case .syncing:
                ProgressView().controlSize(.small)
                Text(model.capabilities.twoWaySync ? "Syncing…" : "Exporting…")
            case .idle:
                MeaningDot(color: color)
                Text(text)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
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
