import Contacts2MdCLI
import SwiftUI

/// Overview (docs/ui.md §3): status line, Needs Review (only when nonzero),
/// Since Last Sync (from the latest dry run), This Session, Totals.
struct OverviewView: View {
    let model: AppModel

    var body: some View {
        if let overview = model.overview {
            Form {
                statusSection(overview)
                if !overview.needsReview.isEmpty { needsReviewSection(overview) }
                sinceLastSyncSection(overview)
                if let session = overview.session { sessionSection(session) }
                totalsSection(overview)
            }
            .formStyle(.grouped)
            .navigationTitle("Overview")
        }
    }

    // MARK: - Status

    private func statusSection(_ overview: UIOverview) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                headline(overview.health).font(.title3.weight(.semibold))
                Text(lastSyncedLine(overview)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
            if overview.multiDeviceWithoutStamps {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "Several devices share this folder, but your contacts don't carry sync IDs.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    Text(
                        "Without them, each device matches contacts to files on its own. "
                            + "Turn on “Add sync IDs to contacts” in Settings ▸ Accounts."
                    )
                    .foregroundStyle(.secondary)
                    SettingsLink { Text("Open Settings…") }
                }
            }
            if let export = model.lastExport, !export.failures.isEmpty {
                Label("\(export.failures.count) files could not be written", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func headline(_ health: UIOverview.Health) -> some View {
        switch health {
        case .inSync:
            Label("In sync. Nothing needs your attention.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .changesWaiting(let count):
            Label(
                "\(count.formatted()) \(count == 1 ? "note" : "notes") to update on the next export",
                systemImage: "arrow.triangle.2.circlepath")
        case .needsReview(let count):
            Label {
                Text("\(count.formatted()) \(count == 1 ? "item needs" : "items need") review")
            } icon: {
                MeaningDot(color: .orange)
            }
        case .neverExported:
            Label("Not exported from this Mac yet", systemImage: "circle.dashed")
        }
    }

    private func lastSyncedLine(_ overview: UIOverview) -> String {
        guard let date = overview.lastExport else { return "Choose \(model.syncTitle) to write your notes." }
        var line = "Last exported \(UIFormat.relativeDay(date)) on \(overview.deviceName)"
        if let duration = overview.lastDuration { line += " · \(UIFormat.duration(duration))" }
        return line
    }

    // MARK: - Needs Review

    private func needsReviewSection(_ overview: UIOverview) -> some View {
        Section("Needs Review") {
            ForEach(overview.needsReview) { row in
                Button {
                    model.selection = SidebarItem(row.queue)
                } label: {
                    HStack {
                        MeaningDot(color: .orange)
                        Text(row.title)
                        Spacer()
                        Text(row.count.formatted()).monospacedDigit()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Since Last Sync

    private func sinceLastSyncSection(_ overview: UIOverview) -> some View {
        Section {
            if let changed = overview.changedInContacts {
                CountRow("Changed in Contacts", changed)
                if overview.toAdopt > 0 { CountRow("Existing notes to link", overview.toAdopt) }
                if overview.movedNotes > 0 { CountRow("Notes moved in the folder", overview.movedNotes) }
            } else {
                LabeledContent("Changed in Contacts") {
                    if model.phase == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Changed in Markdown") {
                Text(model.capabilities.twoWaySync ? "—" : "Tracked with two-way sync").foregroundStyle(.secondary)
            }
        } header: {
            Text("Since Last Sync")
        } footer: {
            HStack {
                if let date = overview.planComputedAt {
                    Text("As of \(UIFormat.relativeDay(date))").monospacedDigit()
                }
                Spacer()
                Button("Check Again") { Task { await model.check() } }
                    .disabled(model.phase != .idle)
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - This Session

    private func sessionSection(_ session: UIOverview.SessionTable) -> some View {
        Section(session.heading) {
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Created")
                    Text("Updated")
                    Text("Deleted")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                countsRow("Apple Contacts", session.contacts)
                countsRow("Markdown files", session.markdown)
            }
            if session.adopted > 0 {
                CountRow("Existing notes linked", session.adopted)
            }
        }
    }

    private func countsRow(_ title: String, _ counts: UIChangeCounts) -> some View {
        GridRow {
            Text(title)
            Text(counts.created.formatted())
            Text(counts.updated.formatted())
            Text(counts.deleted.formatted())
        }
        .monospacedDigit()
    }

    // MARK: - Totals

    private func totalsSection(_ overview: UIOverview) -> some View {
        Section("Totals") {
            CountRow("Synced contacts", overview.syncedContacts)
            LabeledContent("Notes root") {
                HStack {
                    PathText(overview.rootPath)
                    Button("Reveal") { model.revealRoot() }
                }
            }
        }
    }
}
