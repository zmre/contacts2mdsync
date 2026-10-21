import SwiftUI
import SyncEngine

/// Overview pane: Contacts permission state and a contact count.
struct OverviewView: View {
    let access: ContactsAccessModel

    var body: some View {
        Form {
            Section("Apple Contacts") {
                LabeledContent("Access", value: access.statusDescription)

                if access.isAuthorized {
                    LabeledContent("Contacts") {
                        if let count = access.contactCount {
                            Text(count, format: .number)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else if access.canRequestAccess {
                    Button("Allow Access…") {
                        Task { await access.requestAccess() }
                    }
                } else {
                    Text("Grant access in System Settings › Privacy & Security › Contacts.")
                        .foregroundStyle(.secondary)
                }

                if let message = access.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }

            Section("Sync") {
                LabeledContent("Engine", value: SyncEngine.status)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .task { await access.refresh() }
    }
}
