import Contacts2MdCLI
import SwiftUI

/// Duplicates (docs/ui.md §7): unlinked contacts that look like one person,
/// copied notes sharing a sync id, linked contacts carrying several sync
/// ids, and files iCloud kept several differing versions of (M6). Group list on the left, side-by-side cards on the right.
struct DuplicatesView: View {
    let model: AppModel
    @State private var selectedID: String?

    private var groups: [UIDuplicateGroup] { model.queues?.duplicates ?? [] }

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Duplicates", systemImage: "checkmark.circle")
                } description: {
                    Text(emptyDescription)
                }
            } else {
                HStack(spacing: 0) {
                    groupList.frame(width: 250)
                    Divider()
                    if let group = groups.first(where: { $0.id == selectedID }) ?? groups.first {
                        if group.kind == .contacts {
                            ClusterDetail(model: model, group: group)
                                .id(group.id)
                        } else {
                            DuplicateDetail(model: model, group: group)
                                .id(group.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
    }

    private var emptyDescription: String {
        let snoozed = model.queues?.snoozedCount ?? 0
        return snoozed > 0
            ? "\(snoozed) ignored for now. They return after the next sync."
            : "No contacts or files look like the same person."
    }

    private var groupList: some View {
        List(selection: $selectedID) {
            Section {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(group.title).lineLimit(1)
                            Spacer()
                            Text(group.counts).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(group.sources).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(group.id)
                }
            } header: {
                Text("\(groups.count) possible \(groups.count == 1 ? "duplicate" : "duplicates")")
            }
        }
        .onAppear { if selectedID == nil { selectedID = groups.first?.id } }
    }
}

/// One group: headline, reasons, cards and actions.
private struct DuplicateDetail: View {
    let model: AppModel
    let group: UIDuplicateGroup
    @State private var confirming: UIDuplicateAction?
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(group.cards) { card in
                            DuplicateCardView(model: model, group: group, card: card) { confirming = $0 }
                        }
                    }
                    .padding(.bottom, 4)
                }
                actions
                if group.kind == .mergeRecords {
                    Text(
                        "These cards were linked in Contacts after each had its own note. Choose Keep This File "
                            + "on the note that should stay synced; the other notes are detached, not deleted."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if group.kind == .fileVersions {
                    Text(
                        "Two devices changed this file before seeing each other's change, and iCloud kept both. "
                            + "Keep the current contents or one of the versions; the device that leads syncing "
                            + "applies your choice on its next sync."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isWorking)
        .confirmationDialog(
            confirmTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming
        ) { action in
            Button(confirmButton(action)) {
                Task { await run(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmMessage(action))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(group.title) — \(group.counts)").font(.title2.weight(.semibold))
            Text("Why: " + group.reasons.joined(separator: " · ")).foregroundStyle(.secondary)
            Text("Noticed \(UIFormat.relativeDay(group.firstSeen))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if group.kind == .mergeRecords {
                Button("Open in Contacts") { model.openInContacts(cardIDs: group.allCardIDs) }
            } else if group.kind == .fileVersions, let path = group.cards.first?.path {
                Button("Reveal in Finder") { model.revealInFinder(path: path) }
            }
            Button("Ignore for Now") { model.snooze(group.id) }
                .help("Hide until the next sync")
            if isWorking { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Confirmation

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var confirmTitle: String {
        switch confirming {
        case .notDuplicates, .resolve: ""
        case .keepSyncID: "Keep the sync id on this file?"
        case .pickSurvivingFile(_, let path): "Keep \(path)?"
        case .keepCurrentVersion: "Keep the current version of \(group.title)?"
        case .keepOtherVersion(let index): "Keep version \(index + 1) of \(group.title)?"
        case .ignoreForNow, nil: ""
        }
    }

    private func confirmButton(_ action: UIDuplicateAction) -> String {
        switch action {
        case .notDuplicates: "Not Duplicates"
        case .resolve: "Apply"
        case .keepSyncID: "Keep This One"
        case .pickSurvivingFile: "Keep This File"
        case .keepCurrentVersion: "Keep Current"
        case .keepOtherVersion: "Keep This Version"
        case .ignoreForNow: "Ignore for Now"
        }
    }

    private func confirmMessage(_ action: UIDuplicateAction) -> String {
        switch action {
        case .notDuplicates, .resolve:
            return ""
        case .keepSyncID(let index):
            let others = group.cards.indices.filter { $0 != index }.compactMap { group.cards[$0].path }
            return "The other \(others.count == 1 ? "file" : "files") (\(others.joined(separator: ", "))) "
                + "will be treated as a copy and not synced."
        case .pickSurvivingFile(_, let path):
            return group.keepFileMessage(keeping: path, appleWrites: model.vaultOptions?.appleWrites ?? false)
        case .keepCurrentVersion, .keepOtherVersion:
            return group.keepVersionMessage(action)
        case .ignoreForNow:
            return ""
        }
    }

    private func run(_ action: UIDuplicateAction) async {
        isWorking = true
        defer { isWorking = false }
        if let answer = action.decision(itemID: group.id) {
            await model.decide([answer])
        }
    }
}

/// One side-by-side card (`┌ iCloud ─┐`).
private struct DuplicateCardView: View {
    let model: AppModel
    let group: UIDuplicateGroup
    let card: UIDuplicateCard
    let choose: (UIDuplicateAction) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.headline).lineLimit(2)
                ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if card.lines.isEmpty && card.source != .note {
                    Text("Details appear after the next check.").foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                cardActions
            }
            .frame(width: 200, alignment: .leading)
            .frame(minHeight: 150, alignment: .top)
        } label: {
            Label(card.heading, systemImage: icon)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.inspect(InspectorItem(card, group: group), open: true) }
    }

    private var icon: String {
        switch card.source {
        case .note: "doc.text"
        case .fileVersion: "doc.on.doc"
        case .contact: "person.crop.circle"
        }
    }

    @ViewBuilder private var cardActions: some View {
        HStack {
            if !card.cardIDs.isEmpty {
                Button("Open") { model.openInContacts(cardIDs: card.cardIDs) }
                    .help("Open in Contacts")
            }
            if let path = card.path {
                Button("Reveal") { model.revealInFinder(path: path) }
                    .help("Reveal in Finder")
            }
            if let action = card.action {
                switch action {
                case .keepSyncID:
                    Button("Keep This One") { choose(action) }
                case .pickSurvivingFile:
                    Button("Keep This File") { choose(action) }
                        .help("Keep this note synced with the contact; the others are detached")
                case .keepCurrentVersion:
                    Button("Keep Current") { choose(action) }
                        .help("Keep the file as it is on this Mac; the other versions are discarded")
                case .keepOtherVersion:
                    Button("Keep This Version") { choose(action) }
                        .help("Replace the file with this version on the next sync")
                case .resolve, .notDuplicates, .ignoreForNow:
                    EmptyView()
                }
            }
        }
        .controlSize(.small)
    }
}
