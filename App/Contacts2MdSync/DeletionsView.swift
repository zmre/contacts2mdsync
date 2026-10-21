import Contacts2MdCLI
import SwiftUI

/// Deletions (docs/ui.md §6): two queues with non-destructive defaults and a
/// destructive confirmation. Today the only entries are notes found missing
/// since the last export (shown read-only until two-way sync can act on them).
struct DeletionsView: View {
    let model: AppModel
    @State private var side = DeletionSide.contacts
    @State private var selection: Set<String> = []
    @State private var chosen: [String: DeletionOption] = [:]
    @State private var confirmingDestructive = false

    private var all: [DeletionRow] { model.deletions }
    private var rows: [DeletionRow] { all.filter { $0.side == side } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Queue", selection: $side) {
                ForEach(DeletionSide.allCases) { side in
                    Text("\(side.title) (\(all.filter { $0.side == side }.count))").tag(side)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(10)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Pending Deletions", systemImage: "checkmark.circle")
                } description: {
                    Text(
                        side == .contacts
                            ? "Contacts deleted in Apple Contacts wait here before their notes are touched."
                            : "Notes deleted from the folder wait here before anything happens in Contacts.")
                }
            } else {
                table
            }
        }
        .navigationTitle("Deletions")
        .onAppear {
            if rows.isEmpty, all.contains(where: { $0.side == .markdown }) { side = .markdown }
        }
        .toolbar {
            ToolbarItem {
                Button(applyTitle) {
                    if pending.contains(where: { $0.option.isDestructive }) {
                        confirmingDestructive = true
                    } else {
                        Task { await model.applyDeletions(pending) }
                    }
                }
                .disabled(pending.isEmpty)
                .help(model.capabilities.deletionActions ? "" : ReviewCapabilities.twoWayHelp)
            }
        }
        .alert(destructiveTitle, isPresented: $confirmingDestructive) {
            Button("Delete", role: .destructive) { Task { await model.applyDeletions(pending) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup is saved first. Files move to the Trash.")
        }
        .onChange(of: selection) {
            let row = selection.count == 1 ? all.first { selection.contains($0.id) } : nil
            model.inspect(row.map(InspectorItem.init))
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { row in Text(row.title) }
            TableColumn(side == .contacts ? "File" : "Was at") { row in
                Text(row.path ?? "—").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Noticed") { row in
                Text(row.noticed.map { UIFormat.relativeDay($0) } ?? "—").monospacedDigit()
            }
            .width(min: 110, ideal: 140)
            TableColumn("Action") { row in
                if row.isActionable {
                    Picker("Action", selection: option(for: row)) {
                        ForEach(row.options) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text("Decide after two-way sync")
                        .foregroundStyle(.secondary)
                        .help("Restore File, Unlink and Delete Apple Contact arrive with two-way sync.")
                }
            }
            .width(min: 170, ideal: 200)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = all.first(where: { $0.id == id }) {
                if side == .contacts, let path = row.path {
                    Button("Reveal in Finder") { model.revealInFinder(path: path) }
                }
                if !row.cardIDs.isEmpty {
                    Button("Open in Contacts") { model.openInContacts(cardIDs: row.cardIDs) }
                }
            }
        }
    }

    private func option(for row: DeletionRow) -> Binding<DeletionOption> {
        Binding(get: { chosen[row.id] ?? row.options[0] }, set: { chosen[row.id] = $0 })
    }

    /// Every actionable row with its (default or chosen) option.
    private var pending: [DeletionChoice] {
        all.filter(\.isActionable).map { DeletionChoice(id: $0.id, option: chosen[$0.id] ?? $0.options[0]) }
    }

    private var applyTitle: String {
        let count = pending.count
        return count == 0 ? "Apply" : "Apply \(count) \(count == 1 ? "Change" : "Changes")"
    }

    private var destructiveTitle: String {
        let names = pending.filter(\.option.isDestructive).compactMap { choice in
            all.first { $0.id == choice.id }?.title
        }
        return "Delete \(names.joined(separator: ", "))?"
    }
}
