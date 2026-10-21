import Contacts2MdCLI
import SwiftUI

/// Markdown Only (docs/ui.md §5): contact notes with no Apple contact, with
/// possible matches (M2 adoption proposals). Choose an action per row, tick
/// the rows, then Apply.
struct MarkdownOnlyView: View {
    let model: AppModel
    @State private var showIgnored = false
    @State private var selection: Set<String> = []
    @State private var checked: Set<String> = []
    @State private var actions: [String: UIMarkdownOnlyAction] = [:]
    @State private var isApplying = false

    private var allRows: [UIMarkdownOnlyRow] { model.queues?.markdownOnly ?? [] }
    private var rows: [UIMarkdownOnlyRow] { allRows.filter { showIgnored || !$0.isIgnored } }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Markdown-Only Files", systemImage: "checkmark.circle")
                } description: {
                    Text(emptyDescription)
                }
            } else {
                table
            }
        }
        .navigationTitle("Markdown Only")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Toggle("Show Ignored", isOn: $showIgnored)
                    .toggleStyle(.checkbox)
                    .help("Show notes you chose to ignore")
                Button("Add to Contacts") {}
                    .disabled(true)
                    .help(ReviewCapabilities.twoWayHelp)
                Button(applyTitle) { Task { await apply() } }
                    .disabled(applicable.isEmpty || isApplying)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onChange(of: selection) {
            let row = selection.count == 1 ? allRows.first { selection.contains($0.id) } : nil
            model.inspect(row.map(InspectorItem.init))
        }
    }

    private var emptyDescription: String {
        let ignored = allRows.filter(\.isIgnored).count
        let base = "Every contact note is linked to an Apple contact."
        return ignored > 0 ? base + " \(ignored) ignored (Show Ignored to see them)." : base
    }

    private var subtitle: String {
        let open = allRows.filter(\.needsReview).count
        return "\(open.formatted()) \(open == 1 ? "file has" : "files have") no Apple contact"
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { row in
                Toggle("Include", isOn: checkedBinding(row))
                    .labelsHidden()
                    .disabled(!row.needsReview || decisions(for: row).isEmpty)
            }
            .width(22)
            TableColumn("Name") { row in
                Text(row.title)
                    .foregroundStyle(row.isIgnored ? .secondary : .primary)
                    .help(row.path)
            }
            TableColumn("Kind") { row in
                Text(row.kind == .organization ? "Org" : "Person").foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60, max: 80)
            TableColumn("Folder") { row in
                Text(row.folder.isEmpty ? "/" : row.folder + "/").foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn("Possible match") { row in
                if let match = row.bestMatch {
                    ConfidenceText(title: match.title, confidence: match.confidence)
                        .help(match.reasons.joined(separator: ", "))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            TableColumn("Action") { row in actionCell(row) }
                .width(min: 150, ideal: 190)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, ids.count == 1, let row = allRows.first(where: { $0.id == id }) {
                Button("Reveal in Finder") { model.revealInFinder(path: row.path) }
                if let match = row.bestMatch {
                    Button("Open “\(match.title)” in Contacts") { model.openInContacts(cardIDs: match.contact.cardIDs) }
                }
            }
        }
    }

    @ViewBuilder private func actionCell(_ row: UIMarkdownOnlyRow) -> some View {
        if row.isIgnored {
            Text("Ignored").foregroundStyle(.secondary)
        } else if let note = row.decidedNote {
            Text(note).foregroundStyle(.secondary).lineLimit(1).help(note)
        } else {
            Menu(title(of: action(for: row))) {
                Button("No Action") { set(.leave, for: row) }
                Button("Add to Contacts") {}
                    .disabled(!model.capabilities.addToContacts)
                    .help(ReviewCapabilities.twoWayHelp)
                if !row.matches.isEmpty { Divider() }
                ForEach(row.matches) { match in
                    Button("Link to “\(match.title)”") { set(.link(itemID: match.id), for: row) }
                    Button("Not “\(match.title)”") { set(.notThisPerson(itemID: match.id), for: row) }
                }
                Divider()
                Button("Ignore") { set(.ignore, for: row) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Staged actions

    private func action(for row: UIMarkdownOnlyRow) -> UIMarkdownOnlyAction {
        actions[row.id] ?? row.defaultAction
    }

    private func decisions(for row: UIMarkdownOnlyRow) -> [UIReviewDecision] {
        action(for: row).decisions(for: row)
    }

    private func set(_ action: UIMarkdownOnlyAction, for row: UIMarkdownOnlyRow) {
        actions[row.id] = action
        if action.decisions(for: row).isEmpty {
            checked.remove(row.id)
        } else {
            checked.insert(row.id)
        }
    }

    private func checkedBinding(_ row: UIMarkdownOnlyRow) -> Binding<Bool> {
        Binding(
            get: { checked.contains(row.id) },
            set: { isOn in
                if isOn { checked.insert(row.id) } else { checked.remove(row.id) }
            })
    }

    private func title(of action: UIMarkdownOnlyAction) -> String {
        switch action {
        case .leave: "No Action"
        case .link: "Link"
        case .notThisPerson: "Not This Person"
        case .ignore: "Ignore"
        case .addToContacts: "Add"
        }
    }

    /// Checked rows that still need review and produce decisions.
    private var applicable: [UIMarkdownOnlyRow] {
        rows.filter { checked.contains($0.id) && $0.needsReview && !decisions(for: $0).isEmpty }
    }

    private var applyTitle: String {
        let count = applicable.count
        return count == 0 ? "Apply" : "Apply \(count) \(count == 1 ? "Change" : "Changes")"
    }

    private func apply() async {
        let rows = applicable
        isApplying = true
        defer { isApplying = false }
        if await model.decide(rows.flatMap { decisions(for: $0) }) {
            for row in rows {
                checked.remove(row.id)
                actions[row.id] = nil
            }
        }
    }
}
