internal import ContactModel
internal import Foundation

/// An account that came back: its cards are matched to the frozen ones they
/// replace (architecture §9 "Unavailable accounts").
///
/// A frozen card is resolved when
/// - a card with its id is back (iCloud and On My Mac ids are stable), or
///   a returned card carries its stamp (or its record's);
/// - the record's other cards are linked to a returned card again (Contacts
///   re-links iCloud and Google cards of the same person by itself);
/// - for a record that had no other card: exactly one returned contact
///   shares a strong key (email, phone) with it and has a compatible name,
///   and that contact matches no other frozen card. The record is then
///   bound to the returned card.
///
/// Until then, during `returnGrace`, the frozen card is kept as last seen,
/// and returned contacts that no record claims yet are held back (one may
/// be its replacement, still syncing down), so nothing shows up as new or
/// as a duplicate. After the grace period a frozen card with no match at all is
/// dropped (the card is really gone), while one whose returned contact is
/// still unlinked stays frozen and the duplicate is reviewed as usual.
extension AccountGuard {
    mutating func resolveReturned(_ observation: AccountObservation) {
        let live = LiveCards(observation.snapshot)
        let lookup = Self.recordsByCard(observation.records)
        for index in state.unavailable.indices where state.unavailable[index].returnedAt != nil {
            let account = state.unavailable[index]
            let inGrace = observation.now.timeIntervalSince(account.returnedAt ?? observation.now) < Self.returnGrace
            let container = account.currentContainerID
            var pending: [FrozenCard] = []
            for frozen in account.cards {
                if let card = structuralMatch(frozen, container: container, live: live, observation) {
                    if let record = frozen.recordID, card.id != frozen.card.id {
                        rebound[record, default: [:]][frozen.card.id] = card
                    }
                } else {
                    pending.append(frozen)
                }
            }
            let matches = valueMatches(pending, container: container, live: live, lookup: lookup, observation)
            var kept: [FrozenCard] = []
            for frozen in pending {
                let linked = isLinkedRecord(frozen, live: live, observation)
                if let card = matches[frozen.card.id] {
                    if !linked, let record = frozen.recordID {
                        rebound[record, default: [:]][frozen.card.id] = card
                        continue
                    }
                    if inGrace { hiddenCardIDs.formUnion(live.contact(of: card.id)?.cardIDs ?? [card.id]) }
                    kept.append(frozen)
                } else if inGrace {
                    kept.append(frozen)
                }
            }
            state.unavailable[index].cards = kept
            if inGrace, !kept.isEmpty { holdUnclaimed(in: container, live: live, lookup: lookup) }
        }
        closeResolved()
    }

    /// During the grace period, returned contacts no record claims (by id,
    /// stamp or a match) are held back: one of them may still be a frozen
    /// card's replacement, and exporting it now would duplicate a note.
    private mutating func holdUnclaimed(in container: String, live: LiveCards, lookup: [String: UUID]) {
        let claimed = Set(rebound.values.flatMap { $0.values.map(\.id) })
        for contact in live.contacts where contact.cards.allSatisfy({ $0.containerID == container }) {
            guard
                !contact.cards.contains(where: { lookup[$0.id] != nil || claimed.contains($0.id) || $0.stampID != nil })
            else { continue }
            hiddenCardIDs.formUnion(contact.cardIDs)
        }
    }

    /// Accounts whose every card was matched (or dropped) are done.
    private mutating func closeResolved() {
        let done = state.unavailable.filter { $0.returnedAt != nil && $0.cards.isEmpty }
        for account in done where account.successorID != nil {
            state.containers.removeAll { $0.id == account.containerID }
        }
        state.unavailable.removeAll { $0.returnedAt != nil && $0.cards.isEmpty }
    }

    /// The returned card that is this frozen card: same id, the same stamp,
    /// or a card linked again with the record's other cards.
    private func structuralMatch(
        _ frozen: FrozenCard, container: String, live: LiveCards, _ observation: AccountObservation
    ) -> AppleCard? {
        if let card = live.card(frozen.card.id) { return card }
        for stamp in [frozen.card.stampID, frozen.recordID].compactMap({ $0 }) {
            if let card = live.stamped(stamp, in: container) { return card }
        }
        let others = otherCards(of: frozen, observation)
        for id in others {
            guard let contact = live.contact(of: id) else { continue }
            if let card = contact.cards.first(where: { $0.containerID == container }) { return card }
        }
        return nil
    }

    /// Ids of the cards the frozen card was linked with (and its record's).
    private func otherCards(of frozen: FrozenCard, _ observation: AccountObservation) -> [String] {
        let recordCards = frozen.recordID.flatMap { observation.records[$0]?.cards.map(\.id) } ?? []
        return Array(Set(frozen.siblingIDs + recordCards).subtracting([frozen.card.id])).sorted()
    }

    /// `true` when the frozen card's record still has a live card elsewhere.
    private func isLinkedRecord(_ frozen: FrozenCard, live: LiveCards, _ observation: AccountObservation) -> Bool {
        otherCards(of: frozen, observation).contains { live.card($0) != nil }
    }

    /// Frozen card id → the one returned card (of a contact made only of
    /// returned cards, claimed by no record) sharing a strong key and a
    /// compatible name with it, when the match is unique both ways.
    private func valueMatches(
        _ pending: [FrozenCard], container: String, live: LiveCards, lookup: [String: UUID],
        _ observation: AccountObservation
    ) -> [String: AppleCard] {
        // Each returned contact is keyed once (phone keys are not cheap).
        var byKey: [String: [(card: AppleCard, values: CanonicalContact)]] = [:]
        for contact in live.contacts
        where contact.cards.allSatisfy({ $0.containerID == container })
            && !contact.cards.contains(where: { lookup[$0.id] != nil || $0.stampID != nil })
        {
            guard let card = contact.cards.first, let values = contact.values(of: card) else { continue }
            for key in Self.strongKeys(values, keyer: observation.keyer) {
                byKey[key, default: []].append((card, values))
            }
        }
        guard !byKey.isEmpty else { return [:] }
        var byFrozen: [String: [AppleCard]] = [:]
        var byCard: [String: Int] = [:]
        for frozen in pending {
            guard let values = frozen.card.values else { continue }
            var seen = Set<String>()
            for key in Self.strongKeys(values, keyer: observation.keyer).sorted() {
                for candidate in byKey[key] ?? []
                where seen.insert(candidate.card.id).inserted && NameCompatibility.compatible(values, candidate.values)
                {
                    byFrozen[frozen.card.id, default: []].append(candidate.card)
                    byCard[candidate.card.id, default: 0] += 1
                }
            }
        }
        return byFrozen.compactMapValues { cards in
            cards.count == 1 && byCard[cards[0].id] == 1 ? cards[0] : nil
        }
    }

    /// Email and phone comparison keys (phones only with a keyer).
    static func strongKeys(_ contact: CanonicalContact, keyer: (any PhoneKeyer)?) -> Set<String> {
        var keys = Set(contact.emails.map { "email:" + ComparisonKeys.email($0.value) })
        if let keyer {
            keys.formUnion(contact.phones.map { "phone:" + ComparisonKeys.phone($0.value, keyer: keyer) })
        }
        return keys.filter { !$0.hasSuffix(":") }
    }
}

/// The live snapshot indexed by card.
struct LiveCards {
    let contacts: [AppleContact]
    private let byCard: [String: (contact: Int, card: AppleCard)]
    private let byStamp: [String: AppleCard]

    init(_ snapshot: AppleSnapshot) {
        contacts = snapshot.contacts
        var index: [String: (contact: Int, card: AppleCard)] = [:]
        var stamps: [String: AppleCard] = [:]
        for (offset, contact) in snapshot.contacts.enumerated() {
            for card in contact.cards {
                index[card.id] = (offset, card)
                guard let stamp = card.stampID else { continue }
                let key = "\(card.containerID)|\(stamp)"
                if stamps[key].map({ card.id < $0.id }) ?? true { stamps[key] = card }
            }
        }
        byCard = index
        byStamp = stamps
    }

    func card(_ id: String) -> AppleCard? { byCard[id]?.card }

    func contact(of cardID: String) -> AppleContact? { byCard[cardID].map { contacts[$0.contact] } }

    /// The card in `container` carrying `stamp` (lowest id when several do).
    func stamped(_ stamp: UUID, in container: String) -> AppleCard? { byStamp["\(container)|\(stamp)"] }
}
