import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// Deterministic random numbers (SplitMix64), so a failing seed reproduces.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Random edits on both sides, synced round after round (architecture §14):
/// after each round one sync reaches a fixpoint (a second sync plans
/// nothing), no file or contact is duplicated, nothing is saved to a unified
/// contact, and every field without a conflict holds exactly the three-way
/// result of that round's edits: additions from either side kept, explicit
/// deletions gone, single-side scalar changes applied — no other data lost.
@Suite("Two-way sync: property test")
struct SyncPropertyTests {
    struct Person {
        var slug: String
        var path: String
        var cards: [String]
    }

    /// With `scripted`, the store has no notes entitlement and notes go
    /// through a `FakeNotesProvider` (Contacts.app scripting), turned on
    /// after the first export: the first sync is the enablement migration.
    ///
    /// With `routed` (spike S15, architecture §6 "Write routing"), a random
    /// subset of cards has a note, the fake framework refuses every update
    /// of those cards (134092) and ignores group removals, and card writes
    /// go through a `CardWriteRouter` with (fake) Contacts.app scripting.
    static func world(
        stamps: Bool, notes: Bool, scripted: Bool = false, routed: SeededRandom? = nil
    ) throws -> (SyncHarness, [Person]) {
        var noted = routed
        var contacts: [AppleContact] = []
        var people: [Person] = []
        let names = ["Ada", "Ben", "Cleo", "Dov", "Eva", "Fin", "Gus"]
        for (index, given) in names.enumerated() {
            let slug = "c\(index)"
            let accounts: [AccountKind] =
                switch index {
                case 4: [.google]
                case 6: [.local]
                default: [.iCloud]
                }
            contacts.append(
                World.person(slug, given, "Test", accounts: accounts) { contact in
                    contact.emails = [Labeled("home", "\(given.lowercased())@home.example")]
                    contact.phones = [Labeled("mobile", "+1 415 555 01\(10 + index)")]
                    contact.jobTitle = "Start"
                    contact.body = noted == nil ? (notes ? "first line\nsecond line\n" : nil) : nil
                    if Self.coin(&noted) { contact.body = "note of \(given)\n" }
                })
            people.append(
                Person(slug: slug, path: "Inbox/\(given) Test.md", cards: ["\(slug):\(accounts[0].rawValue)"]))
        }
        var linked = linkedAnn()
        if notes { for index in linked.cards.indices { linked.cards[index].values?.body = "first line\n" } }
        contacts.append(linked)
        people.append(Person(slug: "ann", path: "Inbox/Ann One.md", cards: ["ann:icloud", "ann:google"]))
        if Self.coin(&noted), let index = contacts.indices.last {
            contacts[index].cards[1].values?.body = "linked note\n"
        }
        let world = SyncHarness(
            contacts: contacts, notesEntitled: notes && !scripted && routed == nil, appleWrites: true,
            stampContacts: stamps)
        world.store.setSynthesizeLinkedIDs(true)
        world.store.setNormalizePhonesOnSave(true)
        try world.export()
        if routed != nil {
            world.store.setModelsFrameworkWithoutNotesEntitlement(true)
            world.enableCardWriteRouting(FakeCardScripting(store: world.store))
        }
        if scripted { world.enableScriptedNotes(FakeNotesProvider(store: world.store), bulkThreshold: 3) }
        try world.sync(Self.options)
        return (world, people)
    }

    /// A coin toss from `random` (`false` without one).
    static func coin(_ random: inout SeededRandom?) -> Bool {
        guard var generator = random else { return false }
        defer { random = generator }
        return Bool.random(using: &generator)
    }

    static let options = SyncOptions(maxAppleChanges: 1000)

    /// Key sets per field of one side.
    struct Keys: Equatable {
        var emails: Set<String>
        var phones: Set<String>
        var jobTitle: String?
        var body: String?
    }

    static func keys(_ contact: CanonicalContact, keyer: any PhoneKeyer) -> Keys {
        Keys(
            emails: Set(contact.emails.map { ComparisonKeys.email($0.value) }),
            phones: Set(contact.phones.map { ComparisonKeys.phone($0.value, keyer: keyer) }),
            jobTitle: contact.jobTitle, body: contact.body.map { ComparisonKeys.body($0) })
    }

    static func appleKeys(_ world: SyncHarness, _ person: Person) -> Keys? {
        World.apple(world, person.cards[0]).map { keys($0, keyer: world.keyer) }
    }

    static func noteKeys(_ world: SyncHarness, _ person: Person) -> Keys? {
        (try? world.note(person.path)).flatMap { $0 }.map { keys($0, keyer: world.keyer) }
    }

    /// Random edits with a running token counter (unique new values).
    struct Mutator {
        var random: SeededRandom
        var counter = 0
        let notes: Bool

        /// One random change to a contact's values.
        mutating func change() -> (inout CanonicalContact) -> Void {
            counter += 1
            let token = counter
            let operation = Int.random(in: 0..<(notes ? 7 : 6), using: &random)
            let pick = Int.random(in: 0..<1000, using: &random)
            return { contact in Self.apply(operation, token: token, pick: pick, to: &contact) }
        }

        static func apply(_ operation: Int, token: Int, pick: Int, to contact: inout CanonicalContact) {
            switch operation {
            case 0: contact.emails.append(Labeled("work", "new\(token)@x.example"))
            case 1: if !contact.emails.isEmpty { contact.emails.remove(at: pick % contact.emails.count) }
            case 2: contact.jobTitle = "Title \(token)"
            case 3: contact.phones.append(Labeled("work", "+1 212 555 \(String(format: "%04d", token % 10_000))"))
            case 4: if !contact.phones.isEmpty { contact.phones.removeLast() }
            case 5:
                if !contact.emails.isEmpty {
                    contact.emails[pick % contact.emails.count].label = ["home", "work", "other", "school"][pick % 4]
                }
            default: contact.body = (contact.body ?? "") + "added \(token)\n"
            }
        }

        /// One random edit on one side of one random person.
        mutating func edit(_ world: SyncHarness, _ people: [Person]) throws {
            let person = people[Int.random(in: 0..<people.count, using: &random)]
            let change = change()
            if Bool.random(using: &random) {
                let card = person.cards[Int.random(in: 0..<person.cards.count, using: &random)]
                world.store.editCard(card) { change(&$0) }
            } else {
                try world.editNote(person.path) { change(&$0) }
            }
        }
    }

    /// Counters that keep the test from passing vacuously.
    struct Totals {
        var scripted = 0
        var apple = 0
        var markdown = 0
        var conflicts = 0
        var resolved = 0
    }

    @Test(
        "random edits on both sides × rounds → one sync reaches a fixpoint, no duplicates, no data loss",
        arguments: [(false, false), (true, false), (false, true), (true, true)])
    func randomRounds(stamps: Bool, notes: Bool) throws {
        try Self.rounds(stamps: stamps, notes: notes, scripted: false)
    }

    @Test(
        "notes through Contacts.app scripting: random edits → fixpoint, no duplicates, no data loss",
        arguments: [false, true])
    func randomRoundsScripted(stamps: Bool) throws {
        try Self.rounds(stamps: stamps, notes: true, scripted: true)
    }

    @Test(
        "cards with notes routed through Contacts.app (S15): random edits → fixpoint, nothing refused, notes intact",
        arguments: [false, true])
    func randomRoundsRouted(scriptedNotes: Bool) throws {
        try Self.rounds(stamps: false, notes: scriptedNotes, scripted: scriptedNotes, routed: true)
    }

    static func rounds(stamps: Bool, notes: Bool, scripted: Bool, routed: Bool = false) throws {
        var totals = Totals()
        for seed in UInt64(1)...4 {
            let salt: UInt64 = (stamps ? 1 : 0) &+ (notes ? 2 : 0) &+ (scripted ? 4 : 0) &+ (routed ? 8 : 0)
            var mutator = Mutator(random: SeededRandom(seed: seed &* 7919 &+ salt), notes: notes)
            let (world, people) = try Self.world(
                stamps: stamps, notes: notes, scripted: scripted,
                routed: routed ? SeededRandom(seed: seed &* 104_729) : nil)
            let contactCount = world.store.contacts.count
            let notesBefore = world.store.scriptedNotes()
            var pending = Set<String>()
            for round in 0..<10 {
                let context = "seed \(seed) round \(round) stamps \(stamps) notes \(notes) scripted \(scripted)"
                let before = Dictionary(uniqueKeysWithValues: people.map { ($0.slug, Self.appleKeys(world, $0)) })
                for _ in 0..<Int.random(in: 3...12, using: &mutator.random) { try mutator.edit(world, people) }
                let edited = Dictionary(
                    uniqueKeysWithValues: people.map {
                        ($0.slug, Sides(apple: Self.appleKeys(world, $0), markdown: Self.noteKeys(world, $0)))
                    })
                let run = try world.sync(Self.options)
                if routed {
                    #expect(run.result?.appleFailures == [], "\(context)")
                    #expect(run.result?.appleHeld == [], "\(context)")
                    #expect(world.store.rejectedForNote.isEmpty, "\(context): a noted card was sent to the framework")
                    if !notes { #expect(world.store.scriptedNotes() == notesBefore, "\(context): notes changed") }
                }
                totals.apple += run.result?.apple.count ?? 0
                totals.scripted += run.result.map { _ in world.store.scriptedOperations.count } ?? 0
                totals.markdown += run.result?.markdown.updated.count ?? 0
                totals.conflicts += run.plan.conflicts.count
                try Self.checkInvariants(world, people, contactCount: contactCount, context: context)
                let conflicted = Set(run.plan.conflicts.map { "\($0.recordID)|\($0.field)" }).union(pending)
                try Self.checkThreeWay(
                    world, people, round: Round(before: before, edited: edited, conflicted: conflicted, notes: notes),
                    context: context)
                pending = try Self.resolveSome(run.plan.conflicts, world, &mutator.random, &totals)
                world.advance(minutes: 3)
            }
        }
        #expect(totals.apple > 10 && totals.markdown > 10, "\(totals)")
        if routed { #expect(totals.scripted > 10, "\(totals)") }
        #expect(totals.conflicts > 0 && totals.resolved > 0, "\(totals)")
    }

    struct Sides {
        var apple: Keys?
        var markdown: Keys?
    }

    struct Round {
        var before: [String: Keys?]
        var edited: [String: Sides]
        /// `record|field` with a conflict this round or open from the last.
        var conflicted: Set<String>
        var notes: Bool
    }

    /// Fixpoint, no unified saves, no duplicate notes or contacts.
    static func checkInvariants(
        _ world: SyncHarness, _ people: [Person], contactCount: Int, context: String
    ) throws {
        let again = try world.plan(options).plan
        #expect(
            again.apple.isEmpty && again.markdown.updates.isEmpty && again.markdown.creates.isEmpty,
            "no fixpoint (\(context)): \(again.apple.map(\.fields))")
        #expect(world.store.unifiedSaveCount == 0, "\(context)")
        #expect(world.store.contacts.count == contactCount, "\(context)")
        let ids = try world.notePaths.compactMap { try world.note($0)?.sync.id }
        #expect(ids.count == people.count && Set(ids).count == ids.count, "\(context): \(world.notePaths)")
    }

    /// Outside conflicts, both sides hold the three-way result of the round:
    /// start ∪ additions − deletions; scalars and bodies agree.
    static func checkThreeWay(_ world: SyncHarness, _ people: [Person], round: Round, context: String) throws {
        for person in people {
            guard let recordID = try world.note(person.path)?.sync.id,
                let base = round.before[person.slug].flatMap({ $0 }),
                let edited = round.edited[person.slug], let appleNow = appleKeys(world, person),
                let noteNow = noteKeys(world, person)
            else {
                Issue.record("\(context): \(person.slug) lost")
                continue
            }
            let clean = { (field: String) in !round.conflicted.contains("\(recordID)|\(field)") }
            for (field, path) in [("emails", \Keys.emails), ("phones", \Keys.phones)] {
                guard clean(field), let apple = edited.apple?[keyPath: path],
                    let markdown = edited.markdown?[keyPath: path]
                else { continue }
                let start = base[keyPath: path]
                let expected = start.union(apple).union(markdown)
                    .subtracting(start.subtracting(apple)).subtracting(start.subtracting(markdown))
                #expect(appleNow[keyPath: path] == expected, "\(context) \(person.slug) apple \(field)")
                #expect(noteNow[keyPath: path] == expected, "\(context) \(person.slug) note \(field)")
            }
            if clean("job_title") { #expect(appleNow.jobTitle == noteNow.jobTitle, "\(context) \(person.slug)") }
            if round.notes, clean("body") { #expect(appleNow.body == noteNow.body, "\(context) \(person.slug)") }
        }
    }

    /// Resolves about half of the conflicts; returns all of them as still
    /// open for the next round's checks.
    static func resolveSome(
        _ conflicts: [SyncConflict], _ world: SyncHarness, _ random: inout SeededRandom, _ totals: inout Totals
    ) throws -> Set<String> {
        for conflict in conflicts where Bool.random(using: &random) {
            let choice = conflict.options.randomElement(using: &random) ?? .keepApple
            try world.decide(conflict.id, choice.rawValue)
            totals.resolved += 1
        }
        return Set(conflicts.map { "\($0.recordID)|\($0.field)" })
    }
}
