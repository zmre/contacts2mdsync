import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Apple group renames and deletions (architecture §8), recognised by CN
/// group id from this device's `groups` table.
@Suite("Groups: renames and deletions in Contacts")
struct GroupRenameTests {
    static func world(tag: String? = nil) throws -> SyncHarness {
        let ann = World.person("ann", "Ann", "One", groups: [Fixtures.family])
        let bob = World.person("bob", "Bob", "Two", groups: [Fixtures.family, Fixtures.work])
        let world = try World.exported([ann, bob])
        if let tag {
            try world.setConfig { config in
                if let index = config.groups.firstIndex(where: { $0.group == "Family" }) {
                    config.groups[index].tag = tag
                }
            }
            try world.editNote(MergeTableTests.path) { $0.tags = $0.tags.map { $0 == "family" ? tag : $0 } }
            try world.editNote(RelationRenameTests.bobPath) { $0.tags = $0.tags.map { $0 == "family" ? tag : $0 } }
            try RelationRenameTests.settle(world)
        }
        try world.editNote(MergeTableTests.path) { $0.tags.append("vip") }
        try RelationRenameTests.settle(world)
        return world
    }

    @Test(
        "Rename: the config entry and the default tag follow; notes get the new tag in place", arguments: [false, true])
    func rename(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try Self.world()
            #expect(try world.note(MergeTableTests.path)?.tags == ["family", "vip"])
            world.store.renameGroup(Fixtures.family.id, to: "Relatives")
            let run = try world.sync()
            #expect(run.plan.markdown.groupChanges.map(\.kind) == [.renamed])
            #expect(run.plan.markdown.groupChanges.first?.summary.contains("tag family → relatives") == true)
            let config = try world.config
            #expect(config.tag(forGroup: "Relatives") == "relatives")
            #expect(config.tag(forGroup: "Family") == nil)
            #expect(try world.note(MergeTableTests.path)?.tags == ["relatives", "vip"])
            #expect(try world.note(RelationRenameTests.bobPath)?.tags.contains("relatives") == true)
            #expect(try world.note(RelationRenameTests.bobPath)?.tags.contains("family") == false)
            // Membership is unchanged: no group writes to Contacts.
            #expect(run.plan.apple.isEmpty, "\(run.plan.apple)")
            #expect(try world.plan().plan.isEmpty)
            #expect(World.apple(world, "ann:icloud") != nil)
            #expect(world.store.contact(withCard: "ann:icloud")?.groupIDs == [Fixtures.family.id])
        }
    }

    @Test("Rename keeps a custom tag (only the group name in the map changes)")
    func renameCustomTag() throws {
        let world = try Self.world(tag: "kin")
        world.store.renameGroup(Fixtures.family.id, to: "Relatives")
        let run = try world.sync()
        #expect(run.plan.markdown.groupChanges.first?.newTag == "kin")
        #expect(try world.config.tag(forGroup: "Relatives") == "kin")
        #expect(try world.note(MergeTableTests.path)?.tags == ["kin", "vip"])
        #expect(run.plan.markdown.updates.isEmpty)
        #expect(try world.plan().plan.isEmpty)
    }

    @Test("Delete: the tag is no longer managed and stays in every note; a warning says so")
    func delete() throws {
        let world = try Self.world()
        world.store.deleteGroup(Fixtures.family.id)
        let run = try world.sync()
        let change = try #require(run.plan.markdown.groupChanges.first)
        #expect(change.kind == .deleted && change.tag == "family")
        #expect(change.summary.contains("no longer managed"))
        #expect(try world.config.tag(forGroup: "Family") == nil)
        #expect(try world.note(MergeTableTests.path)?.tags == ["family", "vip"])
        #expect(try world.note(RelationRenameTests.bobPath)?.tags.contains("family") == true)
        #expect(run.plan.markdown.updates.isEmpty)
        let again = try world.sync()
        #expect(again.plan.isEmpty && again.plan.markdown.groupChanges.isEmpty)
        // Adding the (now unmanaged) tag in markdown changes nothing in Contacts.
        try world.editNote("Inbox/Bob Two.md") { $0.tags.append("family") }
        #expect(try world.sync().plan.apple.isEmpty)
    }

    @Test("A dry run follows nothing: the rename is found again by the next executed run")
    func dryRunThenSync() throws {
        let world = try Self.world()
        world.store.renameGroup(Fixtures.family.id, to: "Relatives")
        #expect(try world.plan().plan.markdown.groupChanges.count == 1)
        #expect(try world.config.tag(forGroup: "Family") == "family")
        try RelationRenameTests.settle(world)
        #expect(try world.config.tag(forGroup: "Relatives") == "relatives")
        #expect(try world.note(MergeTableTests.path)?.tags == ["relatives", "vip"])
    }
}
