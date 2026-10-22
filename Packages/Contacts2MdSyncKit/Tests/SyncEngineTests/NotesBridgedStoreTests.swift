import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

@Suite("Notes through Contacts.app scripting: permission and reads")
struct ScriptedNotesPermissionTests {
    @Test(
        "not granted: notes skipped with a warning, no change on either side, base kept",
        arguments: [
            NotesPermission.denied, .notDetermined,
        ])
    func skippedWithoutPermission(permission: NotesPermission) throws {
        let (world, notes) = try NotesWorld.make([NotesWorld.person("ann", "Ann", note: "One")])
        try world.sync()
        notes.setPermission(permission)
        try world.store.scriptedSetNote(cardID: "ann:icloud", text: "Changed in Contacts")
        let run = try world.sync()
        #expect(run.plan.notes.skipped == "Automation permission for Contacts not granted; notes skipped")
        #expect(run.plan.notes.source == nil)
        #expect(run.plan.isEmpty)
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "One\n")
        #expect(NotesSyncState.lastSource(in: world.state) == .scripting)  // not "off"
        #expect(notes.permissionRequests == 0)  // never prompts
        notes.setPermission(.granted)
        let back = try world.sync()
        #expect(!back.plan.notes.freshStart)
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "Changed in Contacts\n")  // a clean pull
    }

    @Test("a failed read skips notes for the run instead of reading them as empty")
    func failedRead() throws {
        let (world, notes) = try NotesWorld.make([NotesWorld.person("ann", "Ann", note: "One")])
        try world.sync()
        notes.setFailReads(true)
        let run = try world.sync(mode: .full)
        #expect(run.plan.notes.skipped != nil)
        #expect(run.plan.isEmpty)
        #expect(world.bridge?.log.readFailure != nil)
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "One\n")
    }

    @Test("full runs read every note in one bulk call")
    func bulkOnFull() throws {
        let (world, notes) = try NotesWorld.make([
            NotesWorld.person("ann", "Ann", note: "A"), NotesWorld.person("bob", "Bob", note: "B"),
        ])
        try world.sync(mode: .full)
        #expect(notes.bulkReads == 1)
        #expect(notes.cardReads.isEmpty)
    }

    @Test("incremental runs re-read only the notes of touched cards")
    func incrementalReRead() throws {
        let (world, notes) = try NotesWorld.make([
            NotesWorld.person("ann", "Ann", note: "A"), NotesWorld.person("bob", "Bob", note: "B"),
            NotesWorld.person("cat", "Cat", note: "C"),
        ])
        try world.sync()  // full: notes turned on
        let bulk = notes.bulkReads
        try world.store.scriptedSetNote(cardID: "bob:icloud", text: "B changed")
        let run = try world.sync()
        #expect(run.apple?.isComplete == false)
        #expect(notes.bulkReads == bulk)
        #expect(notes.cardReads.last == ["bob:icloud"])
        #expect(try NotesWorld.body(world, "Inbox/Bob Notes.md") == "B changed\n")
        // A markdown edit re-reads that record's cards too.
        try NotesWorld.setBody(world, "Inbox/Cat Notes.md", "C from markdown\n")
        try world.sync()
        #expect(notes.cardReads.contains(["cat:icloud"]))
        #expect(NotesWorld.note(world, "cat:icloud") == "C from markdown")
    }
}

@Suite("NotesBridgedStore")
struct NotesBridgedStoreTests {
    /// A bridge over a fake store without the notes entitlement.
    struct Bridged {
        var bridge: NotesBridgedStore
        var notes: FakeNotesProvider
        var store: FakeContactStore
    }

    static func bridge(_ contacts: [AppleContact], clock: TestClock = TestClock(start: SyncHarness.start)) -> Bridged {
        let store = FakeContactStore(contacts: contacts, notesEntitled: false)
        let notes = FakeNotesProvider(store: store)
        return Bridged(
            bridge: NotesBridgedStore(inner: store, provider: notes, now: { clock.now }), notes: notes, store: store)
    }

    @Test("snapshot overlays card notes by precedence and claims notes")
    func overlay() throws {
        let world = Self.bridge([NotesWorld.person("liz", "Liz", accounts: [.iCloud, .google])])
        let bridge = world.bridge
        let store = world.store
        try store.scriptedSetNote(cardID: "liz:google", text: "g\r\nline")
        let snapshot = try bridge.snapshot()
        #expect(snapshot.notesAvailable)
        #expect(try bridge.capabilities.notesAvailable)
        let liz = try #require(snapshot.contacts.first)
        #expect(liz.contact.body == "g\nline\n")
        #expect(liz.cards.first { $0.id == "liz:google" }?.values?.body == "g\nline\n")
        #expect(liz.notesUnknown == nil)
    }

    @Test("note edits go to the provider; other edits to the store; an echo of our write is recognized, still read")
    func applyAndOwnWrites() throws {
        let clock = TestClock(start: SyncHarness.start)
        let world = Self.bridge([NotesWorld.person("ann", "Ann", note: "Old")], clock: clock)
        let bridge = world.bridge
        let notes = world.notes
        let store = world.store
        let operation = AppleWriteOperation.update(
            cardID: "ann:icloud", edits: [.note("\nNew\nnote  \n"), .scalar(.jobTitle, "CTO")])
        let result = try bridge.apply(AppleWriteBatch(operations: [operation]), author: "test")
        #expect(result.applied == [operation] && result.failed.isEmpty)
        #expect(notes.writes == [["ann:icloud": "New\nnote"]])
        #expect(store.values(ofCard: "ann:icloud")?.jobTitle == "CTO")
        #expect(bridge.ownWrites.count == 1)
        let reads = notes.cardReads.count
        let first = try bridge.refetch(cardIDs: ["ann:icloud"], siblingHints: [])
        #expect(first.contacts.first?.contact.body == "New\nnote\n")
        #expect(notes.cardReads.count == reads + 1)  // always read: never trusted instead of a read
        #expect(bridge.log.ownWritesSeen == 1)
        _ = try bridge.refetch(cardIDs: ["ann:icloud"], siblingHints: [])
        #expect(bridge.log.ownWritesSeen == 1)  // recognized once only
    }

    @Test("a user edit right after our write is read, not mistaken for our echo")
    func userEditAfterOwnWrite() throws {
        let world = Self.bridge([NotesWorld.person("ann", "Ann", note: "Old")])
        let bridge = world.bridge
        let store = world.store
        _ = try bridge.apply(
            AppleWriteBatch(operations: [.update(cardID: "ann:icloud", edits: [.note("Ours")])]), author: "test")
        try store.scriptedSetNote(cardID: "ann:icloud", text: "The user's edit")
        let refetched = try bridge.refetch(cardIDs: ["ann:icloud"], siblingHints: [])
        #expect(refetched.contacts.first?.contact.body == "The user's edit\n")
        #expect(bridge.log.ownWritesSeen == 0)
    }

    @Test("own writes expire after their TTL")
    func ownWritesExpire() throws {
        let clock = TestClock(start: SyncHarness.start)
        let world = Self.bridge([NotesWorld.person("ann", "Ann")], clock: clock)
        let bridge = world.bridge
        _ = try bridge.apply(
            AppleWriteBatch(operations: [.update(cardID: "ann:icloud", edits: [.note("X")])]), author: "test")
        clock.advance(31)
        _ = try bridge.refetch(cardIDs: ["ann:icloud"], siblingHints: [])
        #expect(bridge.log.ownWritesSeen == 0)
    }

    @Test("our note writes are older than the post-write token: the next incremental run sees no change")
    func ownWritesNotReportedBack() throws {
        let (world, notes) = try NotesWorld.make([NotesWorld.person("ann", "Ann", note: "One")])
        try world.sync()
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", "Two\n")
        try world.sync()
        let reads = (notes.bulkReads, notes.cardReads.count)
        let run = try world.sync()
        #expect(run.apple?.isComplete == false)
        #expect(run.plan.isEmpty)
        #expect(notes.bulkReads == reads.0 && notes.cardReads.count == reads.1)  // Contacts.app not asked at all
    }

    @Test("the notes about to be overwritten are backed up first; a failed backup writes nothing")
    func backup() throws {
        let store = FakeContactStore(contacts: [NotesWorld.person("ann", "Ann", note: "Old")], notesEntitled: false)
        let notes = FakeNotesProvider(store: store)
        let saved = SavedNotes()
        let bridge = NotesBridgedStore(inner: store, provider: notes, backup: { saved.add($0) })
        let operation = AppleWriteOperation.update(cardID: "ann:icloud", edits: [.note("New")])
        _ = try bridge.apply(AppleWriteBatch(operations: [operation]), author: "test")
        #expect(saved.all == [["ann:icloud": "Old"]])
        let failing = NotesBridgedStore(
            inner: store, provider: notes, backup: { _ in throw HarnessFailure("disk full") })
        let result = try failing.apply(
            AppleWriteBatch(operations: [.update(cardID: "ann:icloud", edits: [.note("Newer")])]), author: "test")
        #expect(result.failed.count == 1)
        #expect(store.scriptedNotes()["ann:icloud"] == .some("New"))
    }

    @Test("a create's note is written to the new card; its failure never fails the create")
    func createWithNote() throws {
        let world = Self.bridge([])
        let bridge = world.bridge
        let notes = world.notes
        let store = world.store
        let new = NewAppleContact(
            recordID: UUID(), containerID: "icloud", kind: .person, edits: [.note("Hello"), .scalar(.givenName, "Ny")])
        let result = try bridge.apply(AppleWriteBatch(operations: [.create(new)]), author: "test")
        #expect(result.failed.isEmpty)
        let card = try #require(result.createdCardIDs[new.recordID])
        #expect(store.scriptedNotes()[card] == .some("Hello"))
        notes.setFailWrites(true)
        let other = NewAppleContact(recordID: UUID(), containerID: "icloud", kind: .person, edits: [.note("Hi")])
        let second = try bridge.apply(AppleWriteBatch(operations: [.create(other)]), author: "test")
        #expect(second.failed.isEmpty && second.applied.count == 1)
        #expect(bridge.log.writeWarnings.contains { $0.contains("the next sync writes it") })
    }

    @Test("a card missing from the read marks its contact's notes unknown")
    func missingCard() throws {
        let world = Self.bridge([NotesWorld.person("liz", "Liz", note: "x", accounts: [.iCloud, .google])])
        let bridge = world.bridge
        let notes = world.notes
        notes.hide(["liz:google"])
        let liz = try #require(try bridge.snapshot().contacts.first)
        #expect(liz.notesUnknown == true)
        #expect(liz.contact.body == nil)
    }
}

/// Collects backups (thread-safe for the `@Sendable` closure).
final class SavedNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [[String: String?]] = []

    func add(_ notes: [String: String?]) {
        lock.withLock { saved.append(notes) }
    }

    var all: [[String: String?]] { lock.withLock { saved } }
}
