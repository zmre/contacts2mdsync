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
                    list.frame(width: 250)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text("\(record.fields.count) \(record.fields.count == 1 ? "field" : "fields") · \(record.folderText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(record.id)
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

/// One record's fields with Keep choices.
private struct ConflictDetail: View {
    let record: UIConflictRecord
    @Binding var choices: [String: UIConflictResolution]
    let canApply: Bool
    let apply: () async -> Void
    let skip: () -> Void
    @State private var comparing: BodyComparison?

    var body: some View {
        content.sheet(item: $comparing) { comparison in
            BodyComparisonView(comparison: comparison) { comparing = nil }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.title).font(.title2.weight(.semibold))
                        Spacer()
                        Text(record.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let since = record.since {
                        Text("Changed on both sides since \(UIFormat.relativeDay(since))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Field")
                        Text("Previous")
                        Text("Contacts")
                        Text("Markdown")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(record.fields) { field in
                        Divider().gridCellColumns(4)
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(field.name).help(field.fieldPath)
                                if let label = field.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(field.previous ?? "—").foregroundStyle(.secondary)
                            Text(field.contacts)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.markdown)
                                if let contacts = field.contactsText, let markdown = field.markdownText {
                                    Button("Compare…") {
                                        comparing = BodyComparison(contacts: contacts, markdown: markdown)
                                    }
                                    .controlSize(.small)
                                    .help("Show both notes line by line")
                                }
                            }
                        }
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            Picker("Keep", selection: choice(for: field)) {
                                ForEach(field.options) { Text($0.title).tag(Optional($0)) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .gridCellColumns(3)
                        }
                    }
                }
                Text(
                    "Unchanged fields hidden. Your choice is applied on the next sync; "
                        + "changes to Contacts need “Write changes back to Apple Contacts” in Settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Menu("Choose for All Fields") {
                        ForEach(Array(UIConflictResolution.allCases.enumerated()), id: \.element) { index, resolution in
                            Button(resolution.title) { chooseAll(resolution) }
                                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Skip", action: skip)
                    Button("Apply to \(record.title)") { Task { await apply() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canApply || choices.count < record.fields.count)
                        .help(canApply ? "" : ReviewCapabilities.unsupportedHelp)
                }
            }
            .padding(20)
        }
    }

    private func choice(for field: UIConflictField) -> Binding<UIConflictResolution?> {
        Binding(get: { choices[field.id] }, set: { choices[field.id] = $0 })
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
