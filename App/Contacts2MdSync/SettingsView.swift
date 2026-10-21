import Contacts2MdCLI
import SwiftUI

/// Settings (docs/ui.md §9). Controls for features that are not built yet
/// are shown disabled.
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
    @State private var confirming: OptionChange?
    @State private var isSaving = false

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
                if let held = model.syncPlan?.held, held > 0, !(model.vaultOptions?.appleWrites ?? true) {
                    Text("\(held) \(held == 1 ? "change is" : "changes are") waiting for Apple Contacts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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
                    Text("Available once the notes folder has been read.").foregroundStyle(.secondary)
                } else if isSaving {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $confirming) { change in
            OptionConfirmation(change: change) {
                confirming = nil
                Task { await save(change.options) }
            } cancel: {
                confirming = nil
            }
        }
    }

    private var optionsEnabled: Bool { model.capabilities.vaultOptions && model.vaultOptions != nil && !isSaving }

    /// Turning a switch off saves at once; turning one on asks first.
    private func optionBinding(_ keyPath: WritableKeyPath<UIVaultOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.vaultOptions?[keyPath: keyPath] ?? false },
            set: { value in
                guard var options = model.vaultOptions else { return }
                options[keyPath: keyPath] = value
                if value {
                    confirming = keyPath == \.appleWrites ? .appleWrites(options, facts) : .stamping(options, facts)
                } else {
                    Task { await save(options) }
                }
            })
    }

    private var facts: OptionChange.Facts {
        let records = model.data?.records.records.values
        return OptionChange.Facts(
            heldChanges: model.syncPlan.map { $0.hold == nil ? 0 : $0.changedInMarkdown },
            limit: model.data?.config.limits.maxAppleChanges ?? 25,
            contacts: records?.count ?? 0, cards: records?.reduce(0) { $0 + $1.cardIDs.count } ?? 0,
            devices: model.data?.deviceCount ?? 1, appleWrites: model.vaultOptions?.appleWrites ?? false)
    }

    private func save(_ options: UIVaultOptions) async {
        isSaving = true
        defer { isSaving = false }
        await model.setVaultOptions(options)
    }
}

/// Turning on a vault write switch, with what it means.
private enum OptionChange: Identifiable {
    /// Counts the confirmation shows.
    struct Facts {
        /// Apple changes the latest check holds (`nil`: no check yet).
        var heldChanges: Int?
        var limit: Int
        var contacts: Int
        var cards: Int
        var devices: Int
        var appleWrites: Bool
    }

    case appleWrites(UIVaultOptions, Facts)
    case stamping(UIVaultOptions, Facts)

    var id: String {
        switch self {
        case .appleWrites: "apple-writes"
        case .stamping: "stamping"
        }
    }

    var options: UIVaultOptions {
        switch self {
        case .appleWrites(let options, _), .stamping(let options, _): options
        }
    }

    var title: String {
        switch self {
        case .appleWrites: "Write changes back to Apple Contacts?"
        case .stamping: "Add sync IDs to your contacts?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .appleWrites: "Turn On"
        case .stamping: "Add Sync IDs"
        }
    }

    var points: [String] {
        switch self {
        case .appleWrites(_, let facts):
            var points = [
                "Edits you make in your notes are written to the matching contacts on each sync.",
                "Before any sync that changes Contacts, a vCard backup of all your contacts is saved "
                    + "(the last 10 are kept; Settings ▸ Advanced ▸ Backups).",
                "More than \(facts.limit) contacts changed in one sync wait for your approval.",
                "Nothing is deleted on its own: deletions wait in Deletions for your decision.",
            ]
            switch facts.heldChanges {
            case .some(let count) where count > 0:
                points.append(
                    "\(count) \(count == 1 ? "change is" : "changes are") waiting now and will be written "
                        + "on the next sync.")
            case .some: points.append("No changes are waiting right now.")
            case .none: points.append("Check for Changes (⇧⌘R) shows how many changes are waiting.")
            }
            return points
        case .stamping(_, let facts):
            var points = [
                "Each synced contact gets a small link (an x-c2mdsync: URL) on its card, so every device "
                    + "that shares this folder matches it to the same file.",
                "The next sync writes it onto \(facts.contacts) \(facts.contacts == 1 ? "contact" : "contacts") "
                    + "(\(facts.cards) \(facts.cards == 1 ? "card" : "cards")), after a vCard backup.",
                "It is only needed when several devices sync this folder. "
                    + (facts.devices > 1
                        ? "\(facts.devices) devices use this folder."
                        : "Only this Mac uses this folder so far, so you can leave it off."),
            ]
            if !facts.appleWrites {
                points.append("Sync IDs are written only while “Write changes back to Apple Contacts” is on.")
            }
            return points
        }
    }
}

/// The sheet confirming an `OptionChange`.
private struct OptionConfirmation: View {
    let change: OptionChange
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(change.title).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(change.points, id: \.self) { point in
                    Label {
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(change.confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
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
            LeaseSection(model: model)
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
            .help("Not available yet")
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
