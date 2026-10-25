import Contacts2MdCLI
import SwiftUI

/// The conflicting fields of one record (docs/ui.md §4), with the Keep
/// choice and what each side changed under every field.
///
/// Wide: a Field / Previous / Contacts / Markdown table. Compact (a narrow
/// detail column, e.g. with the inspector open): one block per field with
/// the three values stacked. Either way the value columns share whatever
/// width there is and truncate (full text in the tooltip; note bodies in
/// Compare…), so the screen never grows wider than the detail column.
struct ConflictFieldsView: View {
    let fields: [UIConflictField]
    let isCompact: Bool
    @Binding var choices: [String: UIConflictResolution]
    /// Compare… on a note body conflict.
    let compare: (UIConflictField) -> Void

    /// Width of the table's Field column.
    static let nameWidth: CGFloat = 120
    static let columnSpacing: CGFloat = 16
    /// Narrowest content width that still fits the four-column table.
    static let tableWidth: CGFloat = 560

    var body: some View {
        if isCompact { stacked } else { table }
    }

    // MARK: - Wide

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Self.columnSpacing) {
                Text("Field").frame(width: Self.nameWidth, alignment: .leading)
                ForEach(["Previous", "Contacts", "Markdown"], id: \.self) { title in
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            ForEach(fields) { field in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.name).help(field.fieldPath)
                            if let label = field.label { Text(label).font(.caption).foregroundStyle(.secondary) }
                            compareButton(field)
                        }
                        .frame(width: Self.nameWidth, alignment: .leading)
                        ConflictValue(side: "Previous", text: field.previous, isSecondary: true)
                        ConflictValue(side: "Contacts", text: field.contacts)
                        ConflictValue(side: "Markdown", text: field.markdown)
                    }
                    resolution(field).padding(.leading, Self.nameWidth + Self.columnSpacing)
                }
            }
        }
    }

    // MARK: - Compact

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(fields) { field in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.title).fontWeight(.semibold).lineLimit(2).help(field.fieldPath)
                        Spacer(minLength: 8)
                        compareButton(field)
                    }
                    sideRow("Previous", field.previous, isSecondary: true)
                    sideRow("Contacts", field.contacts)
                    sideRow("Markdown", field.markdown)
                    resolution(field)
                }
            }
        }
    }

    private func sideRow(_ side: String, _ text: String?, isSecondary: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(side)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .accessibilityHidden(true)
            ConflictValue(side: side, text: text, isSecondary: isSecondary)
        }
    }

    // MARK: - Shared parts

    /// What each side changed, then the Keep choice.
    private func resolution(_ field: UIConflictField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.changeLine())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .monospacedDigit()
                .help(field.changeLine(limit: 200))
            KeepPicker(field: field, choice: choice(for: field))
        }
    }

    @ViewBuilder private func compareButton(_ field: UIConflictField) -> some View {
        if field.contactsText != nil, field.markdownText != nil {
            Button("Compare…") { compare(field) }
                .controlSize(.small)
                .help("Show both notes line by line")
        }
    }

    private func choice(for field: UIConflictField) -> Binding<UIConflictResolution?> {
        Binding(get: { choices[field.id] }, set: { choices[field.id] = $0 })
    }
}

/// One side's value: up to three lines, the full text in the tooltip.
private struct ConflictValue: View {
    let side: String
    let text: String?
    var isSecondary = false

    var body: some View {
        Text(text ?? "—")
            .foregroundStyle(isSecondary ? .secondary : .primary)
            .lineLimit(3)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help)
            .accessibilityLabel("\(side): \(text ?? "none")")
    }

    /// Tooltips stay readable: very long values (note bodies) are cut; the
    /// whole text is in Compare….
    private var help: String {
        guard let text else { return "No earlier value: added on both sides" }
        return text.count > 1_000 ? String(text.prefix(1_000)) + "…" : text
    }
}

/// Keep Contacts | Keep Markdown | Keep Both, as a segmented control when it
/// fits, else a pop-up menu.
private struct KeepPicker: View {
    let field: UIConflictField
    @Binding var choice: UIConflictResolution?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker("Keep", selection: $choice) {
                ForEach(field.options) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Keep", selection: $choice) {
                Text("Choose…").tag(UIConflictResolution?.none)
                ForEach(field.options) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)
        }
        .labelsHidden()
        .accessibilityLabel("Keep for \(field.title)")
    }
}
