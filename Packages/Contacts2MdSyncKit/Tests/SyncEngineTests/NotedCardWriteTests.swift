import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Card-write routing (architecture §6 "Write routing", spike S15): without
/// the notes entitlement the Contacts framework refuses every update of a
/// card that has a note (134092) and silently ignores group removals, so
/// those writes go through Contacts.app scripting; without permission for
/// that they are held.
@Suite("Write routing: cards with notes through Contacts.app")
struct NotedCardWriteTests {
    static let annPath = "Inbox/Ann One.md"
    static let bobPath = "Inbox/Bob Two.md"

    /// Ann's card has a note, Bob's has none; both in Family. No entitlement;
    /// the fake framework behaves like S15 (134092, removeMember no-op).
    static func world(
        scriptedNotes: Bool = true, scripting permission: NotesPermission? = .granted, entitled: Bool = false
    ) throws -> (SyncHarness, FakeCardScripting?) {
        let ann = Fixtures.contact("ann", groups: [Fixtures.family], image: Fixtures.jpegBytes) { contact in
            contact.name = PersonName(given: "Ann", family: "One")
            contact.jobTitle = "Engineer"
            contact.emails = [Labeled("home", "ann@home.example")]
            contact.body = "Met at the conference.\n"
        }
        let bob = World.person("bob", "Bob", "Two", groups: [Fixtures.family]) { contact in
            contact.jobTitle = "Designer"
        }
        let world = SyncHarness(contacts: [ann, bob], notesEntitled: entitled)
        try world.export()
        world.store.setModelsFrameworkWithoutNotesEntitlement(true)
        let scripting = permission.map { FakeCardScripting(store: world.store, permission: $0) }
        world.enableCardWriteRouting(scripting)
        if scriptedNotes, !entitled { world.enableScriptedNotes(FakeNotesProvider(store: world.store)) }
        try world.sync()
        return (world, scripting)
    }

    static func jobTitle(_ world: SyncHarness, _ card: String) -> String? { World.apple(world, card)?.jobTitle }

    static func cardNote(_ world: SyncHarness, _ card: String) -> String? {
        world.store.scriptedNotes()[card].flatMap { $0 }
    }

    @Test("a card with a note is written through Contacts.app; one without through the framework; note intact")
    func routesByNote() throws {
        let (world, _) = try Self.world()
        try world.editNote(Self.annPath) { $0.jobTitle = "CTO" }
        try world.editNote(Self.bobPath) { $0.jobTitle = "Lead" }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [])
        #expect(run.result?.appleHeld == [])
        #expect(Self.jobTitle(world, "ann:icloud") == "CTO")
        #expect(Self.jobTitle(world, "bob:icloud") == "Lead")
        #expect(world.store.rejectedForNote.isEmpty, "the noted card is routed directly, never refused first")
        #expect(world.store.scriptedOperations.map(\.cardID) == ["ann:icloud"])
        #expect(Self.cardNote(world, "ann:icloud") == "Met at the conference.\n")
        let again = try world.sync()
        #expect(again.plan.apple.isEmpty && again.plan.markdown.updates.isEmpty, "fixpoint")
    }

    @Test("notes not read: scripting when permitted, so nothing is refused first")
    func unknownNotesScripted() throws {
        let (world, _) = try Self.world(scriptedNotes: false)
        try world.editNote(Self.annPath) { $0.jobTitle = "CTO" }
        try world.editNote(Self.bobPath) { $0.jobTitle = "Lead" }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [])
        #expect(world.store.rejectedForNote.isEmpty)
        #expect(Set(world.store.scriptedOperations.compactMap(\.cardID)) == ["ann:icloud", "bob:icloud"])
        #expect(Self.jobTitle(world, "ann:icloud") == "CTO")
        #expect(try world.sync().plan.apple.isEmpty)
    }

    @Test("not permitted (headless, never asked): framework first; the refused card is held, not failed")
    func heldWithoutPermission() throws {
        let (world, scripting) = try Self.world(scriptedNotes: false, scripting: .notDetermined)
        try world.editNote(Self.annPath) { $0.jobTitle = "CTO" }
        try world.editNote(Self.bobPath) { $0.jobTitle = "Lead" }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [])
        #expect(run.result?.appleHeld.map(\.title) == ["Ann One"])
        #expect(run.result?.appleHeld.first?.reason == CardWriteRouter.permissionReason)
        #expect(Self.jobTitle(world, "ann:icloud") == "Engineer")
        #expect(Self.jobTitle(world, "bob:icloud") == "Lead")
        #expect(try world.note(Self.annPath)?.jobTitle == "CTO", "markdown keeps the edit")
        #expect(world.store.rejectedForNote.count == 1)
        // Still pending next run; written once permission is granted.
        let pending = try world.sync()
        #expect(pending.result?.appleHeld.map(\.title) == ["Ann One"])
        scripting?.setPermission(.granted)
        let granted = try world.sync()
        #expect(granted.result?.appleHeld == [])
        #expect(Self.jobTitle(world, "ann:icloud") == "CTO")
        #expect(try world.sync().plan.apple.isEmpty)
    }

    @Test("no scripting at all: noted cards are held with the permission reason")
    func heldWithoutScripting() throws {
        let (world, _) = try Self.world(scripting: nil)
        try world.editNote(Self.annPath) { $0.jobTitle = "CTO" }
        let run = try world.sync()
        #expect(run.result?.appleHeld.map(\.reason) == [CardWriteRouter.permissionReason])
        #expect(run.result?.appleFailures == [])
        #expect(world.store.rejectedForNote.isEmpty, "known noted card: not even tried through the framework")
        #expect(world.router?.log.held == 1)
    }

    @Test("a group removal always goes through Contacts.app (the framework's is a no-op)")
    func removeMemberScripted() throws {
        let (world, _) = try Self.world(entitled: true)
        try world.editNote(Self.bobPath) { $0.tags.removeAll { $0 == "family" } }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [])
        #expect(world.store.contact(withCard: "bob:icloud")?.groupIDs.contains(Fixtures.family.id) == false)
        #expect(world.store.scriptedOperations == [.removeMember(cardID: "bob:icloud", groupID: Fixtures.family.id)])
        #expect(try world.sync().plan.apple.isEmpty)
    }

    @Test("without routing a group removal that does not stick is unapplyable, not retried every run")
    func removeMemberNoOpVerified() throws {
        let bob = World.person("bob", "Bob", "Two", groups: [Fixtures.family])
        let world = SyncHarness(contacts: [bob], notesEntitled: true)
        try world.export()
        world.store.setModelsFrameworkWithoutNotesEntitlement(true)
        try world.sync()
        try world.editNote(Self.bobPath) { $0.tags.removeAll { $0 == "family" } }
        let run = try world.sync()
        #expect(run.result?.newUnapplyable.map(\.field) == ["tags|family"])
        #expect(run.result?.newUnapplyable.first?.attempted == "-")
        let again = try world.sync()
        #expect(again.plan.apple.isEmpty, "the removal is not planned again while unchanged")
    }

    @Test("an image for a card with a note is unapplyable (not scriptable), the rest of the edit applies")
    func imageSkipped() throws {
        let (world, _) = try Self.world()
        let id = try #require(try world.note(Self.annPath)?.sync.id)
        let sidecar = "_images/\(id.uuidString.lowercased()).jpg"
        #expect(world.vault.data(sidecar) == Fixtures.jpegBytes)
        world.vault.seed(sidecar, Fixtures.pngBytes)
        try world.editNote(Self.annPath) { $0.jobTitle = "CTO" }
        let run = try world.sync()
        #expect(run.result?.appleFailures == [])
        #expect(Self.jobTitle(world, "ann:icloud") == "CTO")
        #expect(world.store.contact(withCard: "ann:icloud")?.imageData == Fixtures.jpegBytes)
        #expect(run.result?.newUnapplyable.map(\.field) == ["image"])
        let again = try world.sync()
        #expect(again.plan.apple.isEmpty, "the image is not planned again while unchanged")
        #expect(world.vault.data(sidecar) == Fixtures.pngBytes, "markdown keeps its image")
    }

    @Test("a session failure through Contacts.app is a failure (retried), not a hold")
    func sessionFailure() throws {
        let (world, scripting) = try Self.world()
        scripting?.setFailSession(true)
        try world.editNote(Self.annPath) { $0.jobTitle = "CTO" }
        let run = try world.sync()
        #expect(run.result?.appleHeld == [])
        #expect(run.result?.appleFailures.count == 1)
        #expect(run.result?.appleFailures.first?.contains("via Contacts.app") == true)
        scripting?.setFailSession(false)
        try world.sync()
        #expect(Self.jobTitle(world, "ann:icloud") == "CTO")
    }
}

/// The router on its own: which route each operation of a mixed batch takes.
@Suite("Write routing: CardWriteRouter")
struct CardWriteRouterTests {
    static func store() -> FakeContactStore {
        let noted = Fixtures.contact("noted", groups: [Fixtures.family]) { $0.body = "a note\n" }
        let plain = Fixtures.contact("plain", groups: [Fixtures.family]) { _ in }
        let gone = Fixtures.contact("gone") { $0.body = "deleted with its note\n" }
        let store = FakeContactStore(contacts: [noted, plain, gone], groups: Fixtures.groups, notesEntitled: false)
        store.setModelsFrameworkWithoutNotesEntitlement(true)
        return store
    }

    static let batch = AppleWriteBatch(
        operations: [
            .update(cardID: "noted:icloud", edits: [.scalar(.jobTitle, "CTO"), .image(Fixtures.jpegBytes)]),
            .update(cardID: "plain:icloud", edits: [.scalar(.jobTitle, "Lead")]),
            .removeMember(cardID: "plain:icloud", groupID: Fixtures.family.id),
            .addMember(cardID: "noted:icloud", groupID: Fixtures.work.id),
            .delete(cardID: "gone:icloud"),
            .create(NewAppleContact(recordID: UUID(), containerID: "icloud", kind: .person, edits: [])),
        ],
        cardNotes: ["noted:icloud": true, "plain:icloud": false])

    @Test("mixed batch: noted card and removals scripted, the rest framework; deletes and creates framework")
    func mixedBatch() throws {
        let store = Self.store()
        let scripting = FakeCardScripting(store: store)
        let router = CardWriteRouter(inner: store, scripting: scripting)
        let result = try router.apply(Self.batch, author: "test")
        #expect(result.failed == [])
        #expect(result.held == [])
        #expect(Set(result.applied) == Set(Self.batch.operations))
        #expect(
            Set(scripting.calls.flatMap { $0 }) == [
                Self.batch.operations[0], Self.batch.operations[2], Self.batch.operations[3],
            ])
        #expect(store.rejectedForNote.isEmpty)
        #expect(store.contact(withCard: "gone:icloud") == nil)
        #expect(store.contact(withCard: "plain:icloud")?.groupIDs == [])
        #expect(store.contact(withCard: "noted:icloud")?.groupIDs.contains(Fixtures.work.id) == true)
        #expect(store.values(ofCard: "noted:icloud")?.jobTitle == "CTO")
        #expect(result.skipped.map(\.edit) == [.image(Fixtures.jpegBytes)])
        #expect(scripting.availabilityChecks == 0, "every card's note was known")
    }

    @Test("a card the batch says has no note but does: refused with 134092, then retried through Contacts.app")
    func retryAfterRejection() throws {
        let store = Self.store()
        let scripting = FakeCardScripting(store: store)
        let router = CardWriteRouter(inner: store, scripting: scripting)
        let update = AppleWriteOperation.update(cardID: "noted:icloud", edits: [.scalar(.jobTitle, "CTO")])
        let result = try router.apply(
            AppleWriteBatch(operations: [update], cardNotes: ["noted:icloud": false]), author: "test")
        #expect(result.applied == [update])
        #expect(result.scripted == [update])
        #expect(store.rejectedForNote == [update])
        #expect(router.log.retriedAfterRejection == 1)
    }

    @Test("entitlement present: everything through the framework except group removals")
    func entitled() throws {
        let store = FakeContactStore(
            contacts: [Fixtures.contact("noted", groups: [Fixtures.family]) { $0.body = "a note\n" }],
            groups: Fixtures.groups, notesEntitled: true)
        let scripting = FakeCardScripting(store: store)
        let router = CardWriteRouter(inner: store, scripting: scripting)
        let update = AppleWriteOperation.update(cardID: "noted:icloud", edits: [.scalar(.jobTitle, "CTO")])
        let remove = AppleWriteOperation.removeMember(cardID: "noted:icloud", groupID: Fixtures.family.id)
        let result = try router.apply(AppleWriteBatch(operations: [update, remove]), author: "test")
        #expect(Set(result.applied) == [update, remove])
        #expect(scripting.calls == [[remove]])
    }

    @Test("permission denied: scripted operations are held; framework ones still applied")
    func denied() throws {
        let store = Self.store()
        let router = CardWriteRouter(inner: store, scripting: FakeCardScripting(store: store, permission: .denied))
        let result = try router.apply(Self.batch, author: "test")
        #expect(
            Set(result.held.map(\.operation)) == [
                Self.batch.operations[0], Self.batch.operations[2], Self.batch.operations[3],
            ])
        #expect(result.failed == [])
        #expect(result.applied.count == 3)
        #expect(store.values(ofCard: "plain:icloud")?.jobTitle == "Lead")
    }

    @Test("operation summaries name the operation and its fields")
    func summaries() {
        #expect(
            AppleWriteOperation.update(cardID: "x", edits: [.scalar(.jobTitle, "A"), .list(.emails, [])]).summary
                == "update (job title, emails)")
        #expect(AppleWriteOperation.removeMember(cardID: "x", groupID: "g").summary == "remove from group")
    }
}
