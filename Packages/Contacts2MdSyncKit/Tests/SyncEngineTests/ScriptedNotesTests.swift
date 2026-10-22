import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// Worlds for notes through (fake) Contacts.app scripting: a store without
/// the notes entitlement, exported and synced once with notes off, then
/// `notes_sync: on` (architecture §8).
enum NotesWorld {
    static func make(
        _ contacts: [AppleContact], appleWrites: Bool = true, enable: Bool = true
    ) throws -> (SyncHarness, FakeNotesProvider) {
        let world = SyncHarness(contacts: contacts, notesEntitled: false, appleWrites: appleWrites)
        try world.export()
        try world.sync()
        let notes = FakeNotesProvider(store: world.store)
        if enable { world.enableScriptedNotes(notes) }
        return (world, notes)
    }

    /// The note of one card as Contacts.app shows it.
    static func note(_ world: SyncHarness, _ cardID: String) -> String? {
        world.store.scriptedNotes()[cardID].flatMap { $0 }
    }

    /// The markdown body of a note.
    static func body(_ world: SyncHarness, _ path: String) throws -> String? {
        try world.note(path)?.body
    }

    /// Sets a markdown body.
    static func setBody(_ world: SyncHarness, _ path: String, _ text: String?) throws {
        try world.editNote(path) { $0.body = text }
    }

    static func person(
        _ id: String, _ given: String, note: String? = nil, accounts: [AccountKind] = [.iCloud]
    )
        -> AppleContact
    {
        World.person(id, given, "Notes", accounts: accounts) { contact in
            contact.emails = [Labeled("home", "\(id)@home.example")]
            contact.body = note
        }
    }
}

@Suite("Notes through Contacts.app scripting: enablement migration")
struct NotesEnablementTests {
    /// ann: note only in Contacts; bob: body only in markdown; cat: both,
    /// equal (markdown with a blank line after the frontmatter); dan: both,
    /// different; eve: neither.
    static func matrix(appleWrites: Bool = true) throws -> (SyncHarness, FakeNotesProvider) {
        let (world, notes) = try NotesWorld.make(
            [
                NotesWorld.person("ann", "Ann", note: "Met at a conference."),
                NotesWorld.person("bob", "Bob"),
                NotesWorld.person("cat", "Cat", note: "Same text\nline two"),
                NotesWorld.person("dan", "Dan", note: "Apple version"),
                NotesWorld.person("eve", "Eve"),
            ], appleWrites: appleWrites, enable: false)
        try NotesWorld.setBody(world, "Inbox/Bob Notes.md", "# Hand-written\n\nLong private notes.\n")
        try NotesWorld.setBody(world, "Inbox/Cat Notes.md", "\nSame text\r\nline two  \n")
        try NotesWorld.setBody(world, "Inbox/Dan Notes.md", "Markdown version\n")
        world.enableScriptedNotes(notes)
        return (world, notes)
    }

    @Test("bodies were markdown-only before notes were on")
    func markdownOnlyBefore() throws {
        let (world, _) = try Self.matrix()
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == nil)
        #expect(NotesWorld.note(world, "bob:icloud") == nil)
    }

    @Test("plan previews the migration per record and writes nothing")
    func planPreview() throws {
        let (world, notes) = try Self.matrix()
        world.vault.resetWrites()
        let plan = try world.plan().plan
        #expect(plan.notes.source == .scripting && plan.notes.freshStart)
        let baseline = plan.notesBaseline
        #expect(baseline.toMarkdown.map(\.title) == ["Ann Notes"])
        #expect(baseline.toContacts.map(\.title) == ["Bob Notes"])
        #expect(baseline.toContacts.first?.characters == "# Hand-written\n\nLong private notes.".count)
        #expect(baseline.toContacts.first?.lines == 3)
        #expect(baseline.adopted == 1)
        #expect(baseline.conflicts.map(\.title) == ["Dan Notes"])
        let size = "# Hand-written\n\nLong private notes.".count
        #expect(baseline.summary.contains("1 into Contacts (largest \(size) chars: Bob Notes)"))
        #expect(plan.apple.map(\.title) == ["Bob Notes"])
        #expect(plan.apple.first?.fields == ["body"])
        #expect(world.vault.writes.filter { !$0.hasPrefix(".") }.isEmpty)
        #expect(notes.writes.isEmpty)
    }

    @Test("sync applies the matrix; the next run is a no-op and no longer a fresh start")
    func syncMatrix() throws {
        let (world, _) = try Self.matrix()
        let run = try world.sync()
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "Met at a conference.\n")
        #expect(NotesWorld.note(world, "bob:icloud") == "# Hand-written\n\nLong private notes.")
        #expect(try NotesWorld.body(world, "Inbox/Cat Notes.md") == "\nSame text\r\nline two  \n")  // untouched
        #expect(NotesWorld.note(world, "cat:icloud") == "Same text\nline two")
        #expect(try NotesWorld.body(world, "Inbox/Dan Notes.md") == "Markdown version\n")
        #expect(NotesWorld.note(world, "dan:icloud") == "Apple version")
        #expect(run.plan.conflicts.map(\.field) == ["body"])
        #expect(run.result?.notesSynced == true)
        #expect(NotesSyncState.lastSource(in: world.state) == .scripting)
        let second = try world.sync()
        #expect(!second.plan.notes.freshStart)
        #expect(second.plan.apple.isEmpty && second.plan.markdown.updates.isEmpty)
        #expect(second.plan.conflicts.map(\.field) == ["body"])  // still open, nothing written
    }

    @Test("Keep Both writes markdown, a rule, then the Contacts note, to both sides")
    func keepBoth() throws {
        let (world, _) = try Self.matrix()
        let run = try world.sync()
        let conflict = try #require(run.plan.conflicts.first)
        #expect(conflict.options.contains(.keepBoth))
        try world.decide(conflict.id, "both")
        try world.sync()
        let merged = "Markdown version\n\n---\n\nApple version"
        #expect(try NotesWorld.body(world, "Inbox/Dan Notes.md") == merged + "\n")
        #expect(NotesWorld.note(world, "dan:icloud") == merged)
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("Keep Contacts / Keep Markdown resolve the body conflict", arguments: ["apple", "markdown"])
    func keepOneSide(choice: String) throws {
        let (world, _) = try Self.matrix()
        let conflict = try #require(try world.sync().plan.conflicts.first)
        try world.decide(conflict.id, choice)
        try world.sync()
        let expected = choice == "apple" ? "Apple version" : "Markdown version"
        #expect(try NotesWorld.body(world, "Inbox/Dan Notes.md") == expected + "\n")
        #expect(NotesWorld.note(world, "dan:icloud") == expected)
    }

    @Test("pushes to Contacts are held while apple_writes is disabled, and stay pending")
    func heldWithoutAppleWrites() throws {
        let (world, notes) = try Self.matrix(appleWrites: false)
        let run = try world.sync()
        #expect(run.plan.appleHold == .appleWritesDisabled)
        #expect(run.plan.notesBaseline.toContacts.map(\.title) == ["Bob Notes"])
        #expect(notes.writes.isEmpty)
        #expect(NotesWorld.note(world, "bob:icloud") == nil)
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "Met at a conference.\n")  // markdown side runs
        let again = try world.sync()
        #expect(!again.plan.notes.freshStart)
        #expect(again.plan.notesBaseline.toContacts.map(\.title) == ["Bob Notes"])  // no base yet: still shown
    }

    @Test("pushes count toward the blast radius")
    func blastRadius() throws {
        let (world, notes) = try Self.matrix()
        let run = try world.sync(SyncOptions(maxAppleChanges: 0))
        guard case .blastRadius(let count, _)? = run.plan.appleHold else {
            Issue.record("expected the blast-radius hold, got \(String(describing: run.plan.appleHold))")
            return
        }
        #expect(count == 1)
        #expect(notes.writes.isEmpty)
    }

    @Test("turning notes off and on again starts without a base (conflict, not a silent push)")
    func offThenOn() throws {
        let (world, notes) = try NotesWorld.make([NotesWorld.person("ann", "Ann", note: "Shared")])
        try world.sync()
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "Shared\n")
        world.disableScriptedNotes()
        try world.sync()
        #expect(NotesSyncState.lastSource(in: world.state) == nil)
        // While off, both sides change.
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", "Edited in markdown while notes were off\n")
        try world.store.scriptedSetNote(cardID: "ann:icloud", text: "Edited in Contacts")
        world.enableScriptedNotes(notes)
        let run = try world.sync()
        #expect(run.plan.notes.freshStart)
        #expect(run.plan.conflicts.map(\.field) == ["body"])
        #expect(NotesWorld.note(world, "ann:icloud") == "Edited in Contacts")
    }
}

@Suite("Notes through Contacts.app scripting: sync")
struct ScriptedNotesSyncTests {
    static func synced(_ contacts: [AppleContact]) throws -> (SyncHarness, FakeNotesProvider) {
        let (world, notes) = try NotesWorld.make(contacts)
        try world.sync()
        return (world, notes)
    }

    @Test("edits flow both ways card by card; fixpoint after each")
    func twoWay() throws {
        let (world, _) = try Self.synced([NotesWorld.person("ann", "Ann", note: "One")])
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", "One\nTwo from markdown\n")
        var run = try world.sync()
        #expect(run.result?.apple.map(\.fields) == [["body"]])
        #expect(NotesWorld.note(world, "ann:icloud") == "One\nTwo from markdown")
        #expect(try world.sync().plan.isEmpty)
        try world.store.scriptedSetNote(cardID: "ann:icloud", text: "One\nTwo from markdown\nThree from Contacts")
        run = try world.sync()
        #expect(run.result?.markdown.updated.map(\.changedFields) == [["body"]])
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "One\nTwo from markdown\nThree from Contacts\n")
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("non-overlapping edits on both sides merge line by line (diff3)")
    func diff3() throws {
        let start = (1...6).map { "line \($0)" }.joined(separator: "\n")
        let (world, _) = try Self.synced([NotesWorld.person("ann", "Ann", note: start)])
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", start.replacingOccurrences(of: "line 1", with: "LINE ONE"))
        try world.store.scriptedSetNote(
            cardID: "ann:icloud", text: start.replacingOccurrences(of: "line 6", with: "LINE SIX"))
        let run = try world.sync()
        #expect(run.plan.conflicts.isEmpty)
        let merged = start.replacingOccurrences(of: "line 1", with: "LINE ONE")
            .replacingOccurrences(of: "line 6", with: "LINE SIX")
        #expect(NotesWorld.note(world, "ann:icloud") == merged)
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == merged + "\n")
    }

    @Test("linked cards: the precedence card's note is the record's; another card's note never ping-pongs")
    func linkedDivergence() throws {
        let liz = NotesWorld.person("liz", "Liz", accounts: [.iCloud, .google])
        let world = SyncHarness(contacts: [liz], notesEntitled: false, appleWrites: true)
        try world.store.scriptedSetNote(cardID: "liz:icloud", text: "iCloud note")
        try world.store.scriptedSetNote(cardID: "liz:google", text: "Google note")
        try world.export()
        try world.sync()
        let notes = FakeNotesProvider(store: world.store)
        world.enableScriptedNotes(notes)
        try world.sync()
        #expect(try NotesWorld.body(world, "Inbox/Liz Notes.md") == "iCloud note\n")
        #expect(NotesWorld.note(world, "liz:google") == "Google note")  // left alone
        #expect(notes.writes.isEmpty)
        // The other card changes: not a change of the record's note.
        try world.store.scriptedSetNote(cardID: "liz:google", text: "Google edited")
        var run = try world.sync()
        #expect(run.plan.isEmpty)
        run = try world.sync(mode: .full)
        #expect(run.plan.isEmpty)
        // A markdown edit is written through to every writable card.
        try NotesWorld.setBody(world, "Inbox/Liz Notes.md", "Agreed note\n")
        run = try world.sync()
        let cards = run.result?.apple.flatMap(\.operations).compactMap(\.cardID).sorted()
        #expect(cards == ["liz:google", "liz:icloud"])
        #expect(NotesWorld.note(world, "liz:icloud") == "Agreed note")
        #expect(NotesWorld.note(world, "liz:google") == "Agreed note")
        #expect(try world.sync().plan.isEmpty)
        #expect(world.store.unifiedSaveCount == 0)
    }

    @Test("an empty iCloud note: the first non-empty card in precedence order counts")
    func precedenceSkipsEmpty() throws {
        let liz = NotesWorld.person("liz", "Liz", accounts: [.iCloud, .google])
        let world = SyncHarness(contacts: [liz], notesEntitled: false, appleWrites: true)
        try world.store.scriptedSetNote(cardID: "liz:google", text: "Only on Google")
        try world.export()
        try world.sync()
        world.enableScriptedNotes(FakeNotesProvider(store: world.store))
        try world.sync()
        #expect(try NotesWorld.body(world, "Inbox/Liz Notes.md") == "Only on Google\n")
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("a card that does not keep its note is marked unapplyable and not retried")
    func refusedWrite() throws {
        let (world, notes) = try Self.synced([NotesWorld.person("ann", "Ann", note: "One")])
        notes.refuseWrites(["ann:icloud"])
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", "Changed\n")
        let run = try world.sync()
        #expect(run.result?.newUnapplyable.map(\.field) == ["body"])
        #expect(world.bridge?.log.writeWarnings.isEmpty == false)
        let writes = notes.writes.count
        let again = try world.sync()
        #expect(again.plan.apple.isEmpty)
        #expect(notes.writes.count == writes)
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "Changed\n")  // never reverted
    }

    @Test("a failed write session is reported as failed and retried next run")
    func failedSession() throws {
        let (world, notes) = try Self.synced([NotesWorld.person("ann", "Ann", note: "One")])
        notes.setFailWrites(true)
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", "Changed\n")
        let run = try world.sync()
        #expect(run.result?.appleFailures.isEmpty == false)
        #expect(run.result?.newUnapplyable.isEmpty == true)
        notes.setFailWrites(false)
        try world.sync()
        #expect(NotesWorld.note(world, "ann:icloud") == "Changed")
    }

    @Test("a card scripting cannot see: the body is unknown, never treated as empty")
    func unknownCard() throws {
        let (world, notes) = try Self.synced([NotesWorld.person("ann", "Ann", note: "Keep me")])
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "Keep me\n")
        notes.hide(["ann:icloud"])
        let run = try world.sync(mode: .full)
        #expect(run.plan.isEmpty)
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == "Keep me\n")
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", "Edited while hidden\n")
        #expect(try world.sync(mode: .full).plan.apple.isEmpty)
        notes.hide([])
        let visible = FakeNotesProvider(store: world.store)
        world.enableScriptedNotes(visible)
        try world.sync(mode: .full)
        #expect(NotesWorld.note(world, "ann:icloud") == "Edited while hidden")
    }

    @Test("Contacts converting line endings is not a change and not refused")
    func classicLineEndings() throws {
        let (world, notes) = try Self.synced([NotesWorld.person("ann", "Ann", note: "One")])
        notes.setClassicLineEndings(true)
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", "One\nTwo\nThree\n")
        let run = try world.sync()
        #expect(run.result?.newUnapplyable.isEmpty == true)
        #expect(NotesWorld.note(world, "ann:icloud") == "One\rTwo\rThree")
        #expect(try world.sync(mode: .full).plan.isEmpty)
    }

    @Test("a 49,152-character note with CRLF line endings round-trips without truncation")
    func longNote() throws {
        let line = String(repeating: "x", count: 62)
        let lines = (0..<768).map { "\($0 % 10)" + line + "." }
        let text = lines.joined(separator: "\r\n")
        #expect(text.count >= 49_152)
        let (world, _) = try Self.synced([NotesWorld.person("ann", "Ann", note: text)])
        let body = try #require(try NotesWorld.body(world, "Inbox/Ann Notes.md"))
        #expect(body == lines.joined(separator: "\n") + "\n")
        #expect(try world.sync(mode: .full).plan.isEmpty)
        // Edits far apart on both sides merge.
        var markdown = lines
        markdown[700] = "edited in markdown"
        try NotesWorld.setBody(world, "Inbox/Ann Notes.md", markdown.joined(separator: "\n") + "\n")
        var apple = lines
        apple[3] = "edited in Contacts"
        try world.store.scriptedSetNote(cardID: "ann:icloud", text: apple.joined(separator: "\r\n"))
        let run = try world.sync()
        #expect(run.plan.conflicts.isEmpty)
        var merged = lines
        merged[3] = "edited in Contacts"
        merged[700] = "edited in markdown"
        #expect(NotesWorld.note(world, "ann:icloud") == merged.joined(separator: "\n"))
        #expect(try NotesWorld.body(world, "Inbox/Ann Notes.md") == merged.joined(separator: "\n") + "\n")
    }
}
