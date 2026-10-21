import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// Merge-table rows for the note body, image, title and the first bind
/// (architecture §7), run through the full engine.
@Suite("Merge table (architecture §7): body, image, title, no base")
struct MergeTableContentTests {
    @Test(
        "body: line-based diff3 merges separate edits; overlapping edits conflict with Keep Both",
        arguments: [false, true])
    func body(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported(
                [World.person("ann", "Ann", "One") { $0.body = "line one\nline two\nline three\n" }], notes: true)
            try world.editNote(MergeTableTests.path) { $0.body = "line ONE\nline two\nline three\n" }
            world.store.editCard("ann:icloud") { $0.body = "line one\nline two\nline THREE\n" }
            try MergeTableTests.syncToFixpoint(world)
            #expect(try world.note(MergeTableTests.path)?.body == "line ONE\nline two\nline THREE\n")
            #expect(ComparisonKeys.body(World.apple(world, "ann:icloud")?.body) == "line ONE\nline two\nline THREE")

            try world.editNote(MergeTableTests.path) { $0.body = "markdown version\n" }
            world.store.editCard("ann:icloud") { $0.body = "contacts version\n" }
            let run = try world.sync()
            let conflict = try #require(run.plan.conflicts.first)
            #expect(conflict.field == "body" && conflict.options.contains(.keepBoth))
            try world.decide(conflict.id, "both")
            try MergeTableTests.syncToFixpoint(world)
            #expect(try world.note(MergeTableTests.path)?.body == "markdown version\n\n---\n\ncontacts version\n")
        }
    }

    @Test("body is markdown-only without the notes entitlement", arguments: [false, true])
    func bodyWithoutNotes(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()], notes: false)
            try world.editNote(MergeTableTests.path) { $0.body = "private notes\n" }
            let run = try MergeTableTests.syncToFixpoint(world)
            #expect(run.plan.apple.isEmpty)
            let wroteNote = world.store.appliedOperations.contains { operation in
                guard case .update(_, let edits) = operation else { return false }
                return edits.contains { if case .note = $0 { true } else { false } }
            }
            #expect(!wroteNote)
        }
    }

    @Test(
        "image: by hash; Apple change pulled, markdown change pushed, both changed → conflict, thumbnail = unknown",
        arguments: [false, true])
    func image(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([
                World.person("ann", "Ann", "One") { _ in }
            ])
            world.store.editContact(withCard: "ann:icloud") { $0.imageData = Fixtures.jpegBytes }
            try MergeTableTests.syncToFixpoint(world)
            let id = try #require(try world.note(MergeTableTests.path)?.sync.id)
            let sidecar = "_images/\(id.uuidString.lowercased()).jpg"
            #expect(world.vault.data(sidecar) == Fixtures.jpegBytes)

            // Thumbnail only: never "removed".
            world.store.editContact(withCard: "ann:icloud") {
                $0.imageData = nil
                $0.imageUnavailable = true
            }
            let unknown = try MergeTableTests.syncToFixpoint(world)
            #expect(unknown.plan.isEmpty)
            #expect(try world.note(MergeTableTests.path)?.image != nil)

            // Markdown replaces the image file: pushed to Apple.
            world.store.editContact(withCard: "ann:icloud") {
                $0.imageData = Fixtures.jpegBytes
                $0.imageUnavailable = false
            }
            world.vault.seed(sidecar, Fixtures.pngBytes)
            try MergeTableTests.syncToFixpoint(world)
            #expect(world.store.contact(withCard: "ann:icloud")?.imageData == Fixtures.pngBytes)

            // Both change: conflict.
            world.vault.seed(sidecar, Data([0x47, 0x49, 0x46, 0x38, 0x01]))
            world.store.editContact(withCard: "ann:icloud") { $0.imageData = Fixtures.jpegBytes + Data([0x00]) }
            #expect(try world.sync().plan.conflicts.map(\.field) == ["image"])
        }
    }

    @Test(
        "title is markdown-owned: regenerated only while it equals the generated title; old title kept as alias",
        arguments: [false, true])
    func title(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let bob = World.person("bob", "Bob", "Two") {
                $0.relationships = [RelationshipRef(type: "friend", target: .name("Ann One"))]
            }
            let world = try World.exported([World.ann(), bob])
            world.store.editCard("ann:icloud") { $0.name.family = "Smith" }
            try MergeTableTests.syncToFixpoint(world)
            let note = try #require(try world.note(MergeTableTests.path))
            #expect(note.title == "Ann Smith" && note.name.family == "Smith")
            #expect(note.aliases.contains(.plain("Ann One")))
            #expect(try world.note("Inbox/Bob Two.md")?.relationships.first?.target == .wikilink("Ann Smith"))

            // A hand-edited title is never regenerated.
            try world.editNote(MergeTableTests.path) { $0.title = "Annie" }
            try MergeTableTests.syncToFixpoint(world)
            world.store.editCard("ann:icloud") { $0.name.family = "Jones" }
            try MergeTableTests.syncToFixpoint(world)
            #expect(try world.note(MergeTableTests.path)?.title == "Annie")
        }
    }

    @Test("no base (adoption): equal keys adopted, single-side additions unioned, scalar disagreements conflict")
    func noBase() throws {
        let note = """
            ---
            type: person
            title: Ann One
            first_name: Ann
            last_name: One
            job_title: Hand-written Title
            emails:
              - home: ann@home.example
              - work: ann@hand.example
            ---
            mine
            """
        let world = SyncHarness(
            store: FakeContactStore(contacts: [World.ann()], containers: Fixtures.containers, notesEntitled: false),
            vault: InMemoryVault(files: ["People/Ann One.md": note]))
        let run = try world.sync(SyncOptions(export: ExportOptions(autoAdopt: .always)))
        #expect(run.plan.markdown.adoptions.map(\.path) == ["People/Ann One.md"])
        #expect(run.plan.conflicts.map(\.field) == ["job_title"])
        let adopted = try #require(try world.note("People/Ann One.md"))
        #expect(adopted.emails.map(\.value) == ["ann@home.example", "ann@hand.example"])
        #expect(adopted.phones.map(\.value) == ["+1 415 555 0100"])
        #expect(adopted.body == "mine")
        let appleEmails = Set(World.apple(world, "ann:icloud")?.emails.map(\.value) ?? [])
        #expect(appleEmails.contains("ann@hand.example"))
        #expect(World.apple(world, "ann:icloud")?.jobTitle == "Engineer")
    }

    @Test("note images: unchanged files are not re-read; evicted (dataless) files are never read or compared")
    func imageReads() throws {
        let world = try World.exported([World.person("ann", "Ann", "One") { _ in }])
        world.store.editContact(withCard: "ann:icloud") { $0.imageData = Fixtures.jpegBytes }
        try MergeTableTests.syncToFixpoint(world)
        let id = try #require(try world.note(MergeTableTests.path)?.sync.id)
        let sidecar = "_images/\(id.uuidString.lowercased()).jpg"
        world.vault.resetReads()
        try world.sync()
        #expect(!world.vault.reads.contains(sidecar))
        world.vault.setDataless(sidecar)
        world.store.editContact(withCard: "ann:icloud") { $0.imageData = Fixtures.pngBytes }
        let run = try world.sync()
        #expect(!world.vault.reads.contains(sidecar))
        #expect(run.plan.markdown.images.isEmpty && run.plan.conflicts.isEmpty)
    }
}
