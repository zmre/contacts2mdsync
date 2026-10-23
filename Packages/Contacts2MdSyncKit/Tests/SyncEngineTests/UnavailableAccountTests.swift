import ContactModel
import Foundation
import SyncTestSupport
import Testing
import VaultIndex

@testable import SyncEngine

/// Contacts for the unavailable-accounts scenarios: a linked iCloud + Google
/// pair whose Google card holds values the iCloud card lacks, and
/// Google-only contacts.
enum AccountWorld {
    static func name(_ given: String, _ family: String) -> CanonicalContact {
        var contact = CanonicalContact(kind: .person, title: "")
        contact.name = PersonName(given: given, family: family)
        return contact
    }

    /// Sam Lee: iCloud has the home email and the job title; Google also
    /// has a work email, a phone and a URL (values only Google holds).
    static func sam(googleNote: String? = nil) -> AppleContact {
        var icloud = name("Sam", "Lee")
        icloud.emails = [Labeled("home", "sam@home.example")]
        icloud.jobTitle = "Chef"
        var google = name("Sam", "Lee")
        google.emails = [Labeled("home", "sam@home.example"), Labeled("work", "sam@work.example")]
        google.phones = [Labeled("mobile", "+1 415 555 0142")]
        google.urls = [Labeled("homepage", "https://sam.example")]
        google.body = googleNote
        return Fixtures.linked("sam", [(.iCloud, icloud), (.google, google)])
    }

    /// Google-only contacts `g01`…: Gina GoogleA, Gina GoogleB, … each with an email.
    static func ginas(_ count: Int) -> [AppleContact] {
        (1...count).map { index in
            let letter = String(UnicodeScalar(UInt8(64 + index)))
            var values = name("Gina", "Google\(letter)")
            values.emails = [Labeled("home", "gina.\(letter.lowercased())@gmail.example")]
            values.jobTitle = "Pilot \(letter)"
            return Fixtures.linked(String(format: "g%02d", index), [(.google, values)])
        }
    }

    static func ginaPath(_ index: Int) -> String {
        "Inbox/Gina Google\(String(UnicodeScalar(UInt8(64 + index)))).md"
    }

    /// Every note's text (contact notes only).
    static func notes(_ world: SyncHarness) -> [String: String] {
        Dictionary(uniqueKeysWithValues: world.notePaths.map { ($0, world.vault.text($0) ?? "") })
    }

    static func review(_ world: SyncHarness) throws -> AccountMissingReview? {
        for item in try world.pending("account") {
            if case .accountMissing(let review) = item { return review }
        }
        return nil
    }
}

@Suite("Unavailable accounts: Google turned off")
struct UnavailableAccountTests {
    @Test("a linked pair losing its Google card keeps the Google-only values in markdown", arguments: [false, true])
    func linkedPairKeepsValues(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([AccountWorld.sam(), World.ann()] + AccountWorld.ginas(3))
            let before = AccountWorld.notes(world)
            #expect(try world.note("Inbox/Sam Lee.md")?.phones.map(\.value) == ["+1 415 555 0142"])
            world.store.removeContainer("google")
            world.vault.resetWrites()
            let run = try world.sync()
            #expect(run.plan.breaker == nil)
            #expect(run.result != nil)
            #expect(AccountWorld.notes(world) == before)
            #expect(world.vault.writes.filter { !$0.hasPrefix(".") }.isEmpty)
            #expect(run.plan.apple.isEmpty)
            #expect(run.plan.accounts.map(\.frozenRecords) == [3])
            #expect(run.plan.accounts.map(\.linkedRecords) == [1])
            #expect(
                run.plan.accounts.first?.message.hasPrefix(
                    "Google (\"Google\", 4 cards) is not visible in Contacts; its cards are kept as last seen") == true)
            #expect(!run.plan.needsReview)
            #expect(try AccountWorld.review(world)?.containerID == "google")

            // The surviving iCloud card still syncs normally.
            world.store.editCard("sam:icloud") { $0.jobTitle = "Head Chef" }
            try world.sync()
            let sam = try world.note("Inbox/Sam Lee.md")
            #expect(sam?.jobTitle == "Head Chef")
            #expect(sam?.phones.map(\.value) == ["+1 415 555 0142"])
            #expect(sam?.emails.map(\.value) == ["sam@home.example", "sam@work.example"])
            #expect(sam?.urls.map(\.value) == ["https://sam.example"])
            #expect(try world.sync().plan.isEmpty)
            world.advance(minutes: 30)
            #expect(try world.sync(mode: .full).plan.isEmpty)
            #expect(try world.pending("deleted").isEmpty)
            #expect(try world.state.loadVanished().isEmpty)
            #expect(world.store.unifiedSaveCount == 0)
        }
    }

    @Test("Google-only contacts are frozen: no breaker, no delete queue, no writes", arguments: [false, true])
    func googleOnlyFrozen(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()] + AccountWorld.ginas(12))
            let before = AccountWorld.notes(world)
            world.store.removeContainer("google")
            let run = try world.sync()
            #expect(run.plan.breaker == nil)
            #expect(run.plan.accounts.map(\.frozenRecords) == [12])
            #expect(run.plan.markdown.skipped.isEmpty)
            world.advance(minutes: 15)
            let later = try world.sync(mode: .full)
            #expect(later.plan.breaker == nil)
            #expect(later.plan.trash.isEmpty)
            #expect(try world.pending("deleted").isEmpty)
            #expect(try world.state.loadVanished().isEmpty)
            #expect(AccountWorld.notes(world) == before)
            #expect(try world.state.load().records.count == 13)
        }
    }

    @Test("history: the account's deletions route the run to a full snapshot; later runs stay incremental")
    func incrementalGoesFull() throws {
        let world = try World.exported([AccountWorld.sam()] + AccountWorld.ginas(2), stamps: .never)
        #expect(try world.sync().apple?.kind.isFull == false)
        world.store.removeContainer("google")
        let run = try world.sync()
        #expect(run.apple?.kind.isFull == true)
        #expect(run.plan.accounts.count == 1)
        let next = try world.sync()
        #expect(next.apple?.kind == .incremental(changedCards: 0, refetchedContacts: 0))
        #expect(next.plan.isEmpty)
        #expect(next.plan.accounts.count == 1)
    }

    @Test("a dry run that first sees the account missing keeps its cards for later runs")
    func dryRunRemembers() throws {
        let world = try World.exported([AccountWorld.sam()] + AccountWorld.ginas(2), stamps: .never)
        let before = AccountWorld.notes(world)
        world.store.removeContainer("google")
        let planned = try world.plan().plan
        #expect(planned.markdown.updates.isEmpty)
        #expect(planned.accounts.count == 1)
        // The mirror advanced without Google; the frozen cards were stored.
        let run = try world.sync()
        #expect(run.plan.isEmpty)
        #expect(AccountWorld.notes(world) == before)
    }

    @Test("Google comes back with new ids: re-bound, nothing created, nothing changed", arguments: [false, true])
    func returnsWithNewIDs(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([AccountWorld.sam(), World.ann()] + AccountWorld.ginas(12))
            let before = AccountWorld.notes(world)
            let removed = world.store.removeContainer("google")
            try world.sync()
            world.store.restoreContainer(removed, containerID: "google-2", cardID: { $0 + "~back" })
            world.vault.resetWrites()
            let back = try world.sync()
            #expect(back.apple?.kind == .full(.accountsChanged))
            #expect(back.plan.breaker == nil)
            #expect(back.plan.markdown.creates.isEmpty)
            #expect(back.plan.markdown.updates.isEmpty, "\(back.plan.markdown.updates.map(\.path))")
            #expect(back.plan.apple.isEmpty, "\(back.plan.apple.map(\.title))")
            #expect(back.plan.markdown.reviews.filter(\.needsDecision).isEmpty)
            #expect(AccountWorld.notes(world) == before)
            #expect(AccountGuard.load(from: world.state)?.unavailable.isEmpty == true)
            let cards = try world.state.load().records.values.flatMap(\.cards).map(\.id)
            #expect(cards.contains("g01:google~back"))
            #expect(cards.contains("sam:google~back"))
            #expect(!cards.contains("g01:google"))
            let next = try world.sync(mode: .full)
            #expect(next.plan.isEmpty)
            #expect(next.plan.accounts.isEmpty)
            #expect(world.store.unifiedSaveCount == 0)
        }
    }

    @Test("Google comes back with edits made there while away: merged as usual")
    func returnsWithEdits() throws {
        let world = try World.exported([AccountWorld.sam()] + AccountWorld.ginas(2), stamps: .never)
        let removed = world.store.removeContainer("google")
        try world.sync()
        world.store.restoreContainer(removed, cardID: { $0 + "~back" })
        world.store.editCard("g01:google~back") { $0.jobTitle = "Captain" }
        world.store.editCard("sam:google~back") { $0.phones = [Labeled("mobile", "+1 415 555 0199")] }
        let back = try world.sync()
        #expect(back.plan.conflicts.isEmpty)
        #expect(back.plan.markdown.creates.isEmpty)
        #expect(try world.note(AccountWorld.ginaPath(1))?.jobTitle == "Captain")
        #expect(try world.note("Inbox/Sam Lee.md")?.phones.map(\.value) == ["+1 415 555 0199"])
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("a contact that comes back before Contacts links it again is held, not a duplicate")
    func returnsUnlinked() throws {
        let world = try World.exported([AccountWorld.sam()], stamps: .never)
        let before = AccountWorld.notes(world)
        let removed = world.store.removeContainer("google")
        try world.sync()
        world.store.restoreContainer(removed, cardID: { $0 + "~back" }, link: false)
        let back = try world.sync()
        #expect(back.plan.markdown.creates.isEmpty)
        #expect(back.plan.markdown.reviews.isEmpty, "\(back.plan.markdown.reviews.map(\.summary))")
        #expect(AccountWorld.notes(world) == before)
        // Contacts links them a few minutes later: resolved.
        guard let google = world.store.contact(withCard: "sam:google~back")?.unifiedID,
            let icloud = world.store.contact(withCard: "sam:icloud")?.unifiedID
        else { throw HarnessFailure("contacts missing") }
        world.store.link([icloud, google])
        let linked = try world.sync(mode: .full)
        #expect(linked.plan.isEmpty)
        #expect(linked.plan.accounts.isEmpty)
        #expect(AccountWorld.notes(world) == before)
    }
}
