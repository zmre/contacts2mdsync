import Contacts2MdCLI
import SwiftUI

/// Settings (docs/ui.md §9). Controls for features that are not built yet
/// are shown disabled with the milestone that brings them.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("Folders", systemImage: "folder") { FolderSettings(model: model) }
            Tab("Accounts", systemImage: "person.crop.circle") { AccountSettings(model: model) }
            Tab("Scope", systemImage: "line.3.horizontal.decrease.circle") { ScopeSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings(model: model) }
        }
        .frame(width: 540)
        .frame(minHeight: 340)
    }
}

private struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            LabeledContent("Device name") {
                Text(model.data?.device.name ?? DeviceIdentityFile.computerName)
            }
            .help("This Mac's name from System Settings ▸ General ▸ Sharing")
            Section {
                Toggle("Sync every hour, even when the app is closed", isOn: .constant(false))
                    .disabled(true)
                Text("Or run `contacts2md sync` from launchd or cron. Arrives in M5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Live sync: watch Contacts and the folder for changes", isOn: .constant(false))
                    .disabled(true)
                    .help("Arrives in M5")
                Picker("Safety check", selection: .constant(2)) {
                    Text("Every hour").tag(1)
                    Text("Every 2 hours").tag(2)
                    Text("Every 6 hours").tag(6)
                }
                .disabled(true)
                .help("A full compare in case a change was missed. Arrives in M5.")
                Toggle("Show in menu bar", isOn: .constant(false)).disabled(true).help("Arrives in M5")
                Toggle("Launch at login", isOn: .constant(false)).disabled(true).help("Arrives in M5")
            } footer: {
                Text("Live sync, background sync and the menu bar arrive in M5.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderSettings: View {
    let model: AppModel
    @State private var folder = ""
    @State private var folderError: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            LabeledContent("Notes root") {
                HStack {
                    PathText(model.rootURL?.path(percentEncoded: false) ?? "None chosen")
                    Button("Choose…") { Task { await model.setup.chooseRoot() } }
                }
            }
            LabeledContent("New contacts in") {
                HStack {
                    TextField("New contacts in", text: $folder, prompt: Text("Inbox"))
                        .labelsHidden()
                        .onSubmit { Task { await save() } }
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || folder == model.data?.config.defaultFolder || folder.isEmpty)
                }
            }
            if let folderError {
                Text(folderError).foregroundStyle(.red)
            }
            LabeledContent("Photos in", value: (model.data?.config.imagesFolder ?? "_images") + "/")
            LabeledContent("File names", value: "Full Name (e.g. “Jane Doe.md”)")
        }
        .formStyle(.grouped)
        .onAppear { folder = model.data?.config.defaultFolder ?? model.setup.defaultFolder }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        folderError = await model.setDefaultFolder(folder)
    }
}

private struct AccountSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Write to", value: "iCloud (fixed in v1)")
                LabeledContent("Read from") {
                    VStack(alignment: .trailing, spacing: 4) {
                        if let accounts = model.plan?.accounts, !accounts.isEmpty {
                            ForEach(accounts, id: \.account) { account in
                                Toggle(isOn: .constant(true)) {
                                    Text("\(account.account.displayName) (\(account.count.formatted()))")
                                        .monospacedDigit()
                                }
                                .disabled(true)
                            }
                        } else {
                            Text("Counted after the next check").foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Groups ↔ tags") {
                    Text("\(model.data?.config.groups.count ?? 0) managed tags").monospacedDigit()
                }
            }
            Section {
                Toggle("Write changes back to Apple Contacts", isOn: optionBinding(\.appleWrites))
                    .disabled(!optionsEnabled)
                Toggle(
                    "Add sync IDs to contacts (needed when several devices share this folder)",
                    isOn: optionBinding(\.stampContacts)
                )
                .disabled(!optionsEnabled)
                Text(
                    "A sync ID is a small link stored on each contact card, so every device "
                        + "matches it to the same file. On a single Mac it isn't needed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } footer: {
                if !optionsEnabled {
                    Text("Both are off. They become available with two-way sync.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var optionsEnabled: Bool { model.capabilities.vaultOptions && model.vaultOptions != nil }

    private func optionBinding(_ keyPath: WritableKeyPath<VaultOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.vaultOptions?[keyPath: keyPath] ?? false },
            set: { value in
                guard var options = model.vaultOptions else { return }
                options[keyPath: keyPath] = value
                Task { await model.setVaultOptions(options) }
            })
    }
}

private struct ScopeSettings: View {
    var body: some View {
        Form {
            Section {
                Picker("Include", selection: .constant(0)) {
                    Text("All contacts").tag(0)
                    Text("Only these groups…").tag(1)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Exclude groups", value: "None")
                LabeledContent("Exclude contacts", value: "None")
            } footer: {
                Text("Planned. Until then every contact is included.").foregroundStyle(.secondary)
            }
            .disabled(true)
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            LabeledContent("Contact notes") {
                HStack(spacing: 6) {
                    MeaningDot(color: model.setup.notesAccess == .available ? .green : .gray)
                    Text(notesText)
                }
            }
            .help("The Contacts notes field needs an Apple entitlement; without it, note bodies stay markdown-only.")
            LabeledContent("Sync lease", value: "Held by: none")
                .help("Several Macs sharing one folder take turns. Arrives in M6.")
            LabeledContent("Backups") {
                HStack {
                    Text("10 kept").foregroundStyle(.secondary)
                    Button("Show in Finder") { model.revealBackups() }
                        .disabled(model.data == nil)
                }
            }
            LabeledContent("Command line") {
                PathText(model.setup.cliPath).font(.caption.monospaced())
            }
            HStack {
                Button("Rescan Everything…") {}
                    .disabled(true)
                Button("Reset Sync State…") {}
                    .disabled(true)
                Spacer()
            }
            .help("Arrives with two-way sync")
        }
        .formStyle(.grouped)
    }

    private var notesText: String {
        switch model.setup.notesAccess {
        case .available: "Available"
        case .unavailable: "Not available — notes stay markdown-only"
        case .checking: "Checking…"
        case .unknown: "Unknown"
        }
    }
}
