import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Relation names after a rename (architecture §8): `CNContactRelation` is
/// name-only, so other contacts' cards that still call a renamed record by
/// its old name are updated, and markdown `to:` links follow a regenerated
/// title.
@Suite("Relations follow renames")
struct RelationRenameTests {
    static let bobPath = "Inbox/Bob Two.md"

    /// Bob's card relations (name per relation).
    static func bobRelations(_ world: SyncHarness) -> [String] {
        (World.apple(world, "bob:icloud")?.relationships ?? []).compactMap {
            if case .name(let name)? = $0.target { return name }
            return nil
        }
    }

    static func bob(
        _ relations: [RelationshipRef] = [RelationshipRef(type: "friend", target: .name("Ann One"))]
    )
        -> AppleContact
    {
        World.person("bob", "Bob", "Two") { $0.relationships = relations }
    }

    /// Syncs until a plan is empty (at most `limit` runs); returns the runs.
    @discardableResult
    static func settle(_ world: SyncHarness, limit: Int = 4) throws -> [SyncHarness.Run] {
        var runs: [SyncHarness.Run] = []
        for _ in 0..<limit {
            let run = try world.sync()
            runs.append(run)
            if run.plan.isEmpty { return runs }
        }
        Issue.record("no fixpoint after \(limit) runs")
        return runs
    }

    @Test(
        "Apple rename: other cards' relations take the new name; to: links follow the title", arguments: [false, true])
    func appleRename(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann(), Self.bob()])
            #expect(try world.note(Self.bobPath)?.relationships.first?.target == .wikilink("Ann One"))
            world.store.editCard("ann:icloud") { $0.name.family = "Smith" }
            let first = try world.sync()
            let bobChange = first.result?.apple.first { $0.title == "Bob Two" }
            #expect(bobChange?.fields == ["relationships"])
            #expect(Self.bobRelations(world) == ["Ann Smith"])
            #expect(try world.note(Self.bobPath)?.relationships.first?.target == .wikilink("Ann Smith"))
            // Idempotent: no churn on either side afterwards.
            let again = try world.plan().plan
            #expect(again.isEmpty, "\(again.apple) \(again.markdown.updates.map(\.changedFields))")
            #expect(world.store.unifiedSaveCount == 0)
        }
    }

    @Test("A hand-edited title: the link stays, the Apple relation still follows the Apple name")
    func customTitle() throws {
        let world = try World.exported([World.ann(), Self.bob()])
        try world.editNote(MergeTableTests.path) { $0.title = "Annie" }
        try Self.settle(world)
        world.store.editCard("ann:icloud") { $0.name.family = "Smith" }
        try Self.settle(world)
        #expect(Self.bobRelations(world) == ["Ann Smith"])
        // Still one relationship in Bob's note, pointing at Ann's record (no plain-name churn).
        let relations = try #require(try world.note(Self.bobPath)?.relationships)
        #expect(relations.count == 1)
        #expect(relations.first?.target == .wikilink("Ann One"))
        #expect(try world.plan().plan.isEmpty)
    }

    @Test("Held while Apple writes are off; applied once they are on (former names persist)")
    func heldThenApplied() throws {
        let world = try World.exported([World.ann(), Self.bob()], appleWrites: false)
        world.store.editCard("ann:icloud") { $0.name.family = "Smith" }
        let held = try world.sync()
        #expect(held.plan.appleHold == .appleWritesDisabled)
        #expect(held.plan.apple.contains { $0.title == "Bob Two" })
        #expect(Self.bobRelations(world) == ["Ann One"])
        // Another run: still planned (the base keeps Ann's former name).
        #expect(try world.sync().plan.apple.contains { $0.title == "Bob Two" })
        try world.setConfig { $0.appleWrites = true }
        try Self.settle(world)
        #expect(Self.bobRelations(world) == ["Ann Smith"])
    }

    @Test("Names the user chose are never rewritten: an alias, an unrelated name")
    func userNamesKept() throws {
        let bob = Self.bob([
            RelationshipRef(type: "parent", label: "mother", target: .name("Nana")),
            RelationshipRef(type: "friend", target: .name("Someone Else")),
        ])
        let world = try World.exported([World.ann(), bob])
        try world.editNote(MergeTableTests.path) { $0.aliases.append(.plain("Nana")) }
        try Self.settle(world)
        world.store.editCard("ann:icloud") { $0.name.family = "Smith" }
        try Self.settle(world)
        #expect(Self.bobRelations(world).sorted() == ["Nana", "Someone Else"])
    }

    @Test("Markdown rename: the name goes to Contacts, then other cards' relations follow")
    func markdownRename() throws {
        let world = try World.exported([World.ann(), Self.bob()])
        try world.editNote(MergeTableTests.path) { $0.name.family = "Jones" }
        try Self.settle(world)
        #expect(World.apple(world, "ann:icloud")?.name.family == "Jones")
        #expect(Self.bobRelations(world) == ["Ann Jones"])
        #expect(world.store.unifiedSaveCount == 0)
    }

    @Test("Every writable card holding the old name is updated (linked iCloud + Google)")
    func linkedCards() throws {
        let bob = World.person("bob", "Bob", "Two", accounts: [.iCloud, .google]) {
            $0.relationships = [RelationshipRef(type: "friend", target: .name("Ann One"))]
        }
        let world = try World.exported([World.ann(), bob])
        world.store.editCard("ann:icloud") { $0.name.family = "Smith" }
        try Self.settle(world)
        for card in ["bob:icloud", "bob:google"] {
            let contact = world.store.contact(withCard: card)
            let values = contact?.cards.first { $0.id == card }.flatMap { contact?.values(of: $0) }
            let names = values?.relationships.compactMap {
                if case .name(let name)? = $0.target { return name }
                return nil
            }
            #expect(names == ["Ann Smith"], "\(card)")
        }
        #expect(world.store.unifiedSaveCount == 0)
    }
}
