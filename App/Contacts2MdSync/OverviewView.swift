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
                if !model.renamedLinks.isEmpty { RenamedLinksSection(model: model) }
                sinceLastSyncSection(overview)
                if let session = overview.session { sessionSection(session) }
                totalsSection(overview)
            }
            .formStyle(.grouped)
            .navigationTitle("Overview")
            .task { await model.refreshRenamedLinks() }
        }
    }

    // MARK: - Status

    private func statusSection(_ overview: UIOverview) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                headline(overview.health).font(.title3.weight(.semibold))
                Text(lastSyncedLine(overview)).foregroundStyle(.secondary).monospacedDigit()
                Text(model.live.liveLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
            if let follower = model.follower {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(follower.text)
                        Text(follower.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: follower.isError ? "exclamationmark.triangle" : "person.2.wave.2")
                }
                .foregroundStyle(follower.isError ? .red : .primary)
            }
            if !model.lastFailures.isEmpty {
                let count = model.lastFailures.count
                Label(
                    "\(count) \(count == 1 ? "change" : "changes") could not be written", systemImage: "xmark.octagon"
                )
                .foregroundStyle(.red)
                .help(model.lastFailures.joined(separator: "\n"))
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
                "\(count.formatted()) \(count == 1 ? "change" : "changes") on the next sync",
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
        var line = "Last synced \(UIFormat.relativeDay(date)) on \(overview.deviceName)"
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
                if overview.toTrash > 0 {
                    CountRow("Notes to move to the Trash", overview.toTrash, note: "deleted in Contacts")
                }
            } else {
                LabeledContent("Changed in Contacts") {
                    if model.phase == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
            if let changed = overview.changedInMarkdown {
                CountRow(
                    "Changed in Markdown", changed,
                    note: overview.appleHeld > 0 && changed > 0 ? heldNote(overview) : nil)
            } else {
                LabeledContent("Changed in Markdown") {
                    Text(overview.lastExport == nil ? "After the first sync" : "—").foregroundStyle(.secondary)
                }
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
                    .disabled(!model.canSync)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func heldNote(_ overview: UIOverview) -> String {
        overview.appleWritesEnabled ? "waiting for approval" : "held: writing to Contacts is off"
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
            if session.held > 0 {
                CountRow("Apple changes held", session.held)
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
