import Contacts2MdCLI
import SwiftUI

/// Activity (docs/ui.md §8): runs from this Mac's state (syncs and exports
/// from the app, live sync — Live, Launch, Wake, Sweep, Rescan — the command
/// line and schedules; previews on request), plus contact notes that could
/// not be read. Selecting a run lists its changes in the inspector.
struct ActivityView: View {
    let model: AppModel
    @State private var showPreviews = false
    @State private var selectedID: UIActivityRow.ID?

    private var rows: [UIActivityRow] { model.activityRows.filter { showPreviews || !$0.isPreview } }
    private var issues: [UIProblemNote] { model.queues?.invalidNotes ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if !issues.isEmpty {
                issuesList
                Divider()
            }
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Syncs from this Mac, the app, live sync and the command line, appear here."))
            } else {
                table
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Toggle("Show Previews", isOn: $showPreviews)
                    .toggleStyle(.checkbox)
                    .help("Include dry runs (checks that wrote nothing)")
            }
            ToolbarItem {
                Button("Export Log…", systemImage: "square.and.arrow.up") { Task { await model.exportLog() } }
                    .help("Save this Mac's activity, with each run's changes, as text or JSON")
            }
        }
        .onChange(of: selectedID) {
            guard let row = rows.first(where: { $0.id == selectedID }) else { return }
            Task { await model.inspectActivity(row) }
        }
    }

    private var table: some View {
        Table(rows, selection: $selectedID) {
            TableColumn("Time") { row in
                Text(UIFormat.relativeDay(row.startedAt)).monospacedDigit()
                    .foregroundStyle(row.isPreview ? .secondary : .primary)
            }
            .width(min: 130, ideal: 150)
            TableColumn("Device") { row in Text(row.deviceName).lineLimit(1) }
            TableColumn("Trigger") { row in
                Text(row.isPreview ? "\(row.trigger) · Preview" : row.trigger).foregroundStyle(.secondary)
                    .help(readHelp(row))
            }
            TableColumn("Contacts C/U/D") { row in counts(row.contacts, combined: row.combined) }
                .width(min: 90, ideal: 100)
            TableColumn("Markdown C/U/D") { row in counts(row.markdown, combined: row.combined) }
                .width(min: 90, ideal: 110)
            TableColumn("Held") { row in
                Text(row.held > 0 ? row.held.formatted() : "—")
                    .monospacedDigit()
                    .foregroundStyle(row.held > 0 ? .orange : .secondary)
                    .help(row.holdReason.map { "Apple changes not made: \($0)" } ?? "")
            }
            .width(min: 40, ideal: 50)
            TableColumn("Notes") { row in
                Text(row.notes ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(row.notes == "skipped" ? .orange : row.notes == nil ? .secondary : .primary)
                    .help(notesHelp(row))
            }
            .width(min: 60, ideal: 130)
            TableColumn("Review") { row in
                Text(row.review > 0 ? row.review.formatted() : "—").monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Result") { row in
                HStack(spacing: 4) {
                    result(row)
                    if let accounts = row.accounts {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.orange)
                            .help(accounts + " (nothing removed from your notes)")
                    }
                }
            }
            .width(min: 50, ideal: 70)
        }
    }

    /// What the Notes column means for a row.
    private func notesHelp(_ row: UIActivityRow) -> String {
        switch row.notes {
        case nil: "Contact notes were not synced (off, or a preview)"
        case "skipped"?:
            "Contact notes were skipped: no Automation permission for Contacts, or Contacts.app did not answer"
        default: "Notes bodies written to Contacts notes, and Contacts notes written to markdown"
        }
    }

    /// How the run read Contacts (M5 syncs record it).
    private func readHelp(_ row: UIActivityRow) -> String {
        guard let read = row.appleRead else { return "" }
        return "Contacts read: " + (read == "full" ? "full snapshot" : "changes only")
    }

    /// Runs recorded without the Apple / markdown split (command-line syncs
    /// from before M5) show "—" with both sides' total in the tooltip.
    private func counts(_ counts: UIChangeCounts?, combined: UIChangeCounts?) -> some View {
        Text(counts?.text ?? "—")
            .monospacedDigit()
            .foregroundStyle(counts?.isZero == false ? .primary : .secondary)
            .help(combined.map { "Both sides together: \($0.created) created, \($0.updated) updated" } ?? "")
    }

    @ViewBuilder private func result(_ row: UIActivityRow) -> some View {
        switch row.result {
        case .success:
            Image(systemName: "checkmark").foregroundStyle(.secondary).help(
                "Finished in \(UIFormat.duration(row.duration))")
        case .warnings(let count):
            Label("\(count)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("\(count) contacts skipped; they wait in Review")
        case .failed(let count):
            Label("\(count)", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .help("\(count) changes could not be written")
        }
    }

    private var issuesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(issues.count) contact \(issues.count == 1 ? "note" : "notes") can't be read and won't be written",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            ForEach(issues.prefix(20)) { issue in
                HStack {
                    Text(issue.path).lineLimit(1).truncationMode(.middle)
                    Text(issue.problem).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Reveal in Finder") { model.revealInFinder(path: issue.path) }
                        .controlSize(.small)
                }
            }
            if issues.count > 20 {
                Text("and \(issues.count - 20) more").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
