import Contacts2MdCLI
import SwiftUI

/// Deletions (docs/ui.md §6): two queues with non-destructive defaults and a
/// destructive confirmation. Choices are recorded as decisions; the next
/// sync carries them out (backups first).
struct DeletionsView: View {
    let model: AppModel
    @State private var side = UIDeletionSide.contacts
    @State private var selection: Set<String> = []
    @State private var chosen: [String: UIDeletionOption] = [:]
    @State private var confirmingDestructive = false
    @State private var isApplying = false

    private var all: [UIDeletionRow] { model.deletions }
    private var rows: [UIDeletionRow] { all.filter { $0.side == side } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Queue", selection: $side) {
                ForEach(UIDeletionSide.allCases) { side in
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
                footer
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
                        Task { await apply() }
                    }
                }
                .disabled(pending.isEmpty || isApplying || !model.capabilities.deletionActions)
                .help("Record these choices; the next sync carries them out")
            }
        }
        .alert(destructiveTitle, isPresented: $confirmingDestructive) {
            Button("Delete", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(destructiveMessage)
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
                    Text("Decide after the next sync")
                        .foregroundStyle(.secondary)
                        .help("Found missing by an export. Sync Now once, then choose Restore File, Unlink or Delete.")
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

    @ViewBuilder private var footer: some View {
        if !(model.vaultOptions?.appleWrites ?? false), pending.contains(where: { $0.option.writesToContacts }) {
            Divider()
            Label(
                "Restore Contact and Delete Apple Contact wait until writing to Apple Contacts is on in Settings.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func option(for row: UIDeletionRow) -> Binding<UIDeletionOption> {
        Binding(get: { chosen[row.id] ?? row.options[0] }, set: { chosen[row.id] = $0 })
    }

    /// Every actionable row with its (default or chosen) option.
    private var pending: [UIDeletionChoice] {
        all.filter(\.isActionable).map { UIDeletionChoice(id: $0.id, option: chosen[$0.id] ?? $0.options[0]) }
    }

    private var applyTitle: String {
        let count = pending.count
        return count == 0 ? "Apply" : "Apply \(count) \(count == 1 ? "Change" : "Changes")"
    }

    private func apply() async {
        let choices = pending
        isApplying = true
        defer { isApplying = false }
        if await model.applyDeletions(choices) {
            for choice in choices { chosen[choice.id] = nil }
        }
    }

    // MARK: - Destructive confirmation

    private var destructiveRows: [(UIDeletionRow, UIDeletionOption)] {
        pending.filter(\.option.isDestructive).compactMap { choice in
            all.first { $0.id == choice.id }.map { ($0, choice.option) }
        }
    }

    private var destructiveTitle: String {
        "Delete \(destructiveRows.map(\.0.title).joined(separator: ", "))?"
    }

    /// Names exactly what goes: which files move to the Trash, and which
    /// contacts lose every card in an account this Mac can write.
    private var destructiveMessage: String {
        var lines: [String] = []
        let files = destructiveRows.filter { $0.1 == .deleteFile }.compactMap(\.0.path)
        if !files.isEmpty {
            lines.append("Moved to the Trash: \(files.joined(separator: ", ")).")
        }
        let contacts = destructiveRows.filter { $0.1 == .deleteAppleContact }.map(\.0)
        if !contacts.isEmpty {
            let names = contacts.map { row in
                row.accountsText.isEmpty ? row.title : "\(row.title) (\(row.accountsText))"
            }
            lines.append(
                "Deleted from Contacts: \(names.joined(separator: ", ")). Every card of the contact that this "
                    + "Mac can write to is deleted; cards in read-only accounts stay.")
        }
        lines.append("Carried out by the next sync. A vCard backup of all contacts is saved first.")
        return lines.joined(separator: "\n\n")
    }
}
