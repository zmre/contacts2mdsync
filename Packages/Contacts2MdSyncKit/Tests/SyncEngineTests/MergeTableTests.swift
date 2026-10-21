import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// One scenario per row of the architecture §7 merge table, run through
/// the full engine (plan → execute) against the fake store and vault.
@Suite("Merge table (architecture §7)")
struct MergeTableTests {
    static let path = "Inbox/Ann One.md"

    /// Runs a sync and asserts the following run is a no-op (fixpoint).
    @discardableResult
    static func syncToFixpoint(_ world: SyncHarness, _ options: SyncOptions = SyncOptions()) throws -> SyncHarness.Run {
        let run = try world.sync(options)
        let again = try world.plan(options).plan
        #expect(again.isEmpty, "not a fixpoint: apple \(again.apple) md \(again.markdown.updates.map(\.changedFields))")
        #expect(world.store.unifiedSaveCount == 0)
        return run
    }

    @Test("A = M by key: in sync, markdown display wins, no Apple write", arguments: [false, true])
    func equalByKey(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            world.store.editCard("ann:icloud") { $0.phones = [Labeled("mobile", "(415) 555-0100")] }
            try world.editNote(Self.path) { $0.emails = [Labeled("home", "Ann@Home.example")] }
            world.vault.resetWrites()
            let run = try Self.syncToFixpoint(world)
            #expect(run.plan.apple.isEmpty)
            #expect(run.plan.markdown.updates.isEmpty)
            let note = try #require(try world.note(Self.path))
            #expect(note.phones.map(\.value) == ["+1 415 555 0100"])
            #expect(note.emails.map(\.value) == ["Ann@Home.example"])
        }
    }

    @Test("only Apple changed: applied to markdown", arguments: [false, true])
    func onlyApple(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            world.store.editCard("ann:icloud") { $0.jobTitle = "Architect" }
            let run = try Self.syncToFixpoint(world)
            #expect(run.plan.apple.isEmpty)
            #expect(run.plan.markdown.updates.map(\.changedFields) == [["job_title"]])
            #expect(try world.note(Self.path)?.jobTitle == "Architect")
        }
    }

    @Test(
        "only markdown changed: applied to Apple (card-level, tagged with the device author)", arguments: [false, true])
    func onlyMarkdown(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) { $0.jobTitle = "Architect" }
            let run = try Self.syncToFixpoint(world)
            #expect(run.result?.apple.map(\.recordID).count == 1)
            #expect(World.apple(world, "ann:icloud")?.jobTitle == "Architect")
            #expect(world.store.appliedBatches.last?.author == "com.zmre.contacts2mdsync.device-a")
            #expect(run.result?.backup != nil)  // vCard backup before the Apple write
            guard case .update(let card, _)? = world.store.appliedOperations.last else {
                Issue.record("expected a card update")
                return
            }
            #expect(card == "ann:icloud")
        }
    }

    @Test("both changed, keys equal: adopted, no writes, base refreshed", arguments: [false, true])
    func bothSame(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) { $0.jobTitle = "Architect" }
            world.store.editCard("ann:icloud") { $0.jobTitle = "Architect" }
            let run = try Self.syncToFixpoint(world)
            #expect(run.plan.apple.isEmpty && run.plan.markdown.updates.isEmpty && run.plan.conflicts.isEmpty)
        }
    }

    @Test(
        "both changed, keys differ (scalar): conflict; other fields still sync; resolution applies once",
        arguments: [false, true])
    func scalarConflict(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) {
                $0.jobTitle = "Markdown Title"
                $0.department = "R&D"
            }
            world.store.editCard("ann:icloud") { $0.jobTitle = "Contacts Title" }
            let run = try world.sync()
            let conflict = try #require(run.plan.conflicts.first)
            #expect(conflict.field == "job_title")
            #expect(conflict.apple.value == "Contacts Title" && conflict.markdown.value == "Markdown Title")
            #expect(conflict.options == [.keepApple, .keepMarkdown])
            #expect(run.plan.needsReview)
            #expect(World.apple(world, "ann:icloud")?.department == "R&D")  // the record's other fields synced
            #expect(World.apple(world, "ann:icloud")?.jobTitle == "Contacts Title")
            #expect(try world.note(Self.path)?.jobTitle == "Markdown Title")
            // Same conflict, same id, on the next run.
            #expect(try world.plan().plan.conflicts.map(\.id) == [conflict.id])

            try world.decide(conflict.id, "markdown")
            let resolved = try Self.syncToFixpoint(world)
            #expect(resolved.plan.conflicts.isEmpty)
            #expect(World.apple(world, "ann:icloud")?.jobTitle == "Markdown Title")
        }
    }

    @Test(
        "a resolution made against old values is not applied: the conflict is raised again", arguments: [false, true])
    func staleResolution(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) { $0.jobTitle = "Markdown Title" }
            world.store.editCard("ann:icloud") { $0.jobTitle = "Contacts Title" }
            let conflict = try #require(try world.sync().plan.conflicts.first)
            try world.decide(conflict.id, "apple")
            world.store.editCard("ann:icloud") { $0.jobTitle = "Contacts Title 2" }
            let run = try world.sync()
            #expect(run.plan.conflicts.map(\.id) == [conflict.id])
            #expect(run.plan.conflicts.first?.apple.value == "Contacts Title 2")
            #expect(try world.note(Self.path)?.jobTitle == "Markdown Title")
        }
    }

    @Test(
        "element added on either side: union (markdown order kept, Apple additions appended)", arguments: [false, true])
    func additions(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) { $0.emails.insert(Labeled("work", "ann@work.example"), at: 0) }
            world.store.editCard("ann:icloud") { $0.emails.append(Labeled("other", "ann@other.example")) }
            try Self.syncToFixpoint(world)
            #expect(
                try world.note(Self.path)?.emails.map(\.value)
                    == ["ann@work.example", "ann@home.example", "ann@other.example"])
            #expect(
                Set(World.apple(world, "ann:icloud")?.emails.map(\.value) ?? [])
                    == ["ann@work.example", "ann@home.example", "ann@other.example"])
        }
    }

    @Test("element deleted on one side, untouched on the other: deleted", arguments: [false, true])
    func deletions(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([
                World.person("ann", "Ann", "One") { contact in
                    contact.emails = [Labeled("home", "a@one.example"), Labeled("work", "a@two.example")]
                    contact.phones = [Labeled("mobile", "+1 415 555 0100"), Labeled("work", "+1 415 555 0199")]
                }
            ])
            try world.editNote(Self.path) { $0.emails.removeLast() }
            world.store.editCard("ann:icloud") { $0.phones.removeLast() }
            try Self.syncToFixpoint(world)
            #expect(World.apple(world, "ann:icloud")?.emails.map(\.value) == ["a@one.example"])
            #expect(try world.note(Self.path)?.phones.map(\.value) == ["+1 415 555 0100"])
        }
    }

    @Test("element deleted on one side, edited on the other: conflict for that element", arguments: [false, true])
    func deleteVersusEdit(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) { $0.phones = [] }
            world.store.editCard("ann:icloud") { $0.phones = [Labeled("mobile", "+1 415 555 0142")] }
            let run = try world.sync()
            let conflict = try #require(run.plan.conflicts.first)
            #expect(conflict.field == "phones" && conflict.element == "mobile")
            #expect(conflict.markdown.value == nil && conflict.apple.value == "+1 415 555 0142")
            try world.decide(conflict.id, "apple")
            try Self.syncToFixpoint(world)
            #expect(try world.note(Self.path)?.phones.map(\.value) == ["+1 415 555 0142"])
        }
    }

    @Test(
        "element edited on one side: edited in place on the other (labeled-value identity kept)",
        arguments: [false, true])
    func edit(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) { $0.phones = [Labeled("mobile", "+1 415 555 0177")] }
            try Self.syncToFixpoint(world)
            #expect(World.apple(world, "ann:icloud")?.phones == [Labeled("mobile", "+1 415 555 0177")])
            guard case .update(_, let edits)? = world.store.appliedOperations.last,
                case .list(.phones, let elements)? = edits.first
            else {
                Issue.record("expected a phones edit")
                return
            }
            #expect(elements.first?.existing == .text("+1 415 555 0100"))  // replaces, not adds
        }
    }

    @Test(
        "label changed differently on both sides: conflict; label changed on one side: applied",
        arguments: [false, true])
    func labels(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote(Self.path) { $0.emails = [Labeled("work", "ann@home.example")] }
            try Self.syncToFixpoint(world)
            #expect(World.apple(world, "ann:icloud")?.emails == [Labeled("work", "ann@home.example")])

            try world.editNote(Self.path) { $0.emails = [Labeled("school", "ann@home.example")] }
            world.store.editCard("ann:icloud") { $0.emails = [Labeled("other", "ann@home.example")] }
            let run = try world.sync()
            let conflict = try #require(run.plan.conflicts.first)
            #expect(conflict.field == "emails")
            #expect(conflict.apple.label == "other" && conflict.markdown.label == "school")
            try world.decide(conflict.id, "markdown")
            try Self.syncToFixpoint(world)
            #expect(World.apple(world, "ann:icloud")?.emails == [Labeled("school", "ann@home.example")])
        }
    }

    @Test(
        "managed tags: three-way set merge with Apple groups, never a conflict; unmanaged tags never touch Apple",
        arguments: [false, true])
    func tags(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([
                World.person("ann", "Ann", "One", groups: [Fixtures.family, Fixtures.work])
            ])
            try world.editNote(Self.path) { note in
                note.tags = ["work", "close_friends", "hiking"]  // -family +close_friends, hiking unmanaged
            }
            world.store.editContact(withCard: "ann:icloud") { $0.groupIDs.removeAll { $0 == Fixtures.work.id } }
            let run = try Self.syncToFixpoint(world)
            #expect(run.plan.conflicts.isEmpty)
            #expect(try world.note(Self.path)?.tags == ["close_friends", "hiking"])
            #expect(world.store.contact(withCard: "ann:icloud")?.groupIDs == [Fixtures.closeFriends.id])
        }
    }

    @Test(
        "relationships: keyed by type and target record; edge attributes stay markdown-only", arguments: [false, true])
    func relationships(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([
                World.person("ann", "Ann", "One") {
                    $0.relationships = [RelationshipRef(type: "spouse", target: .name("Bob Two"))]
                },
                World.person("bob", "Bob", "Two"),
            ])
            #expect(try world.note(Self.path)?.relationships.first?.target == .wikilink("Bob Two"))
            try world.editNote(Self.path) { note in
                note.relationships[0].attributes = [YAMLField(key: "married", value: .string("1999-06-01"))]
                note.relationships.append(RelationshipRef(type: "parent", label: "mother", target: .name("Cara Three")))
            }
            try Self.syncToFixpoint(world)
            let apple = try #require(World.apple(world, "ann:icloud"))
            #expect(apple.relationships.map(\.type).sorted() == ["parent", "spouse"])
            #expect(apple.relationships.contains { $0.target == .name("Cara Three") && $0.label == "mother" })
            let note = try #require(try world.note(Self.path))
            #expect(note.relationships.first?.attributes.first?.key == "married")

            // A link to a note whose title is not the contact's name: Apple gets the contact's name.
            try world.editNote("Inbox/Bob Two.md") { $0.title = "Robert" }
            try world.editNote(Self.path) { note in
                note.relationships.append(RelationshipRef(type: "friend", target: .wikilink("Robert")))
            }
            try Self.syncToFixpoint(world)
            let relations = try #require(World.apple(world, "ann:icloud")?.relationships)
            #expect(relations.contains { $0.type == "friend" && $0.target == .name("Bob Two") })
        }
    }
}
