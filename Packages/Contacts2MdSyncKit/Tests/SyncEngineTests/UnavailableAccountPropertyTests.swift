import ContactModel
import Foundation
import SyncTestSupport
import Testing

@testable import SyncEngine

/// Random edits on both sides while the Google account is turned off and
/// back on (with new card ids) at random moments: no run trips the breaker,
/// no note is created, deleted or duplicated, the values only Google holds
/// never leave the notes, every round reaches a fixpoint, and once Google is
/// back every edit made on either side meanwhile is on both sides.
@Suite("Unavailable accounts: property test")
struct UnavailableAccountPropertyTests {
    static let options = SyncOptions(maxAppleChanges: 1000)

    @Test("Google off and on during random edits never loses or duplicates anything", arguments: [false, true])
    func randomToggles(stamps: Bool) throws {
        for seed in UInt64(1)...6 {
            try World.$stampMode.withValue(stamps) { try run(seed: seed) }
        }
    }

    private func run(seed: UInt64) throws {
        var random = SeededRandom(seed: seed)
        let world = try World.exported([AccountWorld.sam(), World.ann()] + AccountWorld.ginas(12))
        let paths = world.notePaths
        let records = try world.state.load().records.count
        var removed: RemovedContainer?
        var generation = 0
        var addedEmails: [String: Set<String>] = [:]
        for round in 0..<12 {
            switch Int.random(in: 0..<4, using: &random) {
            case 0:
                if let gone = removed {
                    generation += 1
                    let suffix = "~g\(generation)"
                    world.store.restoreContainer(gone, cardID: { $0.split(separator: "~")[0] + suffix })
                    removed = nil
                } else {
                    removed = world.store.removeContainer("google")
                }
            case 1:
                world.store.editCard("sam:icloud") { $0.jobTitle = "Job \(seed)-\(round)" }
            default:
                let path = paths[Int.random(in: 0..<paths.count, using: &random)]
                let email = "m\(seed)-\(round)@x.example"
                try world.editNote(path) { $0.emails.append(Labeled("other", email)) }
                addedEmails[path, default: []].insert(email)
            }
            try checkRound(world, paths: paths, records: records, added: addedEmails, at: "seed \(seed) round \(round)")
        }
        if let removed { world.store.restoreContainer(removed, cardID: { $0 + "~end" }) }
        try world.sync(Self.options)
        #expect(try world.sync(Self.options).plan.isEmpty, "seed \(seed): no fixpoint after return")
        #expect(try world.pending("deleted").isEmpty)
        #expect(world.store.unifiedSaveCount == 0)
        #expect(AccountGuard.load(from: world.state)?.unavailable.isEmpty == true)
        for (path, emails) in addedEmails {
            let note = try #require(try world.note(path))
            let contact = world.store.contacts.first { contact in
                TitleGenerator.title(for: contact.cardMergedContact(keyer: world.keyer)) == note.title
            }
            let apple = Set(contact?.cardMergedContact(keyer: world.keyer).emails.map(\.value) ?? [])
            #expect(emails.isSubset(of: apple), "seed \(seed): \(path) emails not in Contacts after return")
        }
    }

    /// One round's sync and its invariants.
    private func checkRound(
        _ world: SyncHarness, paths: [String], records: Int, added: [String: Set<String>], at label: String
    ) throws {
        let sync = try world.sync(Self.options)
        #expect(sync.plan.breaker == nil, "\(label)")
        #expect(sync.plan.markdown.creates.isEmpty, "\(label)")
        #expect(sync.plan.trash.isEmpty)
        #expect(sync.plan.conflicts.isEmpty, "\(label): \(sync.plan.conflicts.map(\.summary))")
        #expect(try world.sync(Self.options).plan.isEmpty, "\(label): no fixpoint")
        #expect(world.notePaths == paths)
        #expect(try world.state.load().records.count == records)
        let sam = try world.note("Inbox/Sam Lee.md")
        #expect(sam?.phones.map(\.value) == ["+1 415 555 0142"], "\(label)")
        #expect(sam?.urls.map(\.value) == ["https://sam.example"])
        for (path, emails) in added {
            let note = Set(try world.note(path)?.emails.map(\.value) ?? [])
            #expect(emails.isSubset(of: note), "\(label): \(path)")
        }
    }
}
