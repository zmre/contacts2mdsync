import Contacts2MdCLI
import SwiftUI

/// The inspector (⌥⌘I): card summary, file, sync id, accounts, and
/// Open in Contacts / Reveal in Finder.
struct InspectorView: View {
    let model: AppModel

    var body: some View {
        if let item = model.inspected {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline).textSelection(.enabled)
                        if let subtitle = item.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    if let path = item.path {
                        LabeledContent("File") { PathText(path) }
                    }
                    if let id = item.syncID {
                        LabeledContent("Sync ID") {
                            Text(id.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let accounts = item.accounts, !accounts.isEmpty {
                        LabeledContent("Accounts", value: accounts)
                    }
                    ForEach(item.details, id: \.self) { detail in
                        if detail.label.isEmpty {
                            Text(detail.value).textSelection(.enabled)
                        } else {
                            LabeledContent(detail.label) { Text(detail.value).textSelection(.enabled) }
                        }
                    }
                }
                if let changes = item.changes {
                    Section("Changes") {
                        if changes.isEmpty {
                            Text("Nothing changed.").foregroundStyle(.secondary)
                        }
                        ForEach(changes) { change in
                            ChangeRow(model: model, change: change)
                        }
                    }
                } else {
                    Section {
                        Button("Open in Contacts") { model.openInContacts(cardIDs: item.cardIDs) }
                            .disabled(item.cardIDs.isEmpty)
                        Button("Reveal in Finder") {
                            if let path = item.path { model.revealInFinder(path: path) }
                        }
                        .disabled(item.path == nil)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Selection", systemImage: "sidebar.trailing",
                description: Text("Select a contact, file or card to see its details."))
        }
    }
}

/// One change of a run: what changed where, with Reveal / Open.
private struct ChangeRow: View {
    let model: AppModel
    let change: UIActivityChange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.text).textSelection(.enabled)
            HStack {
                Text(change.side).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let path = change.path {
                    Button("Reveal") { model.revealInFinder(path: path) }
                        .help("Reveal in Finder")
                }
                if !change.cardIDs.isEmpty {
                    Button("Open") { model.openInContacts(cardIDs: change.cardIDs) }
                        .help("Open in Contacts")
                }
            }
            .controlSize(.small)
        }
    }
}
