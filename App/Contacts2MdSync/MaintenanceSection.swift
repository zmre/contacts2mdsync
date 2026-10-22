import SwiftUI

/// Rescan Everything (confirmed) and Reset Sync State (typed confirmation;
/// the state database is backed up first). Both affect this Mac only.
struct MaintenanceSection: View {
    let model: AppModel
    @State private var confirmingRescan = false
    @State private var confirmingReset = false
    @State private var isWorking = false
    @State private var message: String?

    private var canRun: Bool { model.data?.hasSynced == true && !model.isSyncing && !isWorking }

    var body: some View {
        Section {
            HStack {
                Button("Rescan Everything…") { confirmingRescan = true }
                    .help("Forget this Mac's caches; the next sync reads every note and all of Contacts again")
                Button("Reset Sync State…", role: .destructive) { confirmingReset = true }
                    .help("Forget this Mac's sync state for this folder (backed up first)")
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }
            .disabled(!canRun)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } footer: {
            Text("Both affect this Mac only. Notes, Contacts and the decision log are not changed.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Rescan everything?", isPresented: $confirmingRescan, titleVisibility: .visible
        ) {
            Button("Rescan") { run { await model.rescanEverything() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This Mac forgets which notes it has read and its copy of Contacts, then reads every note and "
                    + "all of Contacts again. Nothing is changed in the notes folder or in Contacts.")
        }
        .sheet(isPresented: $confirmingReset) {
            ResetConfirmation(records: model.data?.records.records.count ?? 0) {
                confirmingReset = false
                run { await model.resetSyncState() }
            } cancel: {
                confirmingReset = false
            }
        }
    }

    private func run(_ work: @escaping () async -> String?) {
        isWorking = true
        message = nil
        Task {
            message = await work()
            isWorking = false
        }
    }
}

/// The reset confirmation: what is forgotten, what stays, and a typed "Reset".
private struct ResetConfirmation: View {
    let records: Int
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reset sync state for this folder?", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(
                "This Mac forgets how \(records.formatted()) notes are linked to contacts, the merge history, its "
                    + "caches and the review queue. A copy of the state database is saved to the backups folder first."
            )
            Text(
                "Your notes, Contacts and the decision log are not changed. Sync Now then runs this Mac's first "
                    + "sync again: notes are linked back by their sync ids (stamps) or by email, phone and name; "
                    + "anything unclear waits in Review, and nothing is duplicated. Live sync stops until then."
            )
            .foregroundStyle(.secondary)
            TextField("Type Reset to confirm", text: $typed)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Reset Sync State", role: .destructive, action: confirm)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).lowercased() != "reset")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 440)
    }
}
