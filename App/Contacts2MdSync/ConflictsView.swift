import Contacts2MdCLI
import SwiftUI

/// Conflicts (docs/ui.md §4): records changed on both sides, one field per
/// row with Previous / Contacts / Markdown and a Keep choice. Filled by the
/// engine once two-way sync lands; until then the list is empty.
struct ConflictsView: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var choices: [String: [String: ConflictResolution]] = [:]
    @State private var batch: ConflictResolution?

    private var records: [ConflictRecord] { model.conflicts }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView {
                    Label("No Conflicts", systemImage: "checkmark.circle")
                } description: {
                    Text(
                        model.capabilities.conflicts
                            ? "Nothing changed on both sides."
                            : "Contacts changed on both sides will wait here once two-way sync is on.")
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
                    ForEach(ConflictResolution.allCases) { resolution in
                        Button(resolution.preferenceTitle) { batch = resolution }
                    }
                }
                .disabled(selection.isEmpty || !model.capabilities.conflicts)
                .help(
                    model.capabilities.conflicts
                        ? "Resolve every selected contact the same way" : ReviewCapabilities.twoWayHelp)
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

    private var current: ConflictRecord? {
        records.first { selection.contains($0.id) } ?? records.first
    }

    private var list: some View {
        List(records, selection: $selection) { record in
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(
                    "\(record.fields.count) \(record.fields.count == 1 ? "field" : "fields") · "
                        + (record.path.split(separator: "/").dropLast().joined(separator: "/") + "/")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .tag(record.id)
        }
    }

    private func binding(for record: ConflictRecord) -> Binding<[String: ConflictResolution]> {
        Binding(get: { choices[record.id] ?? [:] }, set: { choices[record.id] = $0 })
    }

    private func advance(from record: ConflictRecord) {
        guard let index = records.firstIndex(of: record), index + 1 < records.count else { return }
        selection = [records[index + 1].id]
    }

    private func apply(_ records: [ConflictRecord]) async {
        let resolved = records.flatMap { record in
            record.fields.compactMap { field in
                choices[record.id]?[field.id].map {
                    ConflictChoice(recordID: record.id, fieldID: field.id, resolution: $0)
                }
            }
        }
        guard !resolved.isEmpty else { return }
        await model.resolve(resolved)
    }

    // MARK: - Batch

    private var selectedRecords: [ConflictRecord] { records.filter { selection.contains($0.id) } }

    private var isBatchConfirming: Binding<Bool> {
        Binding(get: { batch != nil }, set: { if !$0 { batch = nil } })
    }

    private var batchTitle: String {
        let fields = selectedRecords.reduce(0) { $0 + $1.fields.count }
        return "Apply “\(batch?.preferenceTitle ?? "")” to \(selectedRecords.count) contacts (\(fields) fields)?"
    }

    private func applyBatch() async {
        guard let batch else { return }
        for record in selectedRecords {
            var picked: [String: ConflictResolution] = [:]
            for field in record.fields {
                picked[field.id] = field.options.contains(batch) ? batch : field.options.first
            }
            choices[record.id] = picked
        }
        await apply(selectedRecords)
    }
}

/// One record's fields with Keep choices.
private struct ConflictDetail: View {
    let record: ConflictRecord
    @Binding var choices: [String: ConflictResolution]
    let canApply: Bool
    let apply: () async -> Void
    let skip: () -> Void

    var body: some View {
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
                                Text(field.name)
                                if let label = field.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(field.previous ?? "—").foregroundStyle(.secondary)
                            Text(field.contacts)
                            Text(field.markdown)
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
                Text("Unchanged fields hidden.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Menu("Choose for All Fields") {
                        ForEach(Array(ConflictResolution.allCases.enumerated()), id: \.element) { index, resolution in
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
                        .help(canApply ? "" : ReviewCapabilities.twoWayHelp)
                }
            }
            .padding(20)
        }
    }

    private func choice(for field: ConflictField) -> Binding<ConflictResolution?> {
        Binding(get: { choices[field.id] }, set: { choices[field.id] = $0 })
    }

    private func chooseAll(_ resolution: ConflictResolution) {
        for field in record.fields where field.options.contains(resolution) {
            choices[field.id] = resolution
        }
    }
}
