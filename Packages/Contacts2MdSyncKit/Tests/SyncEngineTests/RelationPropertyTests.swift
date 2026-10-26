import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Random relationship edits on both sides (add, delete, re-target, change
/// type), on cards with notes written through (fake) Contacts.app, some of
/// which lose the related names they are asked to change (what a real Mac
/// did, 2026-10-25). Relationships never conflict: after every round the
/// sync settles within a few runs, with no conflict, and — while Contacts
/// keeps what it is sent — both sides hold the same relations.
@Suite("Relationships: random edits → no conflicts, fixpoint")
struct RelationPropertyTests {
    static let people = [("p0", "Mara"), ("p1", "Bram"), ("p2", "Cora"), ("p3", "Dov")]
    static let types = ["child", "spouse", "sibling", "friend", "parent"]

    static func path(_ given: String) -> String { "Inbox/\(given) Quill.md" }
    static func card(_ slug: String) -> String { "\(slug):icloud" }

    static func world() throws -> (SyncHarness, FakeCardScripting) {
        let contacts = people.map { slug, given in
            World.person(slug, given, "Quill") { $0.body = "note of \(given)\n" }
        }
        let world = try World.exported(contacts, stamps: .never)
        world.store.setModelsFrameworkWithoutNotesEntitlement(true)
        let scripting = FakeCardScripting(store: world.store)
        world.enableCardWriteRouting(scripting)
        world.enableScriptedNotes(FakeNotesProvider(store: world.store))
        try world.sync()
        return (world, scripting)
    }

    /// Relations as `type|name` (Apple names and note titles are both "Given Quill").
    static func relationKeys(_ relations: [RelationshipRef]) -> Set<String> {
        Set(relations.map { "\($0.type)|\($0.target?.displayName ?? "?")" })
    }

    /// One random relationship edit on one side of one random person.
    static func edit(_ world: SyncHarness, _ random: inout SeededRandom) throws {
        let (slug, given) = people[Int.random(in: 0..<people.count, using: &random)]
        let others = people.filter { $0.0 != slug }.map { "\($0.1) Quill" }
        let other = others[Int.random(in: 0..<others.count, using: &random)]
        let type = types[Int.random(in: 0..<types.count, using: &random)]
        let operation = Int.random(in: 0..<4, using: &random)
        let pick = Int.random(in: 0..<1000, using: &random)
        let onApple = Bool.random(using: &random)
        let change = { (relations: inout [RelationshipRef], target: RelationshipTarget) in
            Self.apply(operation, pick: pick, type: type, target: target, to: &relations)
        }
        if onApple {
            world.store.editCard(card(slug)) { change(&$0.relationships, .name(other)) }
        } else {
            try world.editNote(path(given)) { change(&$0.relationships, .wikilink(other)) }
        }
    }

    /// Add, delete, re-target or retype one relation.
    static func apply(
        _ operation: Int, pick: Int, type: String, target: RelationshipTarget, to relations: inout [RelationshipRef]
    ) {
        if operation == 0 {
            relations.append(RelationshipRef(type: type, target: target))
            return
        }
        guard !relations.isEmpty else { return }
        let index = pick % relations.count
        switch operation {
        case 1: relations.remove(at: index)
        case 2: relations[index].target = target
        default: relations[index].type = type
        }
    }

    @Test("random relationship edits × rounds, some cards losing scripted related names", arguments: [false, true])
    func randomRelationRounds(lossy: Bool) throws {
        var edits = 0
        var lostRounds = 0
        for seed in UInt64(1)...4 {
            var random = SeededRandom(seed: seed &* 15_485_863 &+ (lossy ? 1 : 0))
            let (world, scripting) = try Self.world()
            for round in 0..<10 {
                let context = "seed \(seed) round \(round) lossy \(lossy)"
                var losing = Set<String>()
                if lossy {
                    for (slug, _) in Self.people where Int.random(in: 0..<3, using: &random) == 0 {
                        losing.insert(slug)
                    }
                }
                for (slug, _) in Self.people {
                    scripting.setLosesChangedElements(.relations, ofCard: Self.card(slug), losing.contains(slug))
                }
                if !losing.isEmpty { lostRounds += 1 }
                for _ in 0..<Int.random(in: 1...5, using: &random) {
                    try Self.edit(world, &random)
                    edits += 1
                }
                try Self.settleRound(world, agree: !lossy, context: context)
                world.advance(minutes: 3)
            }
        }
        #expect(edits > 40)
        if lossy { #expect(lostRounds > 5) }
    }

    /// Syncs until a plan is empty (at most 4 runs): no conflict, no failure;
    /// with `agree`, both sides then hold the same relations.
    static func settleRound(_ world: SyncHarness, agree: Bool, context: String) throws {
        var settled = false
        for _ in 0..<4 {
            let run = try world.sync()
            #expect(run.plan.conflicts.isEmpty, "\(context): \(run.plan.conflicts.map(\.summary))")
            #expect(run.result?.appleFailures == [], "\(context)")
            if run.plan.isEmpty {
                settled = true
                break
            }
        }
        #expect(settled, "\(context): no fixpoint")
        #expect(try world.pending("conflict").isEmpty, "\(context)")
        guard agree else { return }
        for (slug, given) in people {
            let apple = relationKeys(World.apple(world, card(slug))?.relationships ?? [])
            let note = relationKeys(try world.note(path(given))?.relationships ?? [])
            #expect(apple == note, "\(context) \(given): Contacts \(apple.sorted()) vs note \(note.sorted())")
        }
    }
}
