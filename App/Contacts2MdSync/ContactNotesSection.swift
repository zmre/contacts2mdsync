import AppKit
import ContactModel
import Contacts2MdCLI
import ContactsAdapter
import Observation
import SwiftUI
import SyncEngine

/// This Mac's Contact notes setting and Automation permission (Settings ▸
/// Advanced ▸ Contact notes, architecture §8). Turning notes on asks macOS
/// for permission to control Contacts.app; nothing else ever prompts.
@MainActor
@Observable
final class ContactNotesModel {
    private(set) var settings: NotesSettings
    /// `unknown` until Contacts.app runs (macOS only answers for a running app).
    private(set) var permission = NotesPermission.unknown
    private(set) var isAsking = false

    @ObservationIgnored private let store = NotesSettingsStore(directory: CLIEnvironment.live().stateDirectory)

    init() { settings = store.load() }

    /// Re-reads the setting and the permission (no launch, no prompt).
    func refresh() async {
        settings = store.load()
        let quit = settings.quitContactsAfterSync
        permission = await Task.detached {
            ScriptingNotesProvider(quitWhenDone: quit).currentPermission()
        }.value
    }

    /// Saves `notes_sync`; turning it on asks for permission (the macOS
    /// prompt, once) and returns the answer.
    @discardableResult
    func setNotesSync(_ enabled: Bool) async -> NotesPermission {
        settings.notesSync = enabled
        save()
        guard enabled else { return permission }
        isAsking = true
        defer { isAsking = false }
        let quit = settings.quitContactsAfterSync
        let answer = await Task.detached { () -> NotesAvailability in
            let provider = ScriptingNotesProvider(quitWhenDone: quit)
            defer { provider.finishSession() }  // quits Contacts.app if it was opened for this
            return provider.requestPermission()
        }.value
        switch answer {
        case .scripting(let state): permission = state
        case .entitlement: permission = .granted
        case .unavailable: permission = .unknown
        }
        return permission
    }

    func setQuitContacts(_ quit: Bool) {
        settings.quitContactsAfterSync = quit
        save()
    }

    private func save() {
        do {
            try store.save(settings)
        } catch {
            NSSound.beep()
        }
    }

    /// System Settings ▸ Privacy & Security ▸ Automation.
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Settings ▸ Advanced ▸ Contact notes.
struct ContactNotesSection: View {
    let model: AppModel
    @State private var notes = ContactNotesModel()
    @State private var sheet: NotesSheet?

    private var entitled: Bool { model.setup.notesAccess == .available }

    var body: some View {
        Section {
            LabeledContent("Source") {
                HStack(spacing: 6) {
                    MeaningDot(color: sourceColor)
                    Text(sourceText)
                }
            }
            if !entitled {
                Toggle("Sync notes through Contacts.app", isOn: notesBinding)
                    .disabled(notes.isAsking)
                if notes.settings.notesSync {
                    LabeledContent("Automation permission") {
                        HStack(spacing: 8) {
                            Text(permissionText).foregroundStyle(notes.permission == .denied ? .orange : .secondary)
                            if notes.permission == .denied {
                                Button("Open Privacy Settings…") { notes.openAutomationSettings() }
                            } else if notes.permission != .granted {
                                Button("Ask Again") { Task { await ask() } }
                                    .disabled(notes.isAsking)
                            }
                            Button("Check Again") { Task { await notes.refresh() } }
                        }
                    }
                    Toggle("Quit Contacts.app after syncing when it was opened for the sync", isOn: quitBinding)
                }
            }
        } header: {
            Text("Contact notes")
        } footer: {
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await notes.refresh() }
        .sheet(item: $sheet) { sheet in
            NotesSheetView(sheet: sheet, model: model, notes: notes) { next in self.sheet = next }
        }
    }

    private var sourceText: String {
        if entitled { return "Contacts entitlement" }
        guard notes.settings.notesSync else { return "Off — note bodies stay markdown-only" }
        return notes.permission == .denied ? "Contacts.app scripting (not permitted)" : "Contacts.app scripting"
    }

    private var sourceColor: Color {
        if entitled { return .green }
        guard notes.settings.notesSync else { return .gray }
        return notes.permission == .granted ? .green : notes.permission == .denied ? .orange : .yellow
    }

    private var permissionText: String {
        switch notes.permission {
        case .granted: "Granted"
        case .notDetermined: "Not asked yet"
        case .denied: "Denied"
        case .unknown: "Not known until Contacts.app runs"
        }
    }

    private var explanation: String {
        if entitled {
            return "This build reads and writes the Notes field directly. Note bodies sync with Contacts notes."
        }
        return "Without Apple's notes entitlement, Contacts2MdSync can sync note bodies by controlling "
            + "Contacts.app: during a sync it opens Contacts.app hidden, reads every card's note in one go "
            + "(about half a second), writes changed notes card by card, and quits it again. "
            + "Scheduled and command-line syncs never ask; without permission they skip notes."
    }

    private var notesBinding: Binding<Bool> {
        Binding(
            get: { notes.settings.notesSync },
            set: { enabled in
                if enabled {
                    sheet = .explain
                } else {
                    Task {
                        await notes.setNotesSync(false)
                        await model.check()
                    }
                }
            })
    }

    private var quitBinding: Binding<Bool> {
        Binding(get: { notes.settings.quitContactsAfterSync }, set: { notes.setQuitContacts($0) })
    }

    private func ask() async {
        let answer = await notes.setNotesSync(true)
        if answer == .granted { await model.check() }
    }
}

/// The sheets of turning notes on: what happens, then the answer.
enum NotesSheet: String, Identifiable {
    /// What turning notes on does; Continue asks macOS.
    case explain
    /// Permission granted: the first notes sync, previewed.
    case granted
    /// Permission refused: how to allow it later.
    case denied

    var id: String { rawValue }
}

private struct NotesSheetView: View {
    let sheet: NotesSheet
    let model: AppModel
    let notes: ContactNotesModel
    let next: (NotesSheet?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch sheet {
            case .explain: explain
            case .granted: granted
            case .denied: denied
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var explain: some View {
        Group {
            Text("Sync notes through Contacts.app?").font(.title3.weight(.semibold))
            points([
                "Contacts2MdSync controls Contacts.app to read and write the Notes field of your contacts. "
                    + "macOS asks you once to allow this (“Contacts2MdSync wants to control Contacts”).",
                "During a sync, Contacts.app is opened hidden if it isn't running, and quit afterwards.",
                "Notes are per card: a linked contact's note is its iCloud card's note; a changed markdown body "
                    + "is written to every card you can edit.",
                "The first sync with notes compares every note with its markdown body: a note goes into an "
                    + "empty body, a body into an empty note, equal texts are kept, and different texts wait "
                    + "in Conflicts (Keep Contacts, Keep Markdown or Keep Both). You see a preview first.",
            ])
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { next(nil) }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    Task {
                        let answer = await notes.setNotesSync(true)
                        guard answer == .granted else {
                            next(.denied)
                            return
                        }
                        // The preview fills in when the dry run finishes; never wait for it here.
                        next(.granted)
                        await model.check()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(notes.isAsking)
            }
        }
    }

    private var granted: some View {
        Group {
            Text("Contact notes are on").font(.title3.weight(.semibold))
            if model.phase == .checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.runProgress?.text ?? "Updating the preview…").foregroundStyle(.secondary)
                }
            }
            if let plan = model.syncPlan, plan.notes.isActive {
                let baseline = plan.notesBaseline
                Text(plan.notes.freshStart ? "The first sync with notes will:" : "The next sync will:")
                points([
                    "copy \(baseline.toMarkdown.count) Contacts notes into empty markdown bodies",
                    "write \(baseline.toContacts.count) markdown bodies into empty Contacts notes"
                        + (plan.appleWritesEnabled ? "" : " (held until “Write changes back to Apple Contacts” is on)"),
                    "keep \(baseline.adopted) notes that already match",
                    "list \(baseline.conflicts.count) different notes in Conflicts",
                ])
                if !baseline.toContacts.isEmpty {
                    Text("Markdown bodies going into Contacts").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Self.largestFirst(baseline.toContacts), id: \.recordID) { item in
                                HStack {
                                    Text(item.title).lineLimit(1)
                                    Spacer()
                                    Text("\(item.characters.formatted()) chars, \(item.lines) lines")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .help(item.path)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            } else if model.phase != .checking {
                Text("Check for Changes (⇧⌘R) shows what the first sync with notes will do.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Later") { next(nil) }.keyboardShortcut(.cancelAction)
                Button("Sync Now") {
                    next(nil)
                    // Waits for the preview's dry run if it is still running.
                    Task { await model.syncNow() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.feedback != nil)
            }
        }
    }

    private var denied: some View {
        Group {
            Text("Contacts2MdSync may not control Contacts").font(.title3.weight(.semibold))
            Text(
                "Notes stay on, but syncs skip them until you allow it: System Settings ▸ Privacy & Security ▸ "
                    + "Automation ▸ Contacts2MdSync ▸ turn on Contacts. Then use Check Again here."
            )
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { next(nil) }.keyboardShortcut(.cancelAction)
                Button("Open Privacy Settings…") {
                    notes.openAutomationSettings()
                    next(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func largestFirst(_ items: [NotesBaselineItem]) -> [NotesBaselineItem] {
        items.sorted { $0.characters > $1.characters }
    }

    private func points(_ texts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(texts, id: \.self) { text in
                Label {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
