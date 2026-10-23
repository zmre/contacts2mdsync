public import ContactModel
public import Foundation
internal import Synchronization

/// An account's container and cards as they were when it was turned off,
/// so a test can turn it back on.
public struct RemovedContainer: Sendable {
    /// One removed card and what it was part of.
    public struct Card: Sendable {
        public var card: AppleCard
        /// The cards it was linked with (still in the store).
        public var siblings: [String]
        /// Groups of its contact in the removed container.
        public var groupIDs: [String]
        /// The image of a contact that had no other card.
        public var image: Data?
    }

    public var container: AppleContainer
    public var cards: [Card]
    public var groups: [AppleGroup]
}

/// Accounts turned off and on, as in System Settings ▸ Internet Accounts:
/// macOS removes every card of the account's container from the local store
/// (and the container itself), and adds them back later, Google cards with
/// new identifiers.
extension FakeContactStore {
    /// Turns an account off: its container, groups and every card disappear
    /// (history: one deletion per card). Linked contacts keep their other cards.
    @discardableResult
    public func removeContainer(_ id: String) -> RemovedContainer {
        state.withLock { state in
            let container =
                state.containers.first { $0.id == id } ?? AppleContainer(id: id, name: id, kind: .unknown)
            var removed = Self.removeCards(in: &state) { $0.containerID == id }
            state.containers.removeAll { $0.id == id }
            removed.groups = state.groups.filter { $0.containerID == id }
            let groupIDs = Set(removed.groups.map(\.id))
            state.groups.removeAll { $0.containerID == id }
            for index in state.contacts.indices { state.contacts[index].groupIDs.removeAll(where: groupIDs.contains) }
            return RemovedContainer(container: container, cards: removed.cards, groups: removed.groups)
        }
    }

    /// An account in a partial state: the container stays, but all its cards
    /// except the first `keeping` (by id) disappear.
    @discardableResult
    public func collapseContainer(_ id: String, keeping: Int) -> RemovedContainer {
        state.withLock { state in
            let container =
                state.containers.first { $0.id == id } ?? AppleContainer(id: id, name: id, kind: .unknown)
            let ids = state.contacts.flatMap(\.cards).filter { $0.containerID == id }.map(\.id).sorted()
            let kept = Set(ids.prefix(keeping))
            let removed = Self.removeCards(in: &state) { $0.containerID == id && !kept.contains($0.id) }
            return RemovedContainer(container: container, cards: removed.cards, groups: [])
        }
    }

    /// Turns the account back on: its container (as `containerID` when
    /// Contacts gives it a new one) and cards come back, card ids mapped
    /// through `cardID` (Google gives cards new ids). With `link`, a card
    /// rejoins the contact of its old siblings (Contacts' automatic
    /// linking); otherwise it comes back as a contact of its own.
    public func restoreContainer(
        _ removed: RemovedContainer, containerID: String? = nil, cardID: (String) -> String = { $0 },
        link: Bool = true
    ) {
        state.withLock { state in
            let newID = containerID ?? removed.container.id
            var container = removed.container
            container.id = newID
            if !state.containers.contains(where: { $0.id == newID }) { state.containers.append(container) }
            for var group in removed.groups where !state.groups.contains(where: { $0.id == group.id }) {
                group.containerID = newID
                state.groups.append(group)
            }
            for entry in removed.cards {
                var card = entry.card
                card.id = cardID(card.id)
                card.containerID = newID
                Self.restore(card, entry: entry, link: link, in: &state)
                state.history.append((nil, .changed(card.id)))
            }
        }
    }

    private static func restore(_ card: AppleCard, entry: RemovedContainer.Card, link: Bool, in state: inout State) {
        let anchor =
            link
            ? state.contacts.firstIndex { contact in contact.cards.contains { entry.siblings.contains($0.id) } } : nil
        guard let anchor else {
            let values = card.values ?? CanonicalContact(kind: .person, title: "")
            state.contacts.append(
                AppleContact(
                    unifiedID: card.id, cards: [card], contact: values, imageData: entry.image,
                    groupIDs: entry.groupIDs))
            return
        }
        FakeCardValues.materialize(&state.contacts[anchor])
        state.contacts[anchor].cards.append(card)
        for group in entry.groupIDs where !state.contacts[anchor].groupIDs.contains(group) {
            state.contacts[anchor].groupIDs.append(group)
        }
        FakeCardValues.recomputeUnified(&state.contacts[anchor], lastSaved: state.lastSaved)
    }

    /// Removes matching cards (contacts left without cards go too).
    private static func removeCards(
        in state: inout State, where matches: (AppleCard) -> Bool
    ) -> (cards: [RemovedContainer.Card], groups: [AppleGroup]) {
        var removed: [RemovedContainer.Card] = []
        var kept: [AppleContact] = []
        for var contact in state.contacts {
            guard contact.cards.contains(where: matches) else {
                kept.append(contact)
                continue
            }
            FakeCardValues.materialize(&contact)
            let gone = contact.cards.filter(matches)
            let remaining = contact.cards.filter { !matches($0) }
            for card in gone {
                removed.append(
                    RemovedContainer.Card(
                        card: card, siblings: remaining.map(\.id),
                        groupIDs: contact.groupIDs.filter { id in
                            state.groups.contains { $0.id == id && $0.containerID == card.containerID }
                        },
                        image: remaining.isEmpty ? contact.imageData : nil))
                state.history.append((nil, .deleted(card.id)))
            }
            guard !remaining.isEmpty else { continue }
            contact.cards = remaining
            if remaining.count == 1 { contact.unifiedID = remaining[0].id }
            FakeCardValues.recomputeUnified(&contact, lastSaved: state.lastSaved)
            kept.append(contact)
        }
        state.contacts = kept
        return (removed, [])
    }
}

extension Fixtures {
    /// A contact whose cards each have their own values (as the real adapter
    /// reads them): one card per entry, ids `<id>:<account kind>`, the
    /// unified view derived from the cards like Contacts does.
    public static func linked(
        _ id: String, _ cards: [(AccountKind, CanonicalContact)], groups: [AppleGroup] = []
    ) -> AppleContact {
        var contact = contact(id, accounts: cards.map(\.0), groups: groups) { _ in }
        for index in contact.cards.indices { contact.cards[index].values = cards[index].1 }
        FakeCardValues.recomputeUnified(&contact, lastSaved: [:])
        return contact
    }
}
