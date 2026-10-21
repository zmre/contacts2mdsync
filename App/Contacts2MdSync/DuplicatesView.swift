import Contacts2MdCLI
import SwiftUI

/// Duplicates (docs/ui.md §7): unlinked contacts that look like one person,
/// copied notes sharing a sync id, and linked contacts carrying several
/// sync ids. Group list on the left, side-by-side cards on the right.
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
                        DuplicateDetail(model: model, group: group)
                            .id(group.id)
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
    }

    private var emptyDescription: String {
        let snoozed = model.queues?.snoozedCount ?? 0
        return snoozed > 0
            ? "\(snoozed) ignored for now. They return after the next export."
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
                if group.kind == .contacts {
                    Text(
                        "Contacts has no way for apps to link cards. Open them in Contacts, select both, "
                            + "and choose Card ▸ Link Selected Cards. This window checks again when you come back."
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
            Button(confirmButton(action), role: isDestructive(action) ? .destructive : nil) {
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
            if group.kind == .contacts {
                Button("Open in Contacts to Link") { model.openInContacts(cardIDs: group.allCardIDs) }
                    .buttonStyle(.borderedProminent)
                    .disabled(group.allCardIDs.isEmpty)
                Menu("Sync Only…") {
                    ForEach(group.cards.filter { $0.source != .note }) { card in
                        if let action = card.action {
                            Button(syncOnlyTitle(card)) { confirming = action }
                        }
                    }
                }
                .fixedSize()
                .help("Keep one contact synced and leave the others out")
                Button("Not Duplicates") { confirming = .notDuplicates }
            } else if group.kind == .mergeRecords {
                Button("Open in Contacts") { model.openInContacts(cardIDs: group.allCardIDs) }
            }
            Button("Ignore for Now") { model.snooze(group.id) }
                .help("Hide until the next export")
            if isWorking { ProgressView().controlSize(.small) }
        }
    }

    private func syncOnlyTitle(_ card: UIDuplicateCard) -> String {
        let sameHeading = group.cards.filter { $0.heading == card.heading }.count > 1
        return sameHeading ? "Sync Only \(card.heading) (\(card.title))" : "Sync Only \(card.heading)"
    }

    // MARK: - Confirmation

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var confirmTitle: String {
        switch confirming {
        case .notDuplicates: "Remember that these are different people?"
        case .syncOnly(let member): "Sync only \(memberCard(member)?.heading ?? "this contact")?"
        case .keepSyncID: "Keep the sync id on this file?"
        case .pickSurvivingFile: "Keep this file?"
        case .ignoreForNow, nil: ""
        }
    }

    private func confirmButton(_ action: UIDuplicateAction) -> String {
        switch action {
        case .notDuplicates: "Not Duplicates"
        case .syncOnly: "Sync Only This One"
        case .keepSyncID: "Keep This One"
        case .pickSurvivingFile: "Keep This File"
        case .ignoreForNow: "Ignore for Now"
        }
    }

    private func confirmMessage(_ action: UIDuplicateAction) -> String {
        switch action {
        case .notDuplicates:
            return "They won't be flagged again. Each gets its own note on the next export."
        case .syncOnly(let member):
            let others = group.cards.filter { $0.source != .note && $0.action != action }.map(\.heading)
            return "\(memberCard(member)?.title ?? "This contact") stays synced. "
                + "\(others.joined(separator: ", ")) will be left out of sync. Nothing is deleted."
        case .keepSyncID(let index):
            let others = group.cards.indices.filter { $0 != index }.compactMap { group.cards[$0].path }
            return "The other \(others.count == 1 ? "file" : "files") (\(others.joined(separator: ", "))) "
                + "will be treated as a copy and not synced."
        case .pickSurvivingFile(let path):
            return "\(path) stays. The other files move to the Trash when this is applied."
        case .ignoreForNow:
            return ""
        }
    }

    private func isDestructive(_ action: UIDuplicateAction) -> Bool {
        if case .pickSurvivingFile = action { return true }
        return false
    }

    private func memberCard(_ member: Int) -> UIDuplicateCard? {
        group.cards.first { $0.source == .contact(member: member) }
    }

    private func run(_ action: UIDuplicateAction) async {
        isWorking = true
        defer { isWorking = false }
        if case .pickSurvivingFile(let path) = action {
            await model.pickSurvivingFile(itemID: group.id, path: path)
        } else if let answer = action.decision(itemID: group.id) {
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
            Label(card.heading, systemImage: card.source == .note ? "doc.text" : "person.crop.circle")
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.inspect(InspectorItem(card, group: group), open: true) }
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
                        .disabled(!model.capabilities.pickSurvivingFile)
                        .help(model.capabilities.pickSurvivingFile ? "" : ReviewCapabilities.twoWayHelp)
                case .syncOnly, .notDuplicates, .ignoreForNow:
                    EmptyView()
                }
            }
        }
        .controlSize(.small)
    }
}
