import Contacts2MdCLI
import SwiftUI
import SyncTriggers

/// Settings ▸ General (docs/ui.md §9): device name, live sync and the
/// safety check (this Mac's `triggers.json`), background sync (launchd),
/// menu bar, launch at login.
struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(AppPreferences.showInMenuBar) private var showInMenuBar = true
    @State private var services = BackgroundServices()
    @State private var backgroundHours = UIBackgroundSync.intervals[0]

    private var live: LiveSyncController { model.live }

    var body: some View {
        Form {
            LabeledContent("Device name") {
                Text(model.data?.device.name ?? DeviceIdentityFile.computerName)
            }
            .help("This Mac's name from System Settings ▸ General ▸ Sharing")
            liveSection
            backgroundSection
            Section {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Text("With the menu bar icon shown, closing the window keeps live sync running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: loginBinding)
                if services.loginStatus == .requiresApproval {
                    approvalRow
                }
                if let error = services.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            services.refresh()
            if let hours = services.agentHours { backgroundHours = hours }
        }
    }

    // MARK: - Live sync and safety check (this Mac's triggers.json)

    private var liveSection: some View {
        Section {
            Toggle("Live sync: watch Contacts and the folder for changes", isOn: liveBinding)
            if live.isPaused, let until = live.pausedUntil {
                HStack {
                    Text("Paused until \(UIFormat.relativeDay(until)).").foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { Task { await live.resume() } }
                }
                .font(.caption)
            }
            Picker("Safety check", selection: sweepBinding) {
                ForEach(UISweepChoice.choices(including: UISweepChoice(interval: live.settings.sweepInterval))) {
                    Text($0.title).tag($0)
                }
            }
            Text(
                "A full compare of Contacts and the folder in case a change was missed. "
                    + "It is skipped when one already ran within the interval."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error = live.settingsError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text(
                live.isHosting
                    ? "These settings belong to this Mac. Sync Now always works."
                    : "Live sync starts after the first sync on this Mac. These settings belong to this Mac."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var liveBinding: Binding<Bool> {
        Binding(get: { live.settings.liveSync }, set: { enabled in Task { await live.setLiveSync(enabled) } })
    }

    private var sweepBinding: Binding<UISweepChoice> {
        Binding(
            get: { UISweepChoice(interval: live.settings.sweepInterval) },
            set: { choice in Task { await live.setSweep(choice) } })
    }

    // MARK: - Background sync (launchd)

    @ViewBuilder private var backgroundSection: some View {
        Section("Background sync") {
            switch services.install {
            case .nix:
                Toggle("Sync in the background when the app is closed", isOn: .constant(false))
                    .disabled(true)
                Text(
                    "This copy of the app was installed with nix. Schedule background syncs in your "
                        + "nix-darwin configuration; launchd then runs `contacts2md sync --quiet`:"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(UIBackgroundSync.nixSnippet)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            case .standalone:
                Toggle("Sync in the background when the app is closed", isOn: backgroundBinding)
                Picker("Sync", selection: hoursBinding) {
                    ForEach(UIBackgroundSync.intervals, id: \.self) {
                        Text(UIBackgroundSync.title(hours: $0)).tag($0)
                    }
                }
                .disabled(services.agentHours == nil)
                Text(
                    "A launchd agent runs this app's command line (`sync --quiet`) on that schedule, also "
                        + "while the app is closed. Anything that needs a decision waits in Review; runs "
                        + "show up in Activity as CLI. macOS lists it under Login Items."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                LabeledContent("Status", value: BackgroundServices.describe(services.agentStatus))
                    .font(.caption)
                if services.agentStatus == .requiresApproval {
                    approvalRow
                }
                if let error = services.agentError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var backgroundBinding: Binding<Bool> {
        Binding(
            get: { services.agentHours != nil },
            set: { enabled in services.setBackgroundSync(hours: enabled ? backgroundHours : nil) })
    }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { services.agentHours ?? backgroundHours },
            set: { hours in
                backgroundHours = hours
                if services.agentHours != nil { services.setBackgroundSync(hours: hours) }
            })
    }

    // MARK: - Launch at login

    private var loginBinding: Binding<Bool> {
        Binding(get: { services.launchesAtLogin }, set: { services.setLaunchAtLogin($0) })
    }

    private var approvalRow: some View {
        HStack {
            Text("Allow it in System Settings ▸ General ▸ Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Login Items…") { services.openLoginItems() }
                .controlSize(.small)
        }
    }
}
