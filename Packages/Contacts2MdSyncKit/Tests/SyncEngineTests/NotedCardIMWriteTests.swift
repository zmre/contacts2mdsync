import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// A card with a note whose instant message Contacts.app cannot find
/// (`-1728`, spike S16; `ScriptingCardWriter` reports that list edit
/// skipped): the rest of the edit is applied, the card is not failed, the IM
/// is unapplyable by value — not planned again while unchanged, planned
/// again once the markdown changes it — and nothing ping-pongs.
@Suite("Write routing: an unresolvable IM on a card with a note")
struct NotedCardIMWriteTests {
    static let path = "Inbox/Ann One.md"
    static let card = "ann:icloud"

    static func world() throws -> (SyncHarness, FakeCardScripting) {
        let ann = Fixtures.contact("ann") { contact in
            contact.name = PersonName(given: "Ann", family: "One")
            contact.jobTitle = "Engineer"
            contact.im = [Labeled("skype", IMHandle("ann"))]
            contact.body = "Met at the conference.\n"
        }
        let world = SyncHarness(contacts: [ann], notesEntitled: false)
        try world.export()
        world.store.setModelsFrameworkWithoutNotesEntitlement(true)
        let scripting = FakeCardScripting(store: world.store)
        world.enableCardWriteRouting(scripting)
        world.enableScriptedNotes(FakeNotesProvider(store: world.store))
        try world.sync()
        scripting.setUnresolvable(.im, ofCard: Self.card)
        return (world, scripting)
    }

    @Test("partial: job title applied, IM unapplyable (by value), no failure; next run plans nothing")
    func partialThenQuiet() throws {
        let (world, scripting) = try Self.world()
        try world.editNote(Self.path) {
            $0.jobTitle = "CTO"
            $0.im = [Labeled("skype", IMHandle("ann2"))]
        }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [], "an unresolvable IM does not fail the card")
        #expect(run.result?.appleHeld == [])
        #expect(run.result?.apple.map(\.title) == ["Ann One"], "the change counts as made")
        #expect(World.apple(world, Self.card)?.jobTitle == "CTO")
        #expect(World.apple(world, Self.card)?.im == [Labeled("skype", IMHandle("ann"))])
        let unapplyable = run.result?.newUnapplyable ?? []
        #expect(unapplyable.map(\.field).allSatisfy { $0.hasPrefix("im|") })
        #expect(unapplyable.count == 1)
        #expect(unapplyable.first?.observed == "absent")
        let calls = scripting.calls.count

        let again = try world.sync()
        #expect(again.plan.apple.isEmpty, "the IM is not planned again while unchanged")
        #expect(again.plan.markdown.updates.isEmpty, "the card's old IM is not pulled into markdown (no ping-pong)")
        #expect(scripting.calls.count == calls)
        #expect(try world.note(Self.path)?.im == [Labeled("skype", IMHandle("ann2"))], "markdown keeps its IM")
        #expect(try world.note(Self.path)?.jobTitle == "CTO")
        let third = try world.sync()
        #expect(third.plan.apple.isEmpty && third.plan.markdown.updates.isEmpty, "fixpoint")
    }

    @Test("the markdown IM changes again: planned again (keyed by value); resolvable now → written, entry gone")
    func retriedWhenValueChanges() throws {
        let (world, scripting) = try Self.world()
        try world.editNote(Self.path) { $0.im = [Labeled("skype", IMHandle("ann2"))] }
        try world.sync()
        #expect(try world.sync().plan.apple.isEmpty)
        scripting.setUnresolvable(.im, ofCard: Self.card, false)
        try world.editNote(Self.path) { $0.im = [Labeled("skype", IMHandle("ann3"))] }
        let run = try world.sync()
        #expect(!run.plan.apple.isEmpty, "a new value is a new attempt")
        #expect(run.result?.appleFailures == [])
        #expect(World.apple(world, Self.card)?.im == [Labeled("skype", IMHandle("ann3"))])
        #expect(run.result?.newUnapplyable == [])
        let again = try world.sync()
        #expect(again.plan.apple.isEmpty && again.plan.markdown.updates.isEmpty, "fixpoint")
    }
}
