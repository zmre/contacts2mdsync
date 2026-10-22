import Contacts2MdCLI
import SwiftUI

/// Overview: notes outside the contact notes that still link to a renamed
/// contact's old title (architecture §8). They keep working through the
/// alias; Update Links rewrites them only when the user confirms.
struct RenamedLinksSection: View {
    let model: AppModel
    @State private var confirming: UIRenamedLinks?

    var body: some View {
        Section {
            ForEach(model.renamedLinks) { links in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(links.rename.oldTitle) is now \(links.rename.newTitle)").font(.headline)
                    Text(links.summary).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Dismiss") { Task { await model.dismissRename(links) } }
                            .help("Stop reporting this rename; the notes keep working through the old title")
                        Button("Update Links…") { confirming = links }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Renamed Contacts")
        } footer: {
            Text("Links to the old title still work: the contact note keeps it as an alias.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            confirming.map { "Update links to [[\($0.rename.oldTitle)]]?" } ?? "", isPresented: isConfirming,
            titleVisibility: .visible, presenting: confirming
        ) { links in
            Button("Update \(links.paths.count) \(links.paths.count == 1 ? "Note" : "Notes")") {
                Task { await model.updateLinks(links) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { links in
            Text(
                "[[\(links.rename.oldTitle)]] becomes [[\(links.rename.newTitle)]] in: "
                    + links.paths.prefix(10).joined(separator: ", ")
                    + (links.paths.count > 10 ? " and \(links.paths.count - 10) more" : "")
                    + ". Each note is backed up first; a note changed meanwhile is left alone.")
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }
}
