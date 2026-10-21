import Contacts2MdCLI
import SwiftUI

/// All Contacts: every synced record, Apple cards ↔ note path, searchable.
struct LibraryView: View {
    let model: AppModel
    @State private var query = ""
    @State private var selection: Set<UUID> = []

    private var rows: [UILibraryRow] {
        query.isEmpty ? model.libraryRows : model.libraryRows.filter { $0.matches(query) }
    }

    var body: some View {
        Group {
            if model.libraryRows.isEmpty {
                ContentUnavailableView(
                    "No Synced Contacts", systemImage: "person.crop.rectangle.stack",
                    description: Text("Contacts appear here after the first export."))
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Name") { row in Text(row.title) }
                    TableColumn("File") { row in
                        Text(row.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Accounts") { row in Text(row.accountsText).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 130)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let row = model.libraryRows.first(where: { $0.id == id }) {
                        Button("Open in Contacts") { model.openInContacts(cardIDs: row.cardIDs) }
                            .disabled(row.cardIDs.isEmpty)
                        Button("Reveal in Finder") { model.revealInFinder(path: row.path) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let row = model.libraryRows.first(where: { $0.id == id }) {
                        model.inspect(InspectorItem(row), open: true)
                    }
                }
            }
        }
        .navigationTitle("All Contacts")
        .navigationSubtitle("\(rows.count.formatted()) contacts")
        .searchable(text: $query, placement: .toolbar, prompt: "Name, file or account")
        .onChange(of: selection) {
            let row = selection.count == 1 ? model.libraryRows.first { selection.contains($0.id) } : nil
            model.inspect(row.map(InspectorItem.init))
        }
    }
}
