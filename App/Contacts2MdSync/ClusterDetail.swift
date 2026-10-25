import Contacts2MdCLI
import SwiftUI

/// One duplicate cluster (docs/ui.md §7): a selectable card per contact,
/// actions on the selection (Same Person, Different People, Don't Sync), the
/// resulting partition as chips, and Apply, which records one
/// `cluster-resolve` decision. Not Duplicates and Ignore for Now stay as
/// shortcuts.
struct ClusterDetail: View {
    let actions: ClusterActions
    let group: UIDuplicateGroup
    @State private var partition: UIClusterPartition
    @State private var selection = Set<Int>()
    @State private var confirming: Confirmation?
    @State private var isWorking = false
    @FocusState private var focusedMember: Int?

    init(actions: ClusterActions, group: UIDuplicateGroup) {
        self.actions = actions
        self.group = group
        _partition = State(initialValue: group.startingPartition)
    }

    /// The Duplicates screen: answers go to the decision log, Details to the inspector.
    init(model: AppModel, group: UIDuplicateGroup) {
        self.init(actions: ClusterActions(model: model), group: group)
    }

    private enum Confirmation: Identifiable {
        case apply
        case notDuplicates

        var id: Int { self == .apply ? 0 : 1 }
    }

    private var cards: [UIDuplicateCard] { group.memberCards }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                selectionBar
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(cards) { card in
                        if let member = card.member {
                            MemberCard(
                                actions: actions, group: group, card: card, member: member,
                                isSelected: selection.contains(member), badge: partition.badge(for: member),
                                tint: tint(for: partition.assignment(of: member))
                            ) {
                                toggle(member)
                            }
                            .focused($focusedMember, equals: member)
                        }
                    }
                }
                partitionBar
                Text(
                    "Select cards, then say whether they are the same person, different people, or should not "
                        + "sync. Each person gets one note. Contacts has no way for apps to link cards: open a "
                        + "person's cards in Contacts and choose Card ▸ Link Selected Cards."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isWorking)
        .confirmationDialog(
            confirmTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming
        ) { confirmation in
            Button(confirmation == .apply ? "Apply" : "Not Duplicates") {
                Task { await run(confirmation) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmMessage(confirmation))
        }
    }

    // MARK: - Header and bars

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(group.title) — \(group.counts)").font(.title2.weight(.semibold))
            Text("Why: " + group.reasons.joined(separator: " · ")).foregroundStyle(.secondary)
            if group.priorPartition != nil {
                Text("You answered for some of these before; new cards are undecided.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("Noticed \(UIFormat.relativeDay(group.firstSeen))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    /// Actions on the selected cards; wraps in a narrow detail column.
    private var selectionBar: some View {
        FlowLayout(spacing: 8) {
            Text(selection.isEmpty ? "No cards selected" : "\(selection.count) selected")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 110, alignment: .leading)
            Button("Same Person") { edit { $0.samePerson(selection) } }
                .disabled(selection.count < 2)
                .help("The selected cards are one person: one note")
            Button("Different People") { edit { $0.differentPeople(selection) } }
                .disabled(selection.isEmpty)
                .help("Each selected card is a different person with its own note")
            Button("Don't Sync") { edit { $0.dontSync(selection) } }
                .disabled(selection.isEmpty)
                .help("Leave the selected cards out of sync; nothing is deleted, but a note they have stops syncing")
            Button("Select All") { selection = Set(cards.compactMap(\.member)) }
                .keyboardShortcut("a", modifiers: .command)
            Button("Select None") { selection = [] }
                .disabled(selection.isEmpty)
        }
        .controlSize(.small)
    }

    /// The resulting partition, then Undo / Reset / Apply and the shortcuts.
    /// Chips and button groups wrap, so a big cluster or a narrow detail
    /// column never makes the screen wider than the column.
    private var partitionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(partition.chips) { chip in
                    Text(chip.text)
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(chipColor(chip.kind).opacity(0.18)))
                        .overlay(Capsule().strokeBorder(chipColor(chip.kind).opacity(0.5)))
                        .accessibilityLabel(chip.text)
                }
                ForEach(partition.people, id: \.self) { person in
                    let ids = group.cardIDs(of: person, in: partition)
                    if partition.members(of: person).count > 1 {
                        Button("Link \(UIClusterPartition.personName(person)) in Contacts…") {
                            actions.openInContacts(ids)
                        }
                        .controlSize(.small)
                        .help("Open these cards in Contacts, then choose Card ▸ Link Selected Cards")
                    }
                }
            }
            FlowLayout(spacing: 24) {
                HStack(spacing: 8) {
                    Button("Apply") { confirming = .apply }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!partition.isComplete)
                        .help(
                            partition.isComplete
                                ? "Record this answer; the next sync applies it"
                                : "Every card needs a person or Don't Sync")
                    Button("Undo") { partition.undo() }
                        .disabled(!partition.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button("Reset") {
                        partition.reset()
                        selection = []
                    }
                    .disabled(!partition.isEdited)
                }
                HStack(spacing: 8) {
                    Button("Not Duplicates") { confirming = .notDuplicates }
                        .help("Every card is a different person (remembered)")
                    Button(actions.ignoreTitle) { actions.ignore(group.id) }
                        .help(actions.ignoreHelp)
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    // MARK: - Selection and edits

    private func toggle(_ member: Int) {
        if selection.contains(member) { selection.remove(member) } else { selection.insert(member) }
        focusedMember = member
    }

    private func edit(_ change: (inout UIClusterPartition) -> Void) {
        change(&partition)
        selection = []
    }

    private func tint(for assignment: UIClusterPartition.Assignment?) -> Color {
        switch assignment {
        case .person(let person): Self.palette[person % Self.palette.count]
        case .excluded: .gray
        case nil: .clear
        }
    }

    private func chipColor(_ kind: UIPartitionChip.Kind) -> Color {
        switch kind {
        case .person(let person): Self.palette[person % Self.palette.count]
        case .excluded: .gray
        case .undecided: .orange
        }
    }

    private static let palette: [Color] = [.blue, .green, .purple, .pink, .teal, .brown, .indigo, .mint]

    // MARK: - Confirmation

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var confirmTitle: String {
        switch confirming {
        case .apply: "Apply this answer for \(group.title)?"
        case .notDuplicates: "Remember that these are different people?"
        case nil: ""
        }
    }

    private func confirmMessage(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .apply: group.applyMessage(partition) + "\n" + actions.appliesWhen
        case .notDuplicates: "They won't be flagged again. Each gets its own note on the next sync."
        }
    }

    private func run(_ confirmation: Confirmation) async {
        isWorking = true
        defer { isWorking = false }
        let answer: UIReviewDecision? =
            switch confirmation {
            case .apply: partition.decision(itemID: group.id)
            case .notDuplicates: UIDuplicateAction.notDuplicates.decision(itemID: group.id)
            }
        if let answer { _ = await actions.decide([answer]) }
    }
}

/// What a cluster's buttons do: in Duplicates (decision log, inspector) or
/// embedded in onboarding (recorded before the first sync, no inspector).
@MainActor
struct ClusterActions {
    var decide: ([UIReviewDecision]) async -> Bool
    var ignore: (String) -> Void
    var ignoreTitle = "Ignore for Now"
    var ignoreHelp = "Hide until the next sync"
    /// Said after the Apply confirmation's partition summary.
    var appliesWhen = "The next sync applies it."
    var openInContacts: ([String]) -> Void
    var revealInFinder: (String) -> Void
    /// Details in the inspector (`nil`: no Details button).
    var inspect: ((UIDuplicateCard, UIDuplicateGroup) -> Void)?
}

extension ClusterActions {
    init(model: AppModel) {
        self.init(
            decide: { await model.decide($0) }, ignore: { model.snooze($0) },
            openInContacts: { model.openInContacts(cardIDs: $0) }, revealInFinder: { model.revealInFinder(path: $0) },
            inspect: { card, group in model.inspect(InspectorItem(card, group: group), open: true) })
    }
}

/// One selectable contact card: checkbox and selection ring, the person
/// badge, accounts, details (household numbers de-emphasized), its note,
/// and why it is in the cluster.
private struct MemberCard: View {
    let actions: ClusterActions
    let group: UIDuplicateGroup
    let card: UIDuplicateCard
    let member: Int
    let isSelected: Bool
    let badge: String?
    let tint: Color
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text("\(member + 1)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(card.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.2)))
                }
            }
            accountBadges
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                Text(line).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            ForEach(Array(card.quietLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Home, main and work numbers are shared within a household; they never make cards duplicates")
            }
            if card.lines.isEmpty && card.quietLines.isEmpty {
                Text("Details appear after the next check.").foregroundStyle(.tertiary)
            }
            if !card.why.isEmpty {
                Divider()
                ForEach(Array(card.why.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            HStack {
                if !card.cardIDs.isEmpty {
                    Button("Open") { actions.openInContacts(card.cardIDs) }
                        .help("Open in Contacts")
                }
                if let path = card.path {
                    Button("Reveal") { actions.revealInFinder(path) }
                        .help("Reveal the note in Finder")
                }
                if let inspect = actions.inspect {
                    Button("Details") { inspect(card, group) }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : tint.opacity(0.6), lineWidth: isSelected ? 2.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: toggle)
        .focusable(interactions: .activate)
        .onKeyPress(.space) {
            toggle()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: isSelected ? "Deselect" : "Select", toggle)
    }

    private var accountBadges: some View {
        HStack(spacing: 4) {
            ForEach(card.accounts, id: \.self) { account in
                Text(account)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
            }
            if card.isLinked {
                Label("Linked", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Contacts already links these cards")
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = ["Card \(member + 1)", card.title, card.accounts.joined(separator: " and ")]
        if card.isLinked { parts.append("linked") }
        parts.append(badge ?? "undecided")
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}
