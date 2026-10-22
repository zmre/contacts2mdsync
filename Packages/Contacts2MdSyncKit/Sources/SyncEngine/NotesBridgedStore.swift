public import ContactModel
public import Foundation
internal import Synchronization

/// What happened to notes during one run of a `NotesBridgedStore`.
public struct NotesRunLog: Hashable, Sendable {
    /// Set when a notes read failed: the run went on without notes.
    public var readFailure: String?
    /// The read failed because Automation permission is not granted.
    public var readFailureIsPermission = false
    /// One line per note write that did not happen (session or card failures).
    public var writeWarnings: [String] = []
    /// Bulk reads (every card) and per-card reads made.
    public var bulkReads = 0
    public var cardReads = 0
    /// Re-read notes recognized as the echo of this process's own write
    /// (same card, same text): not a change made in Contacts.
    public var ownWritesSeen = 0
    /// Notes written (cards).
    public var written = 0

    /// Creates an empty log.
    public init() {}
}

/// Remembers the notes this process wrote through Contacts.app, as
/// (card id, hash of the text) with the time of the write.
///
/// Contacts.app saves are not tagged with our `transactionAuthor`, so the
/// change history cannot exclude them by author. Two things keep them from
/// counting as changes made in Contacts:
///
/// - The executor reads the history token *after* the Apple writes (notes
///   included), so the events of our writes are older than the token the
///   next run starts from (spike S12: Contacts.app records one
///   `UpdateContactEvent` on the target card when `save` returns).
/// - Should an event arrive late anyway, the next run re-reads that card's
///   note; when it hashes to what we wrote within `ttl`, it is recognized as
///   our own echo (counted in `NotesRunLog.ownWritesSeen`) — and the merge
///   finds no change, because the base was refreshed from the same text.
///
/// The registry is never trusted *instead of* a read: a user may edit the
/// same note in Contacts right after our write, and only a read sees that.
public final class NotesOwnWrites: Sendable {
    private struct Entry {
        var hash: String
        var writtenAt: Date
    }

    private let entries = Mutex<[String: Entry]>([:])
    /// How long an own write is remembered.
    public let ttl: TimeInterval

    /// Creates an empty registry.
    public init(ttl: TimeInterval = 30) { self.ttl = ttl }

    /// Records the note written to `cardID` (`""` = cleared).
    public func record(cardID: String, text: String, at date: Date) {
        entries.withLock { $0[cardID] = Entry(hash: Self.hash(text), writtenAt: date) }
    }

    /// `true` when `note`, just read from `cardID`, is the text this process
    /// wrote there less than `ttl` ago (the entry is used up either way).
    public func recognize(cardID: String, note: String?, now: Date) -> Bool {
        entries.withLock { entries in
            guard let entry = entries.removeValue(forKey: cardID) else { return false }
            return now.timeIntervalSince(entry.writtenAt) <= ttl && entry.hash == Self.hash(note ?? "")
        }
    }

    private static func hash(_ text: String) -> String {
        hexSHA256(Data(AppleNoteText.note(fromBody: text).utf8))
    }

    /// Number of remembered writes (tests).
    public var count: Int { entries.withLock { $0.count } }
}

/// A `ContactStore` that adds Contacts notes read and written through a
/// `NotesProvider` (Contacts.app scripting) to a store that cannot see them
/// (architecture §8 "Notes").
///
/// - **Reads** happen once per store read, after the Contacts.framework read:
///   `snapshot()` reads every card's note in one bulk call; `refetch` and
///   `fetch` read only the cards they return (per card, or one bulk read
///   when there are more than `bulkThreshold`). Each card's note goes into
///   its `values.body`; the contact's body is the note of the first card in
///   precedence order that has one (the same rule as every single-valued
///   field). A card the provider did not see makes the contact's notes
///   unknown (`AppleContact.notesUnknown`), never empty.
/// - **Writes**: `.note` edits are taken out of the batch; the rest goes to
///   the inner store first, then each note is written to its card, after the
///   notes about to be overwritten were handed to `backup`.
/// - **Failures**: a failed read leaves the run without notes
///   (`notesAvailable == false`, `log.readFailure`); a failed write of the
///   whole session reports those operations as failed (retried next run);
///   a card that refuses its note keeps the operation applied, so the
///   executor's verification marks the note unapplyable for that card.
public final class NotesBridgedStore: ContactStore {
    public let inner: any ContactStore
    public let provider: any NotesProvider
    public let ownWrites: NotesOwnWrites
    /// More cards than this in a partial read → one bulk read instead
    /// (≈0.5 s for 3,785 cards vs ≈9 ms per card, spike S12).
    public let bulkThreshold: Int
    /// Saves the notes about to be overwritten (card id → old text) before
    /// any note write; a throw stops the note writes.
    let backup: (@Sendable ([String: String?]) throws -> Void)?
    let now: @Sendable () -> Date
    private let state = Mutex(NotesRunLog())

    /// Creates a bridge over `inner`.
    public init(
        inner: any ContactStore, provider: any NotesProvider, ownWrites: NotesOwnWrites = NotesOwnWrites(),
        bulkThreshold: Int = 40, backup: (@Sendable ([String: String?]) throws -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inner = inner
        self.provider = provider
        self.ownWrites = ownWrites
        self.bulkThreshold = bulkThreshold
        self.backup = backup
        self.now = now
    }

    /// What happened to notes so far.
    public var log: NotesRunLog { state.withLock { $0 } }

    // MARK: - ContactStore

    public var capabilities: StoreCapabilities {
        get throws {
            var capabilities = try inner.capabilities
            capabilities.notesAvailable = true
            return capabilities
        }
    }

    public func snapshot() throws -> AppleSnapshot {
        var snapshot = try inner.snapshot()
        guard let notes = read(cardIDs: nil) else {
            snapshot.contacts = snapshot.contacts.map(Self.withoutNotes)
            snapshot.notesAvailable = false
            return snapshot
        }
        snapshot.contacts = Self.overlay(snapshot.contacts, notes: notes)
        snapshot.notesAvailable = true
        return snapshot
    }

    public func fetch(unifiedIDs: [String]) throws -> [AppleContact] {
        let contacts = try inner.fetch(unifiedIDs: unifiedIDs)
        guard let notes = read(cardIDs: contacts.flatMap(\.cardIDs)) else { return contacts.map(Self.withoutNotes) }
        return Self.overlay(contacts, notes: notes)
    }

    public func refetch(cardIDs: [String], siblingHints: [String]) throws -> AppleRefetch {
        var result = try inner.refetch(cardIDs: cardIDs, siblingHints: siblingHints)
        let wanted = result.contacts.flatMap(\.cardIDs)
        guard let notes = wanted.isEmpty ? [:] : read(cardIDs: wanted) else {
            result.contacts = result.contacts.map(Self.withoutNotes)
            result.notesAvailable = false
            return result
        }
        let date = now()
        let echoes = notes.filter { ownWrites.recognize(cardID: $0.key, note: $0.value, now: date) }.count
        if echoes > 0 { state.withLock { $0.ownWritesSeen += echoes } }
        result.contacts = Self.overlay(result.contacts, notes: notes)
        result.notesAvailable = true
        return result
    }

    public func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult {
        try inner.changes(since: token, excluding: authors)
    }

    public func currentHistoryToken() throws -> Data? { try inner.currentHistoryToken() }

    public func exportVCards() throws -> Data { try inner.exportVCards() }

    public func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        let split = SplitBatch(batch)
        let innerResult =
            split.inner.isEmpty
            ? AppleWriteResult(applied: []) : try inner.apply(AppleWriteBatch(operations: split.inner), author: author)
        var result = AppleWriteResult(applied: [], createdCardIDs: innerResult.createdCardIDs)
        var failedOriginals: [AppleWriteOperation: String] = [:]
        for failure in innerResult.failed {
            if let original = split.original[failure.operation] { failedOriginals[original] = failure.message }
        }
        let appliedInner = Set(innerResult.applied)
        // Notes go only to cards whose framework part (if any) was saved.
        var targets: [String: String] = [:]
        var owners: [String: AppleWriteOperation] = [:]
        for note in split.notes where failedOriginals[note.operation] == nil {
            if let inner = split.innerPart[note.operation], !appliedInner.contains(inner) { continue }
            guard let card = note.cardID ?? note.recordID.flatMap({ innerResult.createdCardIDs[$0] }) else { continue }
            targets[card] = note.text
            owners[card] = note.operation
        }
        let noteFailures = writeNotes(targets, owners: owners, creates: split.creates)
        failedOriginals.merge(noteFailures) { first, _ in first }
        for operation in batch.operations {
            if let message = failedOriginals[operation] {
                result.failed.append(AppleWriteFailure(operation: operation, message: message))
            } else if let inner = split.innerPart[operation], !appliedInner.contains(inner) {
                result.failed.append(AppleWriteFailure(operation: operation, message: "not saved"))
            } else {
                result.applied.append(operation)
            }
        }
        return result
    }

    // MARK: - Notes I/O

    /// Reads notes (`nil`: every card); `nil` result when the read failed.
    private func read(cardIDs: [String]?) -> [String: String?]? {
        let bulk = cardIDs.map { $0.count > bulkThreshold } ?? true
        do {
            let notes = try provider.readAll(cardIDs: bulk ? nil : cardIDs)
            state.withLock { log in
                if bulk { log.bulkReads += 1 } else { log.cardReads += cardIDs?.count ?? 0 }
            }
            guard bulk, let cardIDs else { return notes }
            let wanted = Set(cardIDs)
            return notes.filter { wanted.contains($0.key) }
        } catch {
            state.withLock { log in
                log.readFailure = String(describing: error)
                log.readFailureIsPermission = (error as? NotesUnavailableError)?.permissionDenied ?? false
            }
            return nil
        }
    }

    /// Writes `targets` (card → text) after backing up their current notes.
    /// Returns the operations that failed as a whole (session failures).
    private func writeNotes(
        _ targets: [String: String], owners: [String: AppleWriteOperation], creates: Set<AppleWriteOperation>
    ) -> [AppleWriteOperation: String] {
        guard !targets.isEmpty else { return [:] }
        var failures: [AppleWriteOperation: String] = [:]
        func failAll(_ message: String) {
            for (card, operation) in owners where !creates.contains(operation) {
                failures[operation] = message
                logWarning("note for card \(card) not written: \(message)")
            }
            for (card, operation) in owners where creates.contains(operation) {
                logWarning("note for new card \(card) not written (\(message)); the next sync writes it")
            }
        }
        do {
            if let backup {
                let current = try provider.readAll(cardIDs: targets.keys.sorted())
                try backup(current)
            }
        } catch {
            failAll("notes backup failed: \(error)")
            return failures
        }
        let written: NotesWriteResult
        do {
            written = try provider.write(targets.mapValues { Optional($0) })
        } catch {
            failAll(String(describing: error))
            return failures
        }
        let date = now()
        for card in written.written {
            ownWrites.record(cardID: card, text: AppleNoteText.note(fromBody: targets[card]), at: date)
        }
        state.withLock { $0.written += written.written.count }
        for (card, message) in written.failed.sorted(by: { $0.key < $1.key }) {
            logWarning("note for card \(card) not kept: \(message)")
        }
        return failures
    }

    private func logWarning(_ text: String) { state.withLock { $0.writeWarnings.append(text) } }

    // MARK: - Overlay

    /// `contacts` with each card's note in `values.body` and the contact's
    /// body set by card precedence; contacts with a card missing from
    /// `notes` get `notesUnknown`.
    public static func overlay(_ contacts: [AppleContact], notes: [String: String?]) -> [AppleContact] {
        contacts.map { contact in
            var copy = contact
            guard contact.cards.allSatisfy({ notes.index(forKey: $0.id) != nil }) else {
                copy = withoutNotes(contact)
                copy.notesUnknown = true
                return copy
            }
            let body = { (card: AppleCard) in AppleNoteText.body(fromNote: notes[card.id].flatMap { $0 }) }
            for index in copy.cards.indices where copy.cards[index].values != nil {
                let note = body(copy.cards[index])
                copy.cards[index].values?.body = note
            }
            copy.contact.body = contact.cardsByPrecedence.lazy.compactMap(body).first
            copy.notesUnknown = nil
            return copy
        }
    }

    /// `contact` with no notes at all (notes not read).
    static func withoutNotes(_ contact: AppleContact) -> AppleContact {
        var copy = contact
        copy.contact.body = nil
        for index in copy.cards.indices { copy.cards[index].values?.body = nil }
        copy.notesUnknown = nil
        return copy
    }
}

/// A write batch with the `.note` edits taken out.
private struct SplitBatch {
    struct Note {
        var operation: AppleWriteOperation
        var cardID: String?
        var recordID: UUID?
        var text: String
    }

    /// Operations for the inner store.
    var inner: [AppleWriteOperation] = []
    /// Inner operation → the batch operation it came from.
    var original: [AppleWriteOperation: AppleWriteOperation] = [:]
    /// Batch operation → its inner part (absent: note only).
    var innerPart: [AppleWriteOperation: AppleWriteOperation] = [:]
    var notes: [Note] = []
    /// Create operations (their note never fails the create).
    var creates = Set<AppleWriteOperation>()

    init(_ batch: AppleWriteBatch) {
        for operation in batch.operations {
            switch operation {
            case .update(let cardID, let edits):
                let (rest, note) = Self.takeNote(edits)
                if let note { notes.append(Note(operation: operation, cardID: cardID, text: note)) }
                if !rest.isEmpty { add(.update(cardID: cardID, edits: rest), for: operation) }
            case .create(var new):
                let (rest, note) = Self.takeNote(new.edits)
                new.edits = rest
                if let note { notes.append(Note(operation: operation, recordID: new.recordID, text: note)) }
                creates.insert(operation)
                add(.create(new), for: operation)
            default:
                add(operation, for: operation)
            }
        }
    }

    private mutating func add(_ part: AppleWriteOperation, for operation: AppleWriteOperation) {
        inner.append(part)
        original[part] = operation
        innerPart[operation] = part
    }

    /// The edits without `.note`, and the last note text (`""` clears).
    private static func takeNote(_ edits: [CardEdit]) -> (rest: [CardEdit], note: String?) {
        var note: String?
        let rest = edits.filter { edit in
            guard case .note(let text) = edit else { return true }
            note = AppleNoteText.note(fromBody: text)
            return false
        }
        return (rest, note)
    }
}
