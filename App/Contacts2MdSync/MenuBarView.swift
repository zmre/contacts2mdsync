import AppKit
import Contacts2MdCLI
import SwiftUI
import SyncTriggers

/// The menu bar icon: filled while something needs review, arrows while syncing.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Contacts2MdSync")
    }

    private var symbol: String {
        if model.isSyncing { return "arrow.triangle.2.circlepath.circle" }
        return model.counts.total > 0 ? "person.2.circle.fill" : "person.2.circle"
    }
}

/// The menu bar extra (docs/ui.md §10): status, last sync, Needs review with
/// click-through, Sync Now, Open App, Pause Live Sync.
struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            Divider()
            review
            Divider()
            actions
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 290)
        .task { await model.launch() }
    }

    // MARK: - Status

    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if model.isSyncing {
                    ProgressView().controlSize(.mini)
                } else {
                    MeaningDot(color: dotColor)
                }
                Text(headline).font(.headline).lineLimit(1)
            }
            .help(model.live.state.display()?.detail ?? "")
            Text(model.isConfigured ? model.live.liveLine : "Not set up yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        guard model.isConfigured else { return "Contacts2MdSync" }
        if model.phase == .syncing { return "Syncing…" }
        return model.live.state.headline(lastSync: model.data?.records.lastExport, reviewTotal: model.counts.total)
    }

    private var dotColor: Color {
        switch model.live.state.display()?.tone {
        case .error?: .red
        case .busy?: .accentColor
        case .idle?, .paused?, nil: model.counts.total > 0 ? .orange : .gray
        }
    }

    // MARK: - Needs review

    @ViewBuilder private var review: some View {
        let counts = model.counts
        if counts.total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    open(.overview)
                } label: {
                    row("Needs review", counts.total, bold: true)
                }
                ForEach(SidebarItem.review) { item in
                    if let queue = item.queue, counts[queue] > 0 {
                        Button {
                            open(item)
                        } label: {
                            row(item.title, counts[queue]).padding(.leading, 12)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(model.data == nil ? "Review counts appear after the first check." : "Nothing needs review.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ count: Int, bold: Bool = false) -> some View {
        HStack {
            if bold { MeaningDot(color: .orange) }
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(count.formatted()).monospacedDigit()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).imageScale(.small)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        HStack {
            Button(model.syncTitle) { Task { await model.syncNow() } }
                .disabled(!model.canSync)
            Spacer()
            Button("Open App…") { open(nil) }
        }
        if model.live.isPaused {
            Button("Resume Live Sync") { Task { await model.live.resume() } }
        } else {
            Menu("Pause Live Sync") {
                ForEach(UILivePause.allCases) { pause in
                    Button(pause.title) { Task { await model.live.pause(pause) } }
                }
            }
            .disabled(!model.live.isHosting || !model.live.settings.liveSync)
            .help(model.live.settings.liveSync ? "Stop watching for changes for a while" : "Live sync is off")
        }
    }

    /// Opens (or brings forward) the main window, at `item` when given.
    private func open(_ item: SidebarItem?) {
        if let item { model.selection = item }
        openWindow(id: AppPreferences.mainWindowID)
        NSApp.activate()
    }
}
