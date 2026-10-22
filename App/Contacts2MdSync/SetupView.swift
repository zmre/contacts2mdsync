import Contacts2MdCLI
import SwiftUI

/// Onboarding: access, folders, a read-only preview, duplicate review, and
/// the first export (docs/ui.md §2 steps 1–5). Once the folder is
/// configured the main window (`MainView`) takes over.
struct SetupView: View {
    @Bindable var model: SetupModel
    let live: LiveSyncController
    @AppStorage(AppPreferences.showInMenuBar) private var showInMenuBar = true
    @State private var selectedCluster: String?

    var body: some View {
        Form {
            accessSection
            foldersSection
            previewSection
            if model.preview != nil, !model.duplicates.isEmpty, model.outcome == nil {
                duplicatesSection
            }
            exportSection
            if let message = model.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Set Up Contacts2MdSync")
    }

    // MARK: - Step 1

    private var accessSection: some View {
        Section {
            LabeledContent("Contacts access") {
                HStack {
                    StatusDot(done: model.isAuthorized)
                    Text(model.accessDescription)
                }
            }
            if model.canRequestAccess {
                Button("Allow Access…") { Task { await model.requestAccess() } }
            } else if !model.isAuthorized {
                Text("Contacts access is off.").foregroundStyle(.secondary)
                Button("Open System Settings") { model.openPrivacySettings() }
            }
            if model.isAuthorized {
                LabeledContent("Notes field access") {
                    Text(model.notesAccess.description).foregroundStyle(.secondary)
                }
                .help(
                    "The Contacts notes field needs an Apple entitlement; without it, note bodies stay markdown-only.")
            }
        } header: {
            StepHeader(number: 1, title: "Access", done: model.isAuthorized)
        }
    }

    // MARK: - Step 2

    private var foldersSection: some View {
        Section {
            LabeledContent("Notes root") {
                HStack {
                    Text(model.rootURL?.path(percentEncoded: false) ?? "None chosen")
                        .foregroundStyle(model.rootURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { Task { await model.chooseRoot() } }
                }
            }
            TextField("New contacts go in", text: $model.defaultFolder)
                .onSubmit { model.commitDefaultFolder() }
                .disabled(model.isConfigured)
                .help(
                    model.isConfigured
                        ? "Set in .c2mdsync/config.yaml for this folder."
                        : "A folder under the notes root for newly created notes.")
            if let error = model.folderError {
                Text(error).foregroundStyle(.red)
            }
            if let scan = model.scan {
                Text(
                    "Found \(scan.markdownFiles.formatted()) markdown files · "
                        + "\(scan.contactNotes.formatted()) look like people/orgs"
                )
                .foregroundStyle(.secondary)
            } else if model.rootURL != nil {
                Text("Existing files are scanned and matched; they are never moved.").foregroundStyle(.secondary)
            }
            if let status = model.scan?.status {
                LabeledContent("Last export") {
                    Text(status.lastExport?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }
                CountRow("Synced contacts", status.records)
                CountRow("Items needing a decision", status.pendingReview, needsReview: status.pendingReview > 0)
            }
        } header: {
            StepHeader(number: 2, title: "Folders", done: model.rootURL != nil)
        }
        .disabled(!model.isAuthorized)
    }

    // MARK: - Step 3

    private var previewSection: some View {
        Section {
            if let preview = model.preview {
                CountRow("Contacts read", preview.contactsRead)
                LabeledContent("Accounts") {
                    Text(preview.accounts.map { "\($0.name) \($0.count.formatted())" }.joined(separator: " · "))
                        .monospacedDigit()
                }
                CountRow("Groups → tags", preview.groups)
                CountRow("Matched to existing files", preview.matched)
                CountRow("Existing notes to adopt", preview.toAdopt)
                CountRow("New files to create", preview.toCreate)
                CountRow("Files with no Apple contact", preview.markdownOnly, note: "review later")
                CountRow("Possible duplicates", preview.duplicates, needsReview: preview.duplicates > 0)
                CountRow(
                    "Possible matches to review", preview.possibleMatches, needsReview: preview.possibleMatches > 0)
                if preview.otherReviews > 0 {
                    CountRow("Other items to review", preview.otherReviews, needsReview: true)
                }
                LabeledContent("Writes to Apple Contacts", value: "None (stamping is off)")
            } else {
                Text("Reads Contacts and the notes folder; writes nothing.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(model.preview == nil ? "Preview" : "Refresh Preview") { Task { await model.runPreview() } }
                    .disabled(!model.canPreview)
            }
        } header: {
            StepHeader(number: 3, title: "Preview", done: model.preview != nil)
        }
    }

    // MARK: - Step 4

    private var duplicatesSection: some View {
        Section {
            let open = model.openDuplicates
            if open.isEmpty {
                Label(
                    model.duplicatesSkipped || !model.skippedDuplicates.isEmpty
                        ? "Skipped groups produce one file each and wait in Review."
                        : "Every group is answered.",
                    systemImage: "checkmark")
            } else {
                Text(
                    "\(open.count) \(open.count == 1 ? "person appears" : "people appear") more than once. Decide "
                        + "now, or skip: each group produces one file until you decide in Review."
                )
                .foregroundStyle(.secondary)
                if open.count > 1 {
                    Picker("Group", selection: clusterBinding(open)) {
                        ForEach(open) { group in
                            Text("\(group.title) — \(group.counts)").tag(Optional(group.id))
                        }
                    }
                }
                if let group = open.first(where: { $0.id == selectedCluster }) ?? open.first {
                    ClusterDetail(actions: clusterActions, group: group)
                        .id(group.memberIdentity)
                        .frame(height: 460)
                }
                HStack {
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Button("Skip for Now") { model.skipAllDuplicates() }
                        .help("Decide later in Review; each group produces one file until then")
                }
            }
        } header: {
            StepHeader(number: 4, title: "Review Duplicates", done: model.duplicatesSettled)
        }
    }

    private func clusterBinding(_ open: [UIDuplicateGroup]) -> Binding<String?> {
        Binding(get: { selectedCluster ?? open.first?.id }, set: { selectedCluster = $0 })
    }

    /// Answers go to this Mac's decision log in the folder; the preview reruns.
    private var clusterActions: ClusterActions {
        ClusterActions(
            decide: { await model.recordDuplicate($0) }, ignore: { model.skipDuplicate($0) },
            ignoreTitle: "Skip", ignoreHelp: "Decide later in Review; this group produces one file until then",
            appliesWhen: "The first sync applies it.", openInContacts: { model.openInContacts($0) },
            revealInFinder: { model.revealInFinder($0) }, inspect: nil)
    }

    // MARK: - Step 5

    private var exportSection: some View {
        Section {
            if let outcome = model.outcome {
                Label("Export finished", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                CountRow("Created", outcome.created)
                CountRow("Adopted", outcome.adopted)
                CountRow("Updated", outcome.updated)
                if let path = outcome.contactsBackup {
                    LabeledContent("Contacts backup") { PathText(path) }
                }
                if let path = outcome.notesBackup {
                    LabeledContent("Notes backup") { PathText(path) }
                }
                ForEach(outcome.failures, id: \.self) { failure in
                    Text(failure).foregroundStyle(.red)
                }
                if outcome.pendingReview > 0 {
                    Text("\(outcome.pendingReview) items need a decision. They wait in Review.")
                        .foregroundStyle(.secondary)
                }
            }
            if let preview = model.preview, model.outcome == nil || preview.toCreate + preview.toAdopt > 0 {
                if model.outcome != nil {
                    Text("Next export would:").font(.subheadline).foregroundStyle(.secondary)
                }
                Label(
                    "\(preview.toCreate.formatted()) files will be created in \(model.defaultFolder)/",
                    systemImage: "checkmark")
                Label("\(preview.toAdopt.formatted()) existing files will gain a sync id", systemImage: "checkmark")
                Label("A backup of all contacts and of every rewritten note is saved first", systemImage: "checkmark")
            }
            if model.outcome == nil {
                Toggle("Live sync: keep Contacts and the folder in sync after the first sync", isOn: liveBinding)
                Toggle("Show in menu bar", isOn: $showInMenuBar)
            }
            HStack {
                Spacer()
                Button(model.isConfigured ? "Export Now" : "Run First Export") { Task { await model.runExport() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExport)
            }
        } header: {
            StepHeader(number: 5, title: model.isConfigured ? "Export" : "Confirm", done: model.outcome != nil)
        } footer: {
            if model.preview != nil, !model.duplicatesSettled {
                Text("Answer or skip the duplicates in step 4 first.").foregroundStyle(.secondary)
            }
        }
    }

    /// This Mac's `live_sync` (Settings ▸ General has the same switch).
    private var liveBinding: Binding<Bool> {
        Binding(get: { live.settings.liveSync }, set: { enabled in Task { await live.setLiveSync(enabled) } })
    }
}

/// `● 2  Folders` section header.
private struct StepHeader: View {
    let number: Int
    let title: String
    let done: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(done: done)
            Text("\(number)  \(title)")
        }
    }
}

#Preview {
    SetupView(model: SetupModel(), live: LiveSyncController())
}
