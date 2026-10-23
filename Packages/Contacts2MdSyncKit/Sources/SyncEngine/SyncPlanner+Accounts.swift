internal import ContactModel
public import Foundation

/// An Apple change held because it would touch a card of an unavailable account.
public struct AccountHeldChange: Hashable, Sendable {
    public var recordID: UUID
    public var title: String
    /// Fields held (`emails`, `job_title`, `body`, …).
    public var fields: [String]
    /// `Google ("Gmail", 1,353 cards)`.
    public var account: String
}

/// What `forget` would remove from one note: the values that exist only on
/// the forgotten account's cards.
public struct AccountRemoval: Codable, Hashable, Sendable {
    public var title: String
    public var path: String
    /// `phones: +1 415 555 0100`, `job_title: CTO`, `body`.
    public var values: [String]

    /// Creates a removal.
    public init(title: String, path: String, values: [String]) {
        self.title = title
        self.path = path
        self.values = values
    }
}

/// Planning-run bookkeeping of unavailable accounts.
struct AccountPlanning {
    /// Frozen card id → its account's container id.
    var accountOfCard: [String: String] = [:]
    /// Records frozen whole (every card unavailable, or a value unknown), per account.
    var frozen: [String: [(id: UUID, title: String)]] = [:]
    /// Records that keep an unavailable account's values on a live contact, per account.
    var linked: [String: Int] = [:]
    var removals: [String: [AccountRemoval]] = [:]
    var held: [AccountHeldChange] = []
}

/// Unavailable accounts in a sync run (architecture §9): frozen contacts are
/// bound to their records and not synced; Apple changes that would touch a
/// frozen card are held; `forget` is previewed per record.
extension PlanningRun {
    /// After identity: contacts made only of frozen cards stay bound to
    /// their record (never "deleted", never new) and are not synced, like
    /// contacts whose values are partly unknown.
    mutating func applyUnavailableAccounts() {
        guard let inputs = sync?.inputs, inputs.accounts.isActive else { return }
        var planning = AccountPlanning()
        for account in inputs.accounts.accounts {
            for frozen in account.cards { planning.accountOfCard[frozen.card.id] = account.containerID }
        }
        let bound = Set(boundIDs.values)
        for contact in contacts where inputs.frozenContacts.contains(contact.unifiedID) {
            if boundIDs[contact.unifiedID] == nil, let record = inputs.ghostRecords[contact.unifiedID],
                !bound.contains(record)
            {
                boundIDs[contact.unifiedID] = record
            }
            blocked.insert(contact.unifiedID)
            accountFrozen.insert(contact.unifiedID)
            guard let id = boundIDs[contact.unifiedID] else { continue }
            claimedRecords.insert(id)
            let accountID = contact.cards.lazy.compactMap { planning.accountOfCard[$0.id] }.first ?? ""
            planning.frozen[accountID, default: []].append((id, note(of: id)?.title ?? title(contact)))
        }
        sync?.accounts = planning
    }

    /// The account containers of the frozen cards of `contact`
    /// (`missingOnly`: accounts not visible again yet).
    private func frozenAccounts(of contact: AppleContact, missingOnly: Bool = false) -> [String] {
        let accounts = sync?.accounts.accountOfCard ?? [:]
        let returning = Set(sync?.inputs.accounts.accounts.filter { $0.returnedAt != nil }.map(\.containerID) ?? [])
        return Array(Set(contact.cards.compactMap { accounts[$0.id] })).sorted().filter {
            !missingOnly || !returning.contains($0)
        }
    }

    /// The merge with every Apple change that would touch a frozen card
    /// removed (held, found again next run since the base keeps it):
    /// everything when the card new values go to is frozen; else single
    /// values whose precedence card is frozen (no flip to another card's
    /// value), list edits and deletes of values a frozen card holds, and tag
    /// changes when a frozen card could hold groups.
    mutating func holdFrozenWrites(
        _ merge: MergeResult, candidate: Candidate, builder: ViewBuilder
    ) -> MergeResult {
        let contact = candidate.apple
        let accounts = frozenAccounts(of: contact)
        guard !accounts.isEmpty else { return merge }
        sync?.accounts.linked[accounts[0], default: 0] += 1
        guard merge.changesApple else { return merge }
        let accountOfCard = sync?.accounts.accountOfCard ?? [:]
        let frozen = Set(contact.cards.map(\.id).filter { accountOfCard[$0] != nil })
        var result = merge
        var held: [String] = []
        if let target = contact.stampTargetCard, frozen.contains(target.id) {
            result.holdAllAppleChanges()
            held = merge.appleFields
        } else {
            held = result.hold(frozen: frozen, in: contact, builder: builder)
        }
        if !held.isEmpty {
            let label = sync?.inputs.accounts.accounts.first { $0.containerID == accounts[0] }?.label ?? ""
            sync?.accounts.held.append(
                AccountHeldChange(recordID: candidate.recordID, title: candidate.title, fields: held, account: label))
        }
        return result
    }

    /// What `forget` would remove from this note: values only the frozen
    /// cards hold (what the Apple side loses without them).
    mutating func previewForget(_ candidate: Candidate, builder: ViewBuilder) {
        let contact = candidate.apple
        for account in frozenAccounts(of: contact, missingOnly: true) {
            let cards = sync?.accounts.accountOfCard ?? [:]
            var without = contact
            without.cards.removeAll { cards[$0.id] == account }
            guard !without.cards.isEmpty else { continue }
            let values = builder.apple(self.values(contact), tags: [], image: .none)
            let remaining = builder.apple(without.cardMergedContact(keyer: planner.keyer), tags: [], image: .none)
            let lost = Self.lost(values, remaining)
            guard !lost.isEmpty else { continue }
            sync?.accounts.removals[account, default: []].append(
                AccountRemoval(title: candidate.title, path: candidate.path, values: lost))
        }
    }

    private static func lost(_ values: FieldView, _ remaining: FieldView) -> [String] {
        var lost: [String] = []
        for field in ScalarField.allCases where values.scalars[field] != nil {
            if ScalarField.key(values.scalars[field]) != ScalarField.key(remaining.scalars[field]) {
                lost.append("\(field.rawValue): \(values.scalars[field] ?? "")")
            }
        }
        for field in ListField.allCases {
            let keys = Set(remaining.list(field).map(\.key))
            lost += values.list(field).filter { !keys.contains($0.key) }.map { "\(field.rawValue): \($0.display)" }
        }
        if let body = values.body, !body.isEmpty, body != remaining.body { lost.append("body") }
        return lost
    }

    /// Review items and statuses for the unavailable accounts.
    func accountReport() -> (statuses: [AccountStatus], reviews: [ReviewItem]) {
        guard let sync, sync.inputs.accounts.isActive else { return ([], []) }
        var statuses: [AccountStatus] = []
        var reviews: [ReviewItem] = []
        for account in sync.inputs.accounts.accounts {
            let frozen = sync.accounts.frozen[account.containerID] ?? []
            let held = sync.accounts.held.filter { $0.account == account.label }.count
            statuses.append(
                AccountStatus(
                    account: account, frozenRecords: frozen.count,
                    linkedRecords: sync.accounts.linked[account.containerID] ?? 0, heldChanges: held))
            guard account.returnedAt == nil else { continue }
            reviews.append(
                .accountMissing(
                    AccountMissingReview(
                        account: account, frozenTitles: frozen.map(\.title).sorted(),
                        linkedCount: sync.accounts.linked[account.containerID] ?? 0,
                        removals: (sync.accounts.removals[account.containerID] ?? []).sorted { $0.path < $1.path })))
        }
        return (statuses, reviews)
    }
}

extension MergeResult {
    /// Holds every Apple change (the card new values go to is unavailable).
    mutating func holdAllAppleChanges() {
        appleScalars = [:]
        appleBody = nil
        appleImage = nil
        appleTagsAdded = []
        appleTagsRemoved = []
        for (field, slots) in lists {
            lists[field] = slots.map { slot in
                var slot = slot
                slot.appleFinal = slot.apple.map { [$0] } ?? []
                return slot
            }
        }
    }

    /// Holds the Apple changes that touch `frozen` cards; returns the fields held.
    mutating func hold(frozen: Set<String>, in contact: AppleContact, builder: ViewBuilder) -> [String] {
        var held: [String] = []
        let ordered = contact.cardsByPrecedence
        func sourceIsFrozen(_ has: (CanonicalContact) -> Bool) -> Bool {
            ordered.first { card in contact.values(of: card).map(has) ?? false }.map { frozen.contains($0.id) } ?? false
        }
        for field in appleScalars.keys.sorted(by: { $0.rawValue < $1.rawValue })
        where sourceIsFrozen({ field.value(in: $0) != nil }) {
            appleScalars[field] = nil
            held.append(field.rawValue)
        }
        if appleBody != nil, sourceIsFrozen({ !ComparisonKeys.body($0.body).isEmpty }) {
            appleBody = nil
            held.append("body")
        }
        let frozenViews = contact.cards.filter { frozen.contains($0.id) }.compactMap { card in
            contact.values(of: card).map { builder.apple($0, tags: [], image: .none) }
        }
        for (field, slots) in lists {
            let keys = Set(frozenViews.flatMap { $0.list(field).map(\.key) })
            lists[field] = slots.map { slot in
                guard slot.changesApple, let apple = slot.apple, keys.contains(apple.key) else { return slot }
                var slot = slot
                slot.appleFinal = [apple]
                if !held.contains(field.rawValue) { held.append(field.rawValue) }
                return slot
            }
        }
        let groupCapable = contact.cards.contains { frozen.contains($0.id) && $0.accountKind.supportsGroups }
        if groupCapable, !appleTagsAdded.isEmpty || !appleTagsRemoved.isEmpty {
            appleTagsAdded = []
            appleTagsRemoved = []
            held.append("tags")
        }
        return held
    }
}
