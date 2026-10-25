import Contacts2MdCLI
import SwiftUI

/// Conflicts (docs/ui.md §4): records changed on both sides, one field per
/// row with Previous / Contacts / Markdown and a Keep choice. Choices are
/// recorded as decisions; the next sync applies them while both sides still
/// hold the values they were made against (else the conflict comes back).
struct ConflictsView: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var choices: [String: [String: UIConflictResolution]] = [:]
    @State private var batch: UIConflictResolution?

    private var records: [UIConflictRecord] { model.conflicts }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView {
                    Label("No Conflicts", systemImage: "checkmark.circle")
                } description: {
                    Text(
                        "Nothing changed on both sides. Resolved conflicts are applied by the next sync.")
                }
            } else {
                HStack(spacing: 0) {
                    list.frame(minWidth: 200, idealWidth: 240, maxWidth: 240)
                    Divider()
                    if let record = current {
                        ConflictDetail(
                            record: record, choices: binding(for: record),
                            canApply: model.capabilities.conflicts
                        ) {
                            await apply([record])
                        } skip: {
                            advance(from: record)
                        }
                        .id(record.id)
                        // Never wider than the space left: an HStack wider than
                        // the detail column is centred and slides under the sidebar.
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .navigationTitle("Conflicts")
        .toolbar {
            ToolbarItem {
                Menu("Resolve Selected") {
                    ForEach(UIConflictResolution.allCases) { resolution in
                        Button(resolution.preferenceTitle) { batch = resolution }
                    }
                }
                .disabled(selection.isEmpty || !model.capabilities.conflicts)
                .help(
                    model.capabilities.conflicts
                        ? "Resolve every selected contact the same way" : ReviewCapabilities.unsupportedHelp)
            }
        }
        .confirmationDialog(batchTitle, isPresented: isBatchConfirming, titleVisibility: .visible) {
            Button(batch?.preferenceTitle ?? "Apply") { Task { await applyBatch() } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: selection) {
            model.inspect(current.map(InspectorItem.init))
        }
    }

    private var current: UIConflictRecord? {
        records.first { selection.contains($0.id) } ?? records.first
    }

    private var list: some View {
        List(records, selection: $selection) { record in
            ConflictRow(record: record).tag(record.id)
        }
    }

    private func binding(for record: UIConflictRecord) -> Binding<[String: UIConflictResolution]> {
        Binding(get: { choices[record.id] ?? [:] }, set: { choices[record.id] = $0 })
    }

    private func advance(from record: UIConflictRecord) {
        guard let index = records.firstIndex(of: record), index + 1 < records.count else { return }
        selection = [records[index + 1].id]
    }

    private func apply(_ records: [UIConflictRecord]) async {
        let resolved = records.flatMap { record in
            record.fields.compactMap { field in
                choices[record.id]?[field.id].map {
                    UIConflictChoice(recordID: record.id, fieldID: field.id, resolution: $0)
                }
            }
        }
        guard !resolved.isEmpty else { return }
        if await model.resolve(resolved) {
            for record in records { choices[record.id] = nil }
        }
    }

    // MARK: - Batch

    private var selectedRecords: [UIConflictRecord] { records.filter { selection.contains($0.id) } }

    private var isBatchConfirming: Binding<Bool> {
        Binding(get: { batch != nil }, set: { if !$0 { batch = nil } })
    }

    private var batchTitle: String {
        guard let batch else { return "" }
        let fields = selectedRecords.reduce(0) { $0 + $1.choices(preferring: batch).count }
        let contacts = selectedRecords.count
        return "Apply “\(batch.preferenceTitle)” to \(contacts) \(contacts == 1 ? "contact" : "contacts") "
            + "(\(fields) \(fields == 1 ? "field" : "fields"))?"
    }

    /// Fields that do not offer the preference (Keep Both on scalars) stay undecided.
    private func applyBatch() async {
        guard let batch else { return }
        let picked = selectedRecords.flatMap { $0.choices(preferring: batch) }
        guard !picked.isEmpty else { return }
        await model.resolve(picked)
    }
}

/// A row of the conflicts list: name, what changed on which side, when, folder.
private struct ConflictRow: View {
    let record: UIConflictRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.title).lineLimit(1)
            Text(record.listSummary)
                .font(.caption)
                .lineLimit(2)
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .help(record.changeLines())
    }

    /// `2 fields · Since Today 9:02 AM · Work/`.
    private var details: String {
        let count = record.fields.count
        var parts = ["\(count) \(count == 1 ? "field" : "fields")"]
        if let since = record.since { parts.append("Since \(UIFormat.relativeDay(since))") }
        parts.append(record.folderText)
        return parts.joined(separator: " · ")
    }
}

/// One record's fields with Keep choices. Lays out inside the detail column
/// at any width: the field table stacks below `ConflictFieldsView.tableWidth`
/// and the action bar wraps.
private struct ConflictDetail: View {
    let record: UIConflictRecord
    @Binding var choices: [String: UIConflictResolution]
    let canApply: Bool
    let apply: () async -> Void
    let skip: () -> Void
    @State private var comparing: BodyComparison?
    @State private var isCompact = false

    var body: some View {
        content.sheet(item: $comparing) { comparison in
            BodyComparisonView(comparison: comparison) { comparing = nil }
        }
    }

    private var content: some View {
        // Captured, not read inside the (Sendable) geometry closure.
        let compactBelow = ConflictFieldsView.tableWidth + 2 * Self.padding
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ConflictFieldsView(fields: record.fields, isCompact: isCompact, choices: $choices) { field in
                    if let contacts = field.contactsText, let markdown = field.markdownText {
                        comparing = BodyComparison(contacts: contacts, markdown: markdown)
                    }
                }
                Text(
                    "Unchanged fields hidden. Your choice is applied on the next sync; "
                        + "changes to Contacts need “Write changes back to Apple Contacts” in Settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                actionBar
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < compactBelow
        } action: {
            isCompact = $0
        }
    }

    private static let padding: CGFloat = 20

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title).font(.title2.weight(.semibold)).lineLimit(2)
            Text(record.path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(record.path)
            Text(changedLine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var changedLine: String {
        let count = record.fields.count
        let fields = count == 1 ? "1 field" : "\(count) fields"
        let since = record.since.map { " since \(UIFormat.relativeDay($0))" } ?? ""
        return "\(fields) changed in both Contacts and Markdown\(since). Choose what to keep for each."
    }

    /// Choose for All Fields on the left, Skip / Apply on the right; when the
    /// column is narrow they wrap instead (one copy each, so the ⌘1–3 and
    /// ⌘↩ shortcuts are registered once).
    @ViewBuilder private var actionBar: some View {
        if isCompact {
            FlowLayout {
                chooseAllMenu
                Button("Skip", action: skip)
                applyButton
            }
        } else {
            HStack {
                chooseAllMenu
                Spacer()
                Button("Skip", action: skip)
                applyButton
            }
        }
    }

    private var chooseAllMenu: some View {
        Menu("Choose for All Fields") {
            ForEach(Array(UIConflictResolution.allCases.enumerated()), id: \.element) { index, resolution in
                Button(resolution.title) { chooseAll(resolution) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .fixedSize()
    }

    private var applyButton: some View {
        Button {
            Task { await apply() }
        } label: {
            Text("Apply to \(record.title)").lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canApply || choices.count < record.fields.count)
        .help(canApply ? "Record these choices; the next sync applies them" : ReviewCapabilities.unsupportedHelp)
    }

    private func chooseAll(_ resolution: UIConflictResolution) {
        for field in record.fields where field.options.contains(resolution) {
            choices[field.id] = resolution
        }
    }
}

/// Both texts of a note body conflict.
private struct BodyComparison: Identifiable {
    let id = UUID()
    let contacts: String
    let markdown: String
}

/// A note body conflict line by line: lines in both texts once, lines only
/// in the markdown body marked −, lines only in the Contacts note marked +.
/// Scrolls for long notes (Contacts notes reach ~50,000 characters).
private struct BodyComparisonView: View {
    let comparison: BodyComparison
    let done: () -> Void

    private var lines: [UIDiffLine] {
        UITextDiff.lines(markdown: comparison.markdown, contacts: comparison.contacts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes: Markdown vs Contacts").font(.title3.weight(.semibold))
            HStack(spacing: 16) {
                Label("only in Markdown", systemImage: "minus.square.fill").foregroundStyle(.red)
                Label("only in Contacts", systemImage: "plus.square.fill").foregroundStyle(.green)
            }
            .font(.caption)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marker(line.side)).foregroundStyle(.secondary)
                            Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                        }
                        .font(.body.monospaced())
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.side))
                    }
                }
            }
            .frame(minHeight: 280)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("Keep Both writes the markdown text, a --- line, then the Contacts text, to both sides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 560)
    }

    private func marker(_ side: UIDiffLine.Side) -> String {
        switch side {
        case .both: " "
        case .markdown: "−"
        case .contacts: "+"
        }
    }

    private func background(_ side: UIDiffLine.Side) -> Color {
        switch side {
        case .both: .clear
        case .markdown: .red.opacity(0.12)
        case .contacts: .green.opacity(0.12)
        }
    }
}

// MARK: - Previews

private enum ConflictPreviewData {
    static let body =
        "Met at the 2019 conference in Lisbon; talked about distributed systems and the office move.\n"
        + "Follow up about the contract renewal before the end of the quarter."

    static let record = UIConflictRecord(
        recordID: UUID(), title: "Jane Doe", path: "Work/Clients/Europe/Jane Doe.md",
        since: Date(timeIntervalSinceNow: -3 * 86_400), cardIDs: [],
        fields: [
            UIConflictField(
                id: "conflict-job", name: "Job", previous: "Engineer", contacts: "Senior Engineer",
                markdown: "Staff Engineer, Platform Infrastructure and Developer Productivity",
                options: [.keepContacts, .keepMarkdown], fieldPath: "job_title",
                since: Date(timeIntervalSinceNow: -3 * 86_400)),
            UIConflictField(
                id: "conflict-phone", name: "Phone", label: "mobile", previous: "+1 555 0100",
                contacts: "+1 555 0199", markdown: UIConflictField.removedText,
                options: [.keepContacts, .keepMarkdown, .keepBoth], fieldPath: "phones[mobile]",
                since: Date(timeIntervalSinceNow: -86_400)),
            UIConflictField(
                id: "conflict-body", name: "Notes", previous: nil, contacts: "Met at the 2019 conference in Lisbon…",
                markdown: "Met at the 2019 conference in Lisbon (edited)…",
                options: [.keepContacts, .keepMarkdown, .keepBoth], fieldPath: "body",
                contactsText: body, markdownText: body + "\nAlso: prefers email."),
        ])
}

/// The Conflicts screen's list + detail in a detail column of `width`.
private struct ConflictPreview: View {
    let width: CGFloat
    @State private var choices: [String: UIConflictResolution] = [:]

    var body: some View {
        HStack(spacing: 0) {
            List([ConflictPreviewData.record]) { ConflictRow(record: $0) }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 240)
            Divider()
            ConflictDetail(record: ConflictPreviewData.record, choices: $choices, canApply: true) {
            } skip: {
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: 640)
    }
}

#Preview("Conflicts, wide") { ConflictPreview(width: 1_100) }
#Preview("Conflicts, narrow") { ConflictPreview(width: 560) }
#Preview("Conflicts, inspector open at minimum width") { ConflictPreview(width: 380) }
