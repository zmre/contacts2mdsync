public import ContactModel
internal import Foundation
internal import Synchronization

extension FakeContactStore {
    /// Every card's note as Contacts.app scripting sees it (notes are stored
    /// on the cards even when the store has no notes entitlement; card id →
    /// text, `nil` = no note).
    public func scriptedNotes() -> [String: String?] {
        state.withLock { state in
            var notes: [String: String?] = [:]
            for contact in state.contacts {
                for card in contact.cards {
                    notes[card.id] = .some(Self.scriptedNote(of: card, in: contact))
                }
            }
            return notes
        }
    }

    /// Sets a card's note as Contacts.app does (`set note … ; save`): one
    /// change-history event on that card, authored by nobody we exclude.
    /// Throws `cardNotFound` for an unknown card.
    public func scriptedSetNote(cardID: String, text: String) throws {
        try state.withLock { state in
            guard let index = state.contacts.firstIndex(where: { $0.cards.contains { $0.id == cardID } }),
                let cardIndex = state.contacts[index].cards.firstIndex(where: { $0.id == cardID })
            else { throw ContactStoreError.cardNotFound(cardID) }
            FakeCardValues.materialize(&state.contacts[index])
            state.contacts[index].cards[cardIndex].values?.body = text.isEmpty ? nil : text
            state.saveSequence += 1
            state.lastSaved[cardID] = state.saveSequence
            FakeCardValues.recomputeUnified(&state.contacts[index], lastSaved: state.lastSaved)
            // Notes are per card: the unified view's body follows the most
            // recently saved card, like every single-valued field.
            state.history.append((nil, .changed(cardID)))
        }
    }

    /// A card's note: its own values, or the unified view for a contact
    /// whose cards were never written.
    static func scriptedNote(of card: AppleCard, in contact: AppleContact) -> String? {
        if let values = card.values { return values.body }
        return contact.cards.count == 1 ? contact.contact.body : nil
    }
}

/// A `NotesProvider` over a `FakeContactStore`'s card notes: what
/// Contacts.app scripting does, with switchable permission, failures and
/// line-ending conversion. Never touches Apple Events.
public final class FakeNotesProvider: NotesProvider {
    struct State {
        var permission: NotesPermission = .granted
        var failReads = false
        var failWrites = false
        /// Cards scripting cannot see (absent from reads, writes fail).
        var hidden = Set<String>()
        /// Cards that silently keep their old note on write.
        var refusing = Set<String>()
        /// Contacts stores line breaks as `\r` (classic) on write.
        var classicLineEndings = false
        var bulkReads = 0
        var cardReads: [[String]] = []
        var writes: [[String: String?]] = []
        var availabilityChecks = 0
        var permissionRequests = 0
        var finishedSessions = 0
        var promptAnswer: NotesPermission = .granted
    }

    public let store: FakeContactStore
    public let source: NotesSource
    private let state = Mutex(State())

    /// Creates a provider reading and writing `store`'s card notes.
    public init(store: FakeContactStore, source: NotesSource = .scripting) {
        self.store = store
        self.source = source
    }

    // MARK: - Switches

    /// The Automation permission macOS reports.
    public func setPermission(_ permission: NotesPermission) { state.withLock { $0.permission = permission } }
    /// What the user answers when `requestPermission()` prompts.
    public func setPromptAnswer(_ answer: NotesPermission) { state.withLock { $0.promptAnswer = answer } }
    /// Every read throws (Contacts.app not answering).
    public func setFailReads(_ fail: Bool) { state.withLock { $0.failReads = fail } }
    /// Every write throws (a session-level failure).
    public func setFailWrites(_ fail: Bool) { state.withLock { $0.failWrites = fail } }
    /// Scripting cannot see these cards (e.g. not synced into Contacts.app yet).
    public func hide(_ cardIDs: [String]) { state.withLock { $0.hidden.formUnion(cardIDs) } }
    /// These cards keep their old note when written.
    public func refuseWrites(_ cardIDs: [String]) { state.withLock { $0.refusing.formUnion(cardIDs) } }
    /// Contacts stores `\n` as `\r` on write.
    public func setClassicLineEndings(_ enabled: Bool) { state.withLock { $0.classicLineEndings = enabled } }

    // MARK: - Counters

    public var bulkReads: Int { state.withLock { $0.bulkReads } }
    /// Card ids of each partial read.
    public var cardReads: [[String]] { state.withLock { $0.cardReads } }
    /// Each `write` call's notes.
    public var writes: [[String: String?]] { state.withLock { $0.writes } }
    public var availabilityChecks: Int { state.withLock { $0.availabilityChecks } }
    public var permissionRequests: Int { state.withLock { $0.permissionRequests } }
    public var finishedSessions: Int { state.withLock { $0.finishedSessions } }

    // MARK: - NotesProvider

    public func availability() -> NotesAvailability {
        state.withLock { state in
            state.availabilityChecks += 1
            return .scripting(state.permission)
        }
    }

    public func currentPermission() -> NotesPermission { state.withLock { $0.permission } }

    public func requestPermission() -> NotesAvailability {
        state.withLock { state in
            state.permissionRequests += 1
            if state.permission == .notDetermined || state.permission == .unknown {
                state.permission = state.promptAnswer
            }
            return .scripting(state.permission)
        }
    }

    public func readAll(cardIDs: [String]?) throws -> [String: String?] {
        let (fail, permission, hidden) = state.withLock { state in
            if let cardIDs { state.cardReads.append(cardIDs) } else { state.bulkReads += 1 }
            return (state.failReads, state.permission, state.hidden)
        }
        guard permission == .granted else {
            throw NotesUnavailableError("Automation permission for Contacts not granted", permissionDenied: true)
        }
        if fail { throw NotesUnavailableError("Contacts.app is not answering") }
        var notes = store.scriptedNotes().filter { !hidden.contains($0.key) }
        if let cardIDs {
            let wanted = Set(cardIDs)
            notes = notes.filter { wanted.contains($0.key) }
        }
        return notes
    }

    public func write(_ notes: [String: String?]) throws -> NotesWriteResult {
        let (fail, permission, hidden, refusing, classic) = state.withLock { state in
            state.writes.append(notes)
            return (state.failWrites, state.permission, state.hidden, state.refusing, state.classicLineEndings)
        }
        guard permission == .granted else {
            throw NotesUnavailableError("Automation permission for Contacts not granted", permissionDenied: true)
        }
        if fail { throw NotesUnavailableError("Contacts.app is not answering") }
        var result = NotesWriteResult()
        for (id, text) in notes.sorted(by: { $0.key < $1.key }) {
            if hidden.contains(id) {
                result.failed[id] = "Contacts.app scripting error -1728: Can't get person id \"\(id)\"."
                continue
            }
            if refusing.contains(id) {
                result.failed[id] = "Contacts kept a different note"
                continue
            }
            var value = text ?? ""
            if classic { value = value.replacingOccurrences(of: "\n", with: "\r") }
            do {
                try store.scriptedSetNote(cardID: id, text: value)
                result.written.append(id)
            } catch {
                result.failed[id] = String(describing: error)
            }
        }
        return result
    }

    public func finishSession() { state.withLock { $0.finishedSessions += 1 } }
}
