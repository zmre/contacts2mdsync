import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// A card with a note, written through Contacts.app scripting (spike S16):
/// instant-message edits are skipped up front (Contacts.app refuses every
/// IM change, `-1719`), and an element Contacts.app refuses is left out
/// while the rest of the card is written. Either way the card is not
/// failed, the skipped field is unapplyable by value — not planned again
/// while unchanged, planned again once the markdown changes it — and
/// nothing ping-pongs.
@Suite("Write routing: IM and refused elements on a card with a note")
struct NotedCardIMWriteTests {
    static let path = "Inbox/Ann One.md"
    static let card = "ann:icloud"

    static func world() throws -> (SyncHarness, FakeCardScripting) {
        let ann = Fixtures.contact("ann") { contact in
            contact.name = PersonName(given: "Ann", family: "One")
            contact.jobTitle = "Engineer"
            contact.emails = [Labeled("home", "ann@home.example")]
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
        return (world, scripting)
    }

    @Test("IM edit: job title applied, IM skipped (notes entitlement) and unapplyable by value; next run quiet")
    func partialThenQuiet() throws {
        let (world, scripting) = try Self.world()
        try world.editNote(Self.path) {
            $0.jobTitle = "CTO"
            $0.im = [Labeled("skype", IMHandle("ann2"))]
        }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [], "a skipped IM does not fail the card")
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

    @Test("the markdown IM changes again: planned again (keyed by value), skipped again, still no failure")
    func retriedWhenValueChanges() throws {
        let (world, _) = try Self.world()
        try world.editNote(Self.path) { $0.im = [Labeled("skype", IMHandle("ann2"))] }
        try world.sync()
        #expect(try world.sync().plan.apple.isEmpty)
        try world.editNote(Self.path) { $0.im = [Labeled("skype", IMHandle("ann3"))] }
        let run = try world.sync()
        #expect(!run.plan.apple.isEmpty, "a new value is a new attempt")
        #expect(run.result?.appleFailures == [])
        #expect(World.apple(world, Self.card)?.im == [Labeled("skype", IMHandle("ann"))])
        #expect(run.result?.newUnapplyable.map(\.field).allSatisfy { $0.hasPrefix("im|") } == true)
        let again = try world.sync()
        #expect(again.plan.apple.isEmpty && again.plan.markdown.updates.isEmpty, "fixpoint")
    }

    @Test("an email Contacts.app refuses (-1719): job title applied, email unapplyable; quiet; later written")
    func refusedElement() throws {
        let (world, scripting) = try Self.world()
        scripting.setRefused(.emails, ofCard: Self.card, error: -1719)
        try world.editNote(Self.path) {
            $0.jobTitle = "CTO"
            $0.emails = [Labeled("home", "ann@home.example"), Labeled("work", "ann@work.example")]
        }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [], "a refused element does not fail the card")
        #expect(run.result?.apple.map(\.title) == ["Ann One"])
        #expect(World.apple(world, Self.card)?.jobTitle == "CTO")
        #expect(World.apple(world, Self.card)?.emails == [Labeled("home", "ann@home.example")])
        let unapplyable = run.result?.newUnapplyable ?? []
        #expect(unapplyable.count == 1)
        #expect(unapplyable.first?.field.hasPrefix("emails|") == true)
        let again = try world.sync()
        #expect(again.plan.apple.isEmpty, "not retried while unchanged")
        #expect(again.plan.markdown.updates.isEmpty, "no ping-pong")

        scripting.setRefused(.emails, ofCard: Self.card, error: nil)
        try world.editNote(Self.path) {
            $0.emails = [Labeled("home", "ann@home.example"), Labeled("work", "ann@work2.example")]
        }
        let retried = try world.sync()
        #expect(retried.result?.appleFailures == [])
        #expect(World.apple(world, Self.card)?.emails.map(\.value).contains("ann@work2.example") == true)
        let quiet = try world.sync()
        #expect(quiet.plan.apple.isEmpty && quiet.plan.markdown.updates.isEmpty, "fixpoint")
    }
}
