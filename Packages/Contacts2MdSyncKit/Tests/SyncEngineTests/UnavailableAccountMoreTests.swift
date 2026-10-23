import ContactModel
import Foundation
import MarkdownCodec
import SyncTestSupport
import Testing
import VaultIndex

@testable import SyncEngine

@Suite("Unavailable accounts: forget, partial state, other accounts, held writes")
struct UnavailableAccountMoreTests {
    @Test("renamed on Google while away: matched by email + compatible name to its frozen card, not a review")
    func returnsRenamed() throws {
        let world = try World.exported(AccountWorld.ginas(2), stamps: .never)
        let removed = world.store.removeContainer("google")
        try world.sync()
        world.store.restoreContainer(removed, cardID: { $0 + "~back" })
        world.store.editCard("g01:google~back") { $0.name.family = "GoogleA-Smith" }
        let back = try world.sync()
        #expect(
            back.plan.markdown.reviews.filter(\.needsDecision).isEmpty, "\(back.plan.markdown.reviews.map(\.summary))")
        #expect(back.plan.markdown.creates.isEmpty)
        #expect(try world.note(AccountWorld.ginaPath(1))?.name.family == "GoogleA-Smith")
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("forget: the plan shows the removals, which happen only after the decision", arguments: [false, true])
    func forget(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([AccountWorld.sam(), World.ann()] + AccountWorld.ginas(12))
            world.store.removeContainer("google")
            try world.sync()
            let review = try #require(try AccountWorld.review(world))
            #expect(review.frozenTitles.count == 12)
            #expect(review.removals.map(\.path) == ["Inbox/Sam Lee.md"])
            #expect(
                review.removals.first?.values.sorted()
                    == ["emails: sam@work.example", "phones: +1 415 555 0142", "urls: https://sam.example"])
            #expect(review.forgetPreview.first?.hasPrefix("queue 12 contacts only in this account as deleted") == true)
            #expect(try world.note("Inbox/Sam Lee.md")?.phones.count == 1)

            try world.decide("account-missing:google", "forget")
            let planned = try world.plan().plan
            #expect(planned.breaker == nil)
            #expect(planned.markdown.updates.map(\.path) == ["Inbox/Sam Lee.md"])
            #expect(planned.markdown.reviews.filter { $0.id.hasPrefix("deleted-") }.count == 12)
            #expect(planned.accounts.isEmpty)
            #expect(try world.note("Inbox/Sam Lee.md")?.phones.count == 1)  // a plan writes nothing

            let run = try world.sync()
            #expect(run.plan.breaker == nil)
            #expect(run.plan.trash.isEmpty)
            let sam = try world.note("Inbox/Sam Lee.md")
            #expect(sam?.phones.isEmpty == true)
            #expect(sam?.urls.isEmpty == true)
            #expect(sam?.emails.map(\.value) == ["sam@home.example"])
            #expect(try world.pending("deleted").count == 12)
            #expect(world.vault.exists(AccountWorld.ginaPath(1)))
            let stored = AccountGuard.load(from: world.state)
            #expect(stored?.unavailable.isEmpty == true)
            #expect(stored?.containers.contains { $0.id == "google" } == false)
            let next = try world.sync()
            #expect(next.plan.accounts.isEmpty)
            #expect(next.plan.breaker == nil)
            #expect(next.plan.markdown.updates.isEmpty)
        }
    }

    @Test("an account in a partial state (cards collapsed to a few) is unavailable, not a mass delete")
    func partialState() throws {
        let world = try World.exported(AccountWorld.ginas(25), stamps: .never)
        let before = AccountWorld.notes(world)
        world.store.collapseContainer("google", keeping: 1)
        let run = try world.sync()
        #expect(run.plan.breaker == nil)
        #expect(run.plan.accounts.first?.account.reason == .collapsed)
        #expect(run.plan.accounts.first?.frozenRecords == 25)
        world.advance(minutes: 15)
        try world.sync(mode: .full)
        #expect(try world.pending("deleted").isEmpty)
        #expect(AccountWorld.notes(world) == before)
    }

    @Test("iCloud missing: same rail, a stronger message; groups and tags kept; writes to the linked Google card held")
    func iCloudMissing() throws {
        var ann = World.ann()
        ann.groupIDs = [Fixtures.family.id]
        let world = try World.exported([AccountWorld.sam(), ann] + AccountWorld.ginas(2), stamps: .never)
        #expect(try world.note("Inbox/Ann One.md")?.tags.contains("family") == true)
        let before = AccountWorld.notes(world)
        let config = world.vault.text(VaultConfig.path)
        world.store.removeContainer("icloud")
        let run = try world.sync()
        #expect(run.plan.breaker == nil)
        #expect(run.plan.accounts.first?.account.kind == .iCloud)
        #expect(run.plan.accounts.first?.hint.contains("This is your iCloud account") == true)
        #expect(AccountWorld.notes(world) == before)
        #expect(world.vault.text(VaultConfig.path) == config)
        try world.editNote("Inbox/Sam Lee.md") { $0.jobTitle = "Owner" }
        let edited = try world.sync()
        #expect(edited.plan.apple.isEmpty)
        #expect(edited.plan.accountHeld.map(\.title) == ["Sam Lee"])
        #expect(world.store.values(ofCard: "sam:google")?.jobTitle == nil)
        #expect(try world.note("Inbox/Sam Lee.md")?.jobTitle == "Owner")
    }

    @Test("On My Mac container missing: frozen the same way")
    func localMissing() throws {
        let local = Fixtures.linked("loc", [(.local, AccountWorld.name("Lou", "Local"))])
        let world = try World.exported([local, World.ann()], stamps: .never)
        let before = AccountWorld.notes(world)
        world.store.removeContainer("local")
        let run = try world.sync()
        #expect(run.plan.accounts.first?.account.kind == .local)
        #expect(run.plan.accounts.first?.hint.contains("On My Mac") == true)
        world.advance(minutes: 15)
        try world.sync(mode: .full)
        #expect(try world.pending("deleted").isEmpty)
        #expect(AccountWorld.notes(world) == before)
    }

    @Test("a value only the missing card holds, deleted in markdown: held, never re-added, applied on return")
    func heldDeletion() throws {
        let world = try World.exported([AccountWorld.sam()], stamps: .never)
        let removed = world.store.removeContainer("google")
        try world.sync()
        try world.editNote("Inbox/Sam Lee.md") { $0.emails.removeAll { $0.value == "sam@work.example" } }
        let run = try world.sync()
        #expect(run.plan.apple.isEmpty)
        #expect(run.plan.accountHeld.first?.fields == ["emails"])
        #expect(try world.sync().plan.markdown.updates.isEmpty)
        #expect(try world.note("Inbox/Sam Lee.md")?.emails.map(\.value) == ["sam@home.example"])
        world.store.restoreContainer(removed, cardID: { $0 + "~back" })
        let back = try world.sync()
        #expect(back.plan.markdown.updates.isEmpty)
        #expect(world.store.values(ofCard: "sam:google~back")?.emails.map(\.value) == ["sam@home.example"])
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("note precedence: the Google card's note stays the body; a markdown edit to it is held, not flipped")
    func notesPrecedenceFrozen() throws {
        let world = try World.exported(
            [AccountWorld.sam(googleNote: "Met at Google I/O")], notes: true, stamps: .never)
        #expect(try world.note("Inbox/Sam Lee.md")?.body?.contains("Met at Google I/O") == true)
        let removed = world.store.removeContainer("google")
        let quiet = try world.sync()
        #expect(quiet.plan.isEmpty)
        try world.editNote("Inbox/Sam Lee.md") { $0.body = "Met at Google I/O\n\nNow runs a bakery.\n" }
        let run = try world.sync()
        #expect(run.plan.apple.isEmpty)
        #expect(run.plan.accountHeld.first?.fields == ["body"])
        #expect(world.store.values(ofCard: "sam:icloud")?.body == nil)
        #expect(try world.sync().plan.markdown.updates.isEmpty)
        world.store.restoreContainer(removed)
        let back = try world.sync()
        #expect(back.plan.apple.first?.fields == ["body"])
        #expect(world.store.values(ofCard: "sam:google")?.body?.contains("bakery") == true)
    }

    @Test("scripted notes: a missing card's note is unknown-safe (kept from the mirror, never read as empty)")
    func scriptedNotes() throws {
        let world = try World.exported([AccountWorld.sam(googleNote: "From Google")], stamps: .never)
        let provider = FakeNotesProvider(store: world.store)
        world.enableScriptedNotes(provider)
        try world.sync()
        #expect(try world.note("Inbox/Sam Lee.md")?.body?.contains("From Google") == true)
        world.store.removeContainer("google")
        let run = try world.sync()
        #expect(run.plan.markdown.updates.isEmpty)
        #expect(run.plan.apple.isEmpty)
        #expect(try world.note("Inbox/Sam Lee.md")?.body?.contains("From Google") == true)
    }
}

@Suite("Unavailable accounts: return grace period")
struct UnavailableAccountGraceTests {
    @Test("a returned contact nothing matches is held during the grace period, then the cascade decides: no duplicate")
    func unmatchedReturnHeld() throws {
        var values = AccountWorld.name("Pat", "Nokeys")
        values.jobTitle = "Pilot"
        let pat = Fixtures.linked("pat", [(.google, values)])
        let world = try World.exported([pat, World.ann()], stamps: .never)
        let removed = world.store.removeContainer("google")
        try world.sync()
        world.store.restoreContainer(removed, cardID: { $0 + "~back" })
        let back = try world.sync()
        #expect(back.plan.markdown.creates.isEmpty)
        #expect(back.plan.accounts.first?.isReturning == true)
        #expect(world.notePaths.count == 2)
        world.advance(minutes: 31)
        let after = try world.sync(mode: .full)
        #expect(after.plan.markdown.creates.isEmpty, "\(after.plan.markdown.creates.map(\.path))")
        #expect(world.notePaths.count == 2)
        #expect(after.plan.breaker == nil)
        try world.sync()
        #expect(try world.pending("deleted").isEmpty)
    }
}
