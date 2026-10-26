import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// False conflicts on relationships changed only in markdown (user report
/// 2026-10-25, "Mara Quill"): relations re-pointed in markdown from
/// plain names (`to: Cora`) to links (`to: "[[Cora Quill]]"`) on noted
/// cards. The scripted write left the cards without those relations, the
/// merge base kept the old elements although neither side had them, and the
/// next merge read Apple's absence as a deletion against the markdown edit.
@Suite("Relationships changed only in markdown never conflict")
struct RelationConflictTests {
    static let annPath = "Inbox/Mara Quill.md"
    static let brianPath = "Inbox/Bram Quill.md"

    /// Mara and Bram (both noted, as on the user's Mac) and Cora.
    /// Their Apple relations use first names only, which resolve to no
    /// record, so the notes say `to: Cora` (plain names).
    static func contacts() -> [AppleContact] {
        let ann = World.person("ann", "Mara", "Quill") {
            $0.relationships = [
                RelationshipRef(type: "child", target: .name("Cora")),
                RelationshipRef(type: "spouse", target: .name("Bram")),
            ]
            $0.body = "Mara's note.\n"
        }
        let bram = World.person("bram", "Bram", "Quill") {
            $0.relationships = [
                RelationshipRef(type: "other", target: .name("The Quills")),
                RelationshipRef(type: "spouse", target: .name("Mara")),
                RelationshipRef(type: "child", target: .name("Cora")),
            ]
            $0.body = "Bram's note.\n"
        }
        return [ann, bram, World.person("cora", "Cora", "Quill")]
    }

    /// A world after the first import and two-way run; cards with notes are
    /// written through (fake) Contacts.app like on the user's Mac.
    static func world(
        appleWrites: Bool = true, scripting permission: NotesPermission? = .granted
    ) throws -> (SyncHarness, FakeCardScripting?) {
        let world = try World.exported(contacts(), appleWrites: appleWrites, stamps: .never)
        world.store.setModelsFrameworkWithoutNotesEntitlement(true)
        let scripting = permission.map { FakeCardScripting(store: world.store, permission: $0) }
        world.enableCardWriteRouting(scripting)
        world.enableScriptedNotes(FakeNotesProvider(store: world.store))
        return (world, scripting)
    }

    /// The user's markdown edit: plain names → links to the records.
    static func linkRelations(_ world: SyncHarness) throws {
        try world.editNote(annPath) {
            $0.relationships = [
                RelationshipRef(type: "child", target: .wikilink("Cora Quill")),
                RelationshipRef(type: "spouse", target: .wikilink("Bram Quill")),
            ]
        }
        try world.editNote(brianPath) {
            $0.relationships = [
                RelationshipRef(type: "other", target: .name("The Quills")),
                RelationshipRef(type: "spouse", target: .wikilink("Mara Quill")),
                RelationshipRef(type: "child", target: .wikilink("Cora Quill")),
            ]
        }
    }

    /// A card's relations as `type label name`.
    static func relations(_ world: SyncHarness, _ card: String) -> [String] {
        (World.apple(world, card)?.relationships ?? []).map { ref in
            "\(ref.type) \(ref.label ?? "-") \(ref.target?.displayName ?? "?")"
        }.sorted()
    }

    static func links(_ world: SyncHarness, _ path: String) throws -> [String] {
        try (world.note(path)?.relationships ?? []).map { ref in
            switch ref.target {
            case .wikilink(let title)?: "\(ref.type) [[\(title)]]"
            case .name(let name)?: "\(ref.type) \(name)"
            default: "\(ref.type) ?"
            }
        }
    }

    static func conflicts(_ run: SyncHarness.Run) -> [String] { run.plan.conflicts.map(\.summary) }

    /// Runs until a plan is empty (at most `limit` runs); every run must be conflict-free.
    @discardableResult
    static func settle(_ world: SyncHarness, limit: Int = 4) throws -> SyncHarness.Run {
        for _ in 0..<limit {
            let run = try world.sync()
            #expect(conflicts(run).isEmpty, "\(conflicts(run))")
            if run.plan.isEmpty { return run }
        }
        let last = try world.sync()
        Issue.record("no fixpoint: \(last.plan.apple.map(\.fields)) \(last.plan.markdown.updates.map(\.changedFields))")
        return last
    }

    // MARK: - H3 / the user's case: the scripted write loses the relations

    @Test("scripted relation edits that Contacts.app drops: no conflict, markdown kept, reported unapplyable")
    func scriptedWriteLosesRelations() throws {
        let (world, scripting) = try Self.world()
        let scripting1 = try #require(scripting)
        scripting1.setLosesChangedElements(.relations, ofCard: "ann:icloud")
        scripting1.setLosesChangedElements(.relations, ofCard: "bram:icloud")
        try Self.linkRelations(world)

        let first = try world.sync()
        #expect(Self.conflicts(first).isEmpty)
        #expect(first.result?.appleFailures == [])
        // What the real Contacts.app did: the old relations are gone, the new ones never came.
        #expect(Self.relations(world, "ann:icloud").isEmpty)
        #expect(Self.relations(world, "bram:icloud") == ["other - The Quills"])

        // The next runs (where the user saw 4 conflicts): no conflict, the
        // markdown edits stay, and Contacts is asked once more to add them.
        let second = try world.sync()
        #expect(Self.conflicts(second).isEmpty, "\(Self.conflicts(second))")
        #expect(try world.pending("conflict").isEmpty)
        let added = second.plan.apple.flatMap(\.fields)
        #expect(added == ["relationships", "relationships"])
        try Self.settle(world)
        #expect(try Self.links(world, Self.annPath) == ["child [[Cora Quill]]", "spouse [[Bram Quill]]"])
        #expect(
            try Self.links(world, Self.brianPath) == [
                "other The Quills", "spouse [[Mara Quill]]", "child [[Cora Quill]]",
            ])
        // The values Contacts could not take are recorded, not retried.
        let refused = try world.state.loadUnapplyable().filter { $0.field.hasPrefix("relationships|") }
        #expect(refused.count == 4, "\(refused)")
        #expect(refused.allSatisfy { $0.attempted == "+" && $0.observed == "absent" })

        // Not retried while the markdown value stays the same (no ping-pong).
        scripting1.setLosesChangedElements(.relations, ofCard: "ann:icloud", false)
        #expect(try world.sync().plan.isEmpty)
        #expect(Self.relations(world, "ann:icloud").isEmpty)
    }

    @Test("the scripted write works: relations re-pointed in place, labels and types right, fixpoint")
    func scriptedWriteKeepsRelations() throws {
        let (world, _) = try Self.world()
        try Self.linkRelations(world)
        let run = try world.sync()
        #expect(Self.conflicts(run).isEmpty)
        #expect(Self.relations(world, "ann:icloud") == ["child - Cora Quill", "spouse - Bram Quill"])
        // Bram's two unlabeled relations are never paired across types (child ↔ spouse).
        #expect(
            Self.relations(world, "bram:icloud") == [
                "child - Cora Quill", "other - The Quills", "spouse - Mara Quill",
            ])
        #expect(try world.sync().plan.isEmpty)
    }

    // MARK: - H1: failed, held and refused writes leave Apple "unchanged"

    @Test("a write the framework refuses (134092, before scripting existed): no conflict, written later")
    func frameworkRefusesNotedCard() throws {
        let (world, _) = try Self.world(scripting: nil)
        try Self.linkRelations(world)
        for _ in 0..<3 {
            let run = try world.sync()
            #expect(Self.conflicts(run).isEmpty, "\(Self.conflicts(run))")
            #expect(run.result?.appleHeld.count == 2, "held, not lost")
        }
        #expect(Self.relations(world, "ann:icloud") == ["child - Cora", "spouse - Bram"], "Contacts unchanged")
        world.enableCardWriteRouting(FakeCardScripting(store: world.store))
        try Self.settle(world)
        #expect(Self.relations(world, "ann:icloud") == ["child - Cora Quill", "spouse - Bram Quill"])
    }

    @Test("apple_writes off (writes held): no conflict; written once turned on")
    func appleWritesOff() throws {
        let (world, _) = try Self.world(appleWrites: false)
        try Self.linkRelations(world)
        for _ in 0..<2 {
            let run = try world.sync()
            #expect(Self.conflicts(run).isEmpty, "\(Self.conflicts(run))")
            #expect(run.plan.appleHold == .appleWritesDisabled)
        }
        try world.setConfig { $0.appleWrites = true }
        try Self.settle(world)
        #expect(Self.relations(world, "ann:icloud") == ["child - Cora Quill", "spouse - Bram Quill"])
    }

    @Test("Contacts.app refuses the related-name commands (-1719): no conflict, unapplyable, fixpoint")
    func refusedElements() throws {
        let (world, scripting) = try Self.world()
        try #require(scripting).setRefused(.relations, ofCard: "ann:icloud")
        try Self.linkRelations(world)
        let run = try world.sync()
        #expect(Self.conflicts(run).isEmpty)
        #expect(run.result?.newUnapplyable.contains { $0.field.hasPrefix("relationships|") } == true)
        let last = try Self.settle(world)
        #expect(last.plan.isEmpty)
        #expect(Self.relations(world, "ann:icloud") == ["child - Cora", "spouse - Bram"])
        #expect(try Self.links(world, Self.annPath) == ["child [[Cora Quill]]", "spouse [[Bram Quill]]"])
    }

    // MARK: - H2: keys of the same relation agree on both sides

    @Test("a relation Apple names like the note title is one element: no change either side")
    func appleNameAndLinkAgree() throws {
        let (world, _) = try Self.world()
        try Self.linkRelations(world)
        try Self.settle(world)
        // Apple now says "Cora Quill"; markdown `[[Cora Quill]]` (brackets
        // only in the link): both resolve to Cora's record.
        let plan = try world.plan().plan
        #expect(plan.isEmpty)
        let annID = try #require(try world.recordID(Self.annPath))
        let base = try #require(try world.state.load()[annID]?.base)
        #expect(base.keys("relationships").allSatisfy { $0.contains("|r:") }, "\(base.keys("relationships"))")
    }

    // MARK: - H4: type and label changes

    @Test("type and label changed in markdown: Contacts takes the new type and label, no conflict")
    func typeAndLabelChange() throws {
        let (world, _) = try Self.world()
        try Self.linkRelations(world)
        try Self.settle(world)
        try world.editNote(Self.annPath) {
            $0.relationships = [
                RelationshipRef(type: "child", label: "daughter", target: .wikilink("Cora Quill")),
                RelationshipRef(type: "sibling", target: .wikilink("Bram Quill")),
            ]
        }
        try Self.settle(world)
        #expect(Self.relations(world, "ann:icloud") == ["child daughter Cora Quill", "sibling - Bram Quill"])
    }

    @Test("type changed in markdown while Contacts deleted the relation: no conflict, markdown wins")
    func typeChangeAgainstAppleDelete() throws {
        let (world, _) = try Self.world()
        try Self.linkRelations(world)
        try Self.settle(world)
        try world.editNote(Self.annPath) {
            $0.relationships[1] = RelationshipRef(type: "sibling", target: .wikilink("Bram Quill"))
        }
        world.store.editCard("ann:icloud") { $0.relationships.removeAll { $0.type == "spouse" } }
        try Self.settle(world)
        #expect(Self.relations(world, "ann:icloud") == ["child - Cora Quill", "sibling - Bram Quill"])
    }

    @Test("a real Apple-side relation delete, markdown untouched: deleted in markdown")
    func appleDeleteStillDeletes() throws {
        let (world, _) = try Self.world()
        try Self.linkRelations(world)
        try Self.settle(world)
        world.store.editCard("ann:icloud") { $0.relationships.removeAll { $0.type == "spouse" } }
        try Self.settle(world)
        #expect(try Self.links(world, Self.annPath) == ["child [[Cora Quill]]"])
    }

    // MARK: - Migration: the user's state

    @Test("the user's state (base keeps the old relations, Contacts has none): conflicts gone on the next plan")
    func existingFalseConflictsDisappear() throws {
        let (world, _) = try Self.world()
        // The state the user's Mac is in: the base still holds `child|n:cora`
        // and `spouse|n:bram`, the cards have no such relations, the notes
        // link the records.
        try Self.linkRelations(world)
        world.store.editCard("ann:icloud") { $0.relationships = [] }
        world.store.editCard("bram:icloud") { $0.relationships.removeAll { $0.type != "other" } }
        let annID = try #require(try world.recordID(Self.annPath))
        let base = try #require(try world.state.load()[annID]?.base)
        #expect(base.keys("relationships") == ["child|n:cora", "spouse|n:bram"])
        // The four conflicts the old version queued.
        let stale = try world.state.loadPending()
        try world.state.savePending(
            stale.replacing(with: RelationConflictTests.staleConflicts(record: annID), at: world.clock.now))
        #expect(try world.pending("conflict").count == 1)

        let plan = try world.plan().plan
        #expect(plan.conflicts.isEmpty, "\(plan.conflicts.map(\.summary))")
        #expect(try world.pending("conflict").isEmpty, "the queued false conflicts are gone")
        #expect(plan.apple.map(\.fields) == [["relationships"], ["relationships"]], "the links go to Contacts")
        try Self.settle(world)
        #expect(Self.relations(world, "ann:icloud") == ["child - Cora Quill", "spouse - Bram Quill"])
        #expect(
            Self.relations(world, "bram:icloud") == [
                "child - Cora Quill", "other - The Quills", "spouse - Mara Quill",
            ])
    }

    /// A conflict like the old version queued for Mara.
    static func staleConflicts(record: UUID) -> [ReviewItem] {
        [
            .conflict(
                SyncConflict(
                    id: "conflict-c69a084f01",
                    recordID: record, title: "Mara Quill", path: annPath, field: "relationships",
                    element: "[[Cora Quill]]", base: ConflictSide(value: "Cora"), apple: ConflictSide(value: nil),
                    markdown: ConflictSide(value: "[[Cora Quill]]"), options: [.keepApple, .keepMarkdown],
                    appleHash: "73c8ffe9553f8c24", markdownHash: "a0a4f73037369e18"))
        ]
    }
}

/// A list edit Contacts refused (unapplyable `~`/`@`) whose old value later
/// disappears from Contacts is Apple *unchanged*, never an Apple deletion:
/// no conflict, markdown wins locally (architecture §7 "Unapplyable values").
@Suite("Refused list writes never turn into delete-vs-edit conflicts")
struct RefusedListWriteTests {
    @Test("refused right after the write, lost in Contacts later (the user's timeline): no conflict")
    func refusedThenLost() throws {
        let (world, scripting) = try RelationConflictTests.world()
        let scripting1 = try #require(scripting)
        scripting1.setRefused(.relations, ofCard: "ann:icloud")
        try RelationConflictTests.linkRelations(world)
        let first = try world.sync()
        #expect(first.result?.newUnapplyable.filter { $0.attempted.hasPrefix("~") }.count == 2)
        #expect(try world.sync().plan.isEmpty, "refused: not retried")
        // Minutes later the card has lost the related names.
        world.store.editCard("ann:icloud") { $0.relationships = [] }
        scripting1.setRefused(.relations, ofCard: "ann:icloud", error: nil)
        let later = try world.sync()
        #expect(RelationConflictTests.conflicts(later).isEmpty, "\(RelationConflictTests.conflicts(later))")
        try RelationConflictTests.settle(world)
        #expect(
            RelationConflictTests.relations(world, "ann:icloud") == ["child - Cora Quill", "spouse - Bram Quill"])
    }

    @Test("any list: an edit Contacts refused, then the old value gone from Contacts → markdown wins, no conflict")
    func refusedEditThenLostPhone() throws {
        let (world, scripting) = try RelationConflictTests.world()
        let scripting1 = try #require(scripting)
        world.store.editCard("ann:icloud") { $0.phones = [Labeled("mobile", "+1 415 555 0100")] }
        try RelationConflictTests.settle(world)
        scripting1.setRefused(.phones, ofCard: "ann:icloud")
        try world.editNote(RelationConflictTests.annPath) { $0.phones = [Labeled("mobile", "+1 415 555 0177")] }
        let first = try world.sync()
        #expect(
            first.result?.newUnapplyable.contains { $0.field.hasPrefix("phones|") && $0.attempted.hasPrefix("~") }
                == true)
        world.store.editCard("ann:icloud") { $0.phones = [] }
        let later = try world.sync()
        #expect(RelationConflictTests.conflicts(later).isEmpty, "\(RelationConflictTests.conflicts(later))")
        #expect(
            try world.note(RelationConflictTests.annPath)?.phones.map(\.value) == ["+1 415 555 0177"],
            "markdown wins locally")
        try RelationConflictTests.settle(world)
    }

    @Test("without a refusal, Contacts deleting a phone markdown edited is still a conflict (§7)")
    func realPhoneDeleteVsEditStillConflicts() throws {
        let (world, _) = try RelationConflictTests.world()
        world.store.editCard("ann:icloud") { $0.phones = [Labeled("mobile", "+1 415 555 0100")] }
        try RelationConflictTests.settle(world)
        try world.editNote(RelationConflictTests.annPath) { $0.phones = [Labeled("mobile", "+1 415 555 0177")] }
        world.store.editCard("ann:icloud") { $0.phones = [] }
        let run = try world.sync()
        #expect(run.plan.conflicts.map(\.field) == ["phones"])
    }
}

extension SyncHarness {
    /// The record id of the note at `path`.
    func recordID(_ path: String) throws -> UUID? { try note(path)?.sync.id }
}
