public import ContactModel
internal import Foundation
internal import Synchronization

/// Inspecting the fake store and editing it as a user would in Contacts.app.
extension FakeContactStore {
    /// Batches applied so far, with their transaction authors.
    public var appliedBatches: [(batch: AppleWriteBatch, author: String)] { state.withLock { $0.batches } }

    /// All operations applied so far, in order.
    public var appliedOperations: [AppleWriteOperation] {
        state.withLock { $0.batches.flatMap(\.batch.operations) }
    }

    /// Number of vCard exports (backups) taken.
    public var vCardExportCount: Int { state.withLock { $0.vCardExports } }

    /// Operations addressed to a unified id instead of a card (must stay 0).
    public var unifiedSaveCount: Int { state.withLock { $0.unifiedSaves } }

    /// Replaces the contacts (simulate edits made in Contacts.app). The
    /// change history is reset too (older tokens get `DropEverything`).
    public func replaceContacts(_ contacts: [AppleContact]) {
        state.withLock {
            $0.contacts = contacts
            $0.historyEpoch += 1
            $0.history = []
        }
    }

    /// Current contacts (including writes applied so far).
    public var contacts: [AppleContact] { state.withLock { $0.contacts } }

    /// The contact holding `cardID`.
    public func contact(withCard cardID: String) -> AppleContact? {
        state.withLock { state in state.contacts.first { $0.cards.contains { $0.id == cardID } } }
    }

    /// One card's values (its own, or the unified view of a single-card contact).
    public func values(ofCard cardID: String) -> CanonicalContact? {
        state.withLock { state in
            guard let contact = state.contacts.first(where: { $0.cards.contains { $0.id == cardID } }),
                let card = contact.cards.first(where: { $0.id == cardID })
            else { return nil }
            return contact.values(of: card)
        }
    }

    /// Edits one card as the user would in Contacts.app (it becomes the most
    /// recently saved card of its contact).
    public func editCard(_ cardID: String, _ edit: (inout CanonicalContact) -> Void) {
        state.withLock { state in
            guard let index = state.contacts.firstIndex(where: { $0.cards.contains { $0.id == cardID } }) else {
                return
            }
            FakeCardValues.materialize(&state.contacts[index])
            guard let cardIndex = state.contacts[index].cards.firstIndex(where: { $0.id == cardID }),
                var values = state.contacts[index].cards[cardIndex].values
            else { return }
            edit(&values)
            state.contacts[index].cards[cardIndex].values = values
            state.history.append((nil, .changed(cardID)))
            state.saveSequence += 1
            state.lastSaved[cardID] = state.saveSequence
            FakeCardValues.recomputeUnified(&state.contacts[index], lastSaved: state.lastSaved)
        }
    }

    /// Edits a contact's groups, image or image availability as Contacts.app would.
    public func editContact(withCard cardID: String, _ edit: (inout AppleContact) -> Void) {
        state.withLock { state in
            guard let index = state.contacts.firstIndex(where: { $0.cards.contains { $0.id == cardID } }) else {
                return
            }
            let before = state.contacts[index]
            edit(&state.contacts[index])
            for card in Set(before.cards.map(\.id) + state.contacts[index].cards.map(\.id)).sorted() {
                state.history.append((nil, .changed(card)))
            }
        }
    }

    /// Adds a contact (created in Contacts.app).
    public func add(_ contact: AppleContact) {
        state.withLock { state in
            state.contacts.append(contact)
            for card in contact.cards { state.history.append((nil, .changed(card.id))) }
        }
    }

    /// Deletes the contact holding `cardID` (all its cards), as in Contacts.app.
    public func deleteContact(withCard cardID: String) {
        state.withLock { state in
            let removed = state.contacts.filter { $0.cards.contains { $0.id == cardID } }
            state.contacts.removeAll { $0.cards.contains { $0.id == cardID } }
            for card in removed.flatMap(\.cards) { state.history.append((nil, .deleted(card.id))) }
        }
    }

    /// Links the contacts with these (stored) unified ids into one, as
    /// Contacts does on its own for same-name iCloud + Google cards. Each card
    /// keeps its own values; the unified view takes single-valued fields from
    /// the last contact and the union of multi-valued ones.
    public func link(_ unifiedIDs: [String]) {
        state.withLock { state in
            let members = unifiedIDs.compactMap { id in state.contacts.first { $0.unifiedID == id } }
            guard members.count > 1 else { return }
            state.contacts.removeAll { unifiedIDs.contains($0.unifiedID) }
            var cards: [AppleCard] = []
            for member in members {
                for var card in member.cards {
                    if card.values == nil { card.values = member.contact }
                    cards.append(card)
                }
            }
            for card in cards { state.history.append((nil, .changed(card.id))) }
            var unified = members.last?.contact ?? members[0].contact
            for member in members.dropLast() {
                unified.emails += member.contact.emails.filter { !unified.emails.contains($0) }
                unified.phones += member.contact.phones.filter { !unified.phones.contains($0) }
            }
            state.contacts.append(
                AppleContact(
                    unifiedID: members[0].unifiedID, cards: cards, contact: unified,
                    imageData: members.compactMap(\.imageData).last,
                    groupIDs: Array(Set(members.flatMap(\.groupIDs))).sorted()))
        }
    }

    /// Changes every Google card id once (`x` → `x~google-sync`), like Google
    /// sync replacing a newly created card. Single-card contacts' unified ids
    /// change with them; stamps and values are kept.
    public func churnGoogleCardIDs() {
        state.withLock { state in
            for contactIndex in state.contacts.indices {
                var contact = state.contacts[contactIndex]
                for cardIndex in contact.cards.indices where contact.cards[cardIndex].accountKind == .google {
                    let old = contact.cards[cardIndex].id
                    guard !state.churned.contains(old) else { continue }
                    let new = old + "~google-sync"
                    state.churned.insert(new)
                    state.history.append((nil, .deleted(old)))
                    state.history.append((nil, .changed(new)))
                    contact.cards[cardIndex].id = new
                    if contact.unifiedID == old { contact.unifiedID = new }
                }
                state.contacts[contactIndex] = contact
            }
        }
    }
}

/// Change history controls (M5).
extension FakeContactStore {
    /// Invalidates every token handed out so far: the next history read from
    /// an older token gets `DropEverything` (`.reset`), as after a Contacts
    /// database rebuild or a garbage token (spike S3).
    public func resetHistory() {
        state.withLock {
            $0.historyEpoch += 1
            $0.history = []
        }
    }

    /// `false`: `changes(since:)` returns `.unsupported` and there is no token.
    public func setHistorySupported(_ supported: Bool) { state.withLock { $0.historySupported = supported } }

    /// The next history read throws (error 603-style failure).
    public func failNextHistory() { state.withLock { $0.failNextHistory = true } }

    /// A group was added, renamed or deleted (a group-level history event).
    public func recordGroupChange() { state.withLock { $0.history.append((nil, .group)) } }

    /// Full snapshots taken so far.
    public var snapshotCount: Int { state.withLock { $0.snapshots } }

    /// History reads so far.
    public var historyReadCount: Int { state.withLock { $0.historyReads } }

    /// Card ids of each `refetch` call so far.
    public var refetchedCardIDs: [[String]] { state.withLock { $0.refetches } }
}
