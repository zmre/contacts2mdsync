public import ContactModel
public import Foundation

/// The unavailable-accounts guard of one run (architecture §9 "Unavailable
/// accounts").
///
/// When a Contacts account (container) this device has seen with cards
/// disappears from the snapshot — or is still there but lost almost all its
/// cards at once — its cards are *unknown*, not deleted: each run puts them
/// back into the snapshot as they were last seen (from the Contacts mirror),
/// so linked records keep the values that lived only on those cards and
/// records whose every card was there stay bound and frozen. Nothing is
/// written to those cards. When the account comes back (possibly as a new
/// container with new card ids), its cards are matched to the frozen ones
/// and replace them. A `forget` decision drops the account deliberately.
public struct AccountGuard: Sendable {
    /// The tracked accounts after this run (what an executed run stores).
    public internal(set) var state: AccountsState
    /// Containers forgotten this run (the user's `forget`).
    var forgotten: Set<String> = []
    /// Records whose every card was in a forgotten account: deleted on the
    /// user's word (queued without the two-snapshot wait, not counted by the breaker).
    public internal(set) var forgottenRecords: Set<UUID> = []
    /// Cards of returned contacts held back while Contacts links them to the
    /// record whose frozen card they replace (a grace period after the return).
    var hiddenCardIDs: Set<String> = []
    /// Frozen card id → the live cards it can attach to (its old siblings
    /// and the other cards of its record).
    var anchors: [String: [String]] = [:]
    /// Record → (frozen card id → the returned card that replaces it).
    var rebound: [UUID: [String: AppleCard]] = [:]
    /// An account went missing or came back this run.
    public internal(set) var transitioned = false
    /// Made by `evaluate` (an inactive placeholder is never stored).
    var evaluated = false

    /// A guard that changes nothing.
    public static let inactive = AccountGuard(state: AccountsState())

    /// Accounts unavailable or returning this run.
    public var accounts: [UnavailableAccount] { state.unavailable }

    /// `true` when some account's cards are kept as last seen.
    public var isActive: Bool { !state.unavailable.isEmpty }

    /// Containers whose cards are unknown (missing, not returned yet).
    var unavailableContainerIDs: Set<String> {
        Set(state.unavailable.filter { $0.returnedAt == nil }.map(\.containerID))
    }

    /// Whether the container may be written to (not an unavailable account's).
    func isWritable(_ containerID: String) -> Bool { !unavailableContainerIDs.contains(containerID) }

    /// Every card kept as last seen this run.
    var frozenCards: [FrozenCard] { state.unavailable.flatMap(\.cards) }

    /// How long a returned account's unmatched cards stay frozen.
    public static let returnGrace: TimeInterval = 30 * 60
    /// A container with more cards than this that drops to a tenth or less
    /// at once is treated as unavailable (an account in a partial state).
    public static let collapseMinimum = 20
}

/// What the guard looks at.
struct AccountObservation {
    var snapshot: AppleSnapshot
    var previous: AccountsState?
    var records: RecordMap
    /// The Contacts mirror before this run (frozen values come from it).
    var mirror: () -> AppleSnapshotCache?
    var decisions: DecisionSet
    var now: Date
    var keyer: (any PhoneKeyer)?

    /// Cards per container in the snapshot.
    var cardCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for contact in snapshot.contacts {
            for card in contact.cards { counts[card.containerID, default: 0] += 1 }
        }
        return counts
    }

    func isLive(_ containerID: String) -> Bool { snapshot.containers.contains { $0.id == containerID } }
}

extension AccountGuard {
    static func evaluate(_ observation: AccountObservation) -> AccountGuard {
        var accounts = AccountGuard(state: observation.previous ?? seed(observation))
        accounts.evaluated = true
        accounts.applyForgetDecisions(observation)
        accounts.checkReturns(observation)
        accounts.detectNewlyMissing(observation)
        accounts.updateTracked(observation)
        accounts.resolveReturned(observation)
        accounts.computeAnchors(observation.records)
        return accounts
    }

    static func collapsed(_ count: Int, from previous: Int) -> Bool {
        previous > collapseMinimum && count * 10 <= previous
    }

    /// First run with the guard: the snapshot's containers, plus containers
    /// bound cards point at that are gone already.
    private static func seed(_ observation: AccountObservation) -> AccountsState {
        var state = AccountsState()
        let now = observation.now
        let counts = observation.cardCounts
        for container in observation.snapshot.containers {
            state.containers.append(
                TrackedContainer(
                    id: container.id, name: container.name, kind: container.kind,
                    cardCount: counts[container.id] ?? 0, firstSeen: now, lastSeen: now))
        }
        var bound: [String: (kind: AccountKind, count: Int)] = [:]
        for binding in observation.records.records.values {
            for card in binding.cards where !observation.isLive(card.containerID) {
                bound[card.containerID, default: (card.accountKind, 0)].count += 1
            }
        }
        let seen = observation.records.lastExport ?? now
        for (id, entry) in bound.sorted(by: { $0.key < $1.key }) {
            state.containers.append(
                TrackedContainer(
                    id: id, name: entry.kind.displayName, kind: entry.kind, cardCount: entry.count, firstSeen: seen,
                    lastSeen: seen))
        }
        return state
    }

    // MARK: Forget

    private mutating func applyForgetDecisions(_ observation: AccountObservation) {
        for account in state.unavailable where account.returnedAt == nil {
            guard let decision = observation.decisions.accountDecision(containerID: account.containerID),
                decision.choice == "forget", decision.createdAt >= account.since
            else { continue }
            forgotten.insert(account.containerID)
            for (id, binding) in observation.records.records
            where !binding.cards.isEmpty && binding.cards.allSatisfy({ $0.containerID == account.containerID }) {
                forgottenRecords.insert(id)
            }
        }
        state.unavailable.removeAll { forgotten.contains($0.containerID) }
        state.containers.removeAll { forgotten.contains($0.id) }
        // Deletions are concluded only on full snapshots (§10).
        if !forgotten.isEmpty { transitioned = true }
    }

    // MARK: Returns

    private mutating func checkReturns(_ observation: AccountObservation) {
        var claimed = Set(state.unavailable.compactMap(\.successorID))
        let counts = observation.cardCounts
        for index in state.unavailable.indices {
            let account = state.unavailable[index]
            let target =
                observation.isLive(account.containerID)
                ? account.containerID : account.successorID ?? successor(of: account, observation, claimed: claimed)
            guard let target, observation.isLive(target),
                !Self.collapsed(counts[target] ?? 0, from: account.cardCount)
            else {
                state.unavailable[index].returnedAt = nil
                state.unavailable[index].successorID = nil
                continue
            }
            claimed.insert(target)
            if account.returnedAt == nil {
                state.unavailable[index].returnedAt = observation.now
                transitioned = true
            }
            state.unavailable[index].successorID = target == account.containerID ? nil : target
        }
    }

    /// A new container of the same kind that stands in for a missing one
    /// (Contacts may give a re-enabled account a new container id): the one
    /// with the same name, else the only new one when only one is missing.
    private func successor(
        of account: UnavailableAccount, _ observation: AccountObservation, claimed: Set<String>
    ) -> String? {
        let tracked = Set(state.containers.map(\.id))
        let fresh = observation.snapshot.containers.filter {
            $0.kind == account.kind && !tracked.contains($0.id) && !claimed.contains($0.id)
        }
        if let named = fresh.first(where: { $0.name == account.name }) { return named.id }
        let missingOfKind = state.unavailable.filter { $0.kind == account.kind && $0.returnedAt == nil }
        return fresh.count == 1 && missingOfKind.count == 1 ? fresh[0].id : nil
    }

    // MARK: Missing

    private mutating func detectNewlyMissing(_ observation: AccountObservation) {
        let known = Set(state.unavailable.map(\.containerID))
        let successors = Set(state.unavailable.compactMap(\.successorID))
        let counts = observation.cardCounts
        for container in state.containers
        where container.cardCount > 0 && !known.contains(container.id) && !successors.contains(container.id) {
            let reason: UnavailableReason
            if !observation.isLive(container.id) {
                reason = .absent
            } else if Self.collapsed(counts[container.id] ?? 0, from: container.cardCount) {
                reason = .collapsed
            } else {
                continue
            }
            state.unavailable.append(frozen(container, reason: reason, observation))
            transitioned = true
        }
    }

    /// The account's cards as last seen: from the mirror, else (no mirror)
    /// the bound cards without values (their records are then frozen whole).
    private func frozen(
        _ container: TrackedContainer, reason: UnavailableReason, _ observation: AccountObservation
    ) -> UnavailableAccount {
        let lookup = Self.recordsByCard(observation.records)
        var cards: [FrozenCard] = []
        var groups: [AppleGroup] = []
        if let mirror = observation.mirror() {
            groups = mirror.groups.filter { $0.containerID == container.id }
            let groupIDs = Set(groups.map(\.id))
            for contact in mirror.contacts {
                for var card in contact.cards where card.containerID == container.id {
                    card.values = card.values ?? (contact.cards.count == 1 ? contact.contact : nil)
                    cards.append(
                        FrozenCard(
                            card: card, recordID: lookup[card.id], siblingIDs: contact.cardIDs.filter { $0 != card.id },
                            groupIDs: contact.groupIDs.filter(groupIDs.contains), unified: contact.contact,
                            notesKnown: mirror.notesAvailable && contact.notesUnknown != true,
                            hadImage: mirror.imageHashes[AppleChangeTracker.key(contact)] != nil
                                || contact.imageUnavailable))
                }
            }
        }
        let captured = Set(cards.map(\.card.id))
        for (id, binding) in observation.records.records.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for bound in binding.cards where bound.containerID == container.id && !captured.contains(bound.id) {
                cards.append(
                    FrozenCard(
                        card: AppleCard(id: bound.id, containerID: bound.containerID, accountKind: bound.accountKind),
                        recordID: id, siblingIDs: binding.cards.map(\.id).filter { $0 != bound.id }, groupIDs: [],
                        unified: nil, notesKnown: false, hadImage: true))
            }
        }
        return UnavailableAccount(
            containerID: container.id, name: container.name, kind: container.kind, cardCount: container.cardCount,
            lastSeen: container.lastSeen, since: observation.now, reason: reason, returnedAt: nil, successorID: nil,
            cards: cards.sorted { $0.card.id < $1.card.id }, groups: groups)
    }

    /// Records whose every card is in an account that was unavailable at
    /// the end of the last run (their contacts are not in Contacts now).
    static func frozenRecords(_ accounts: AccountsState?, records: RecordMap) -> Set<UUID> {
        let missing = Set(accounts?.unavailable.filter { $0.returnedAt == nil }.map(\.containerID) ?? [])
        guard !missing.isEmpty else { return [] }
        return Set(
            records.records.filter {
                !$0.value.cards.isEmpty && $0.value.cards.allSatisfy { missing.contains($0.containerID) }
            }
            .keys)
    }

    static func recordsByCard(_ records: RecordMap) -> [String: UUID] {
        var lookup: [String: UUID] = [:]
        for (id, binding) in records.records {
            for card in binding.cards where lookup[card.id] == nil { lookup[card.id] = id }
        }
        return lookup
    }

    // MARK: Tracking

    private mutating func updateTracked(_ observation: AccountObservation) {
        let unavailable = unavailableContainerIDs
        let counts = observation.cardCounts
        for container in observation.snapshot.containers where !unavailable.contains(container.id) {
            let count = counts[container.id] ?? 0
            if let index = state.containers.firstIndex(where: { $0.id == container.id }) {
                state.containers[index].name = container.name
                state.containers[index].kind = container.kind
                state.containers[index].cardCount = count
                state.containers[index].lastSeen = observation.now
            } else {
                state.containers.append(
                    TrackedContainer(
                        id: container.id, name: container.name, kind: container.kind, cardCount: count,
                        firstSeen: observation.now, lastSeen: observation.now))
            }
        }
    }

    /// The live cards each frozen card attaches to.
    private mutating func computeAnchors(_ records: RecordMap) {
        for account in state.unavailable {
            for frozen in account.cards {
                let recordCards = frozen.recordID.flatMap { records[$0]?.cards.map(\.id) } ?? []
                anchors[frozen.card.id] = Array(Set(frozen.siblingIDs + recordCards).subtracting([frozen.card.id]))
                    .sorted()
            }
        }
    }

    /// Stores the tracked accounts after a run (`executed`: resolved and
    /// forgotten accounts are dropped; a dry run only adds what it found).
    func save(executed: Bool, in state: any SyncStateStore) throws {
        guard evaluated else { return }
        try Self.save(self.state, forgotten: forgotten, executed: executed, in: state)
    }

    /// The record map with frozen cards replaced by the returned cards
    /// matched to them (trusted: matched by id, stamp or strong keys).
    func rebind(_ records: RecordMap) -> RecordMap {
        guard !rebound.isEmpty else { return records }
        var map = records
        for (id, cards) in rebound {
            guard var binding = map[id] else { continue }
            binding.cards = binding.cards.map { bound in
                guard let card = cards[bound.id] else { return bound }
                return BoundCard(
                    id: card.id, containerID: card.containerID, accountKind: card.accountKind,
                    firstSeen: bound.firstSeen, stampSeen: card.stampID == id, confirmed: true)
            }
            map[id] = binding
        }
        return map
    }
}

extension DecisionSet {
    /// The latest `wait` / `forget` decision for the account in `containerID`.
    public func accountDecision(containerID: String) -> Decision? {
        all.last { $0.kind == .accountMissing && $0.path == containerID }
    }
}
