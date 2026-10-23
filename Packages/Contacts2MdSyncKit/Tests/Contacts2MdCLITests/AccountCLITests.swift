import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// A linked iCloud + Google contact and two Google-only ones.
private func accountStore() -> FakeContactStore {
    func person(
        _ given: String, _ family: String, _ build: (inout CanonicalContact) -> Void = { _ in }
    )
        -> CanonicalContact
    {
        var contact = CanonicalContact(kind: .person, title: "")
        contact.name = PersonName(given: given, family: family)
        build(&contact)
        return contact
    }
    let sam = Fixtures.linked(
        "sam",
        [
            (.iCloud, person("Sam", "Lee") { $0.emails = [Labeled("home", "sam@home.example")] }),
            (.google, person("Sam", "Lee") { $0.phones = [Labeled("mobile", "+1 415 555 0142")] }),
        ])
    let ginas = ["A", "B"].map { letter in
        Fixtures.linked(
            "g\(letter)",
            [(.google, person("Gina", "Google\(letter)") { $0.emails = [Labeled("home", "g\(letter)@x.example")] })])
    }
    return FakeContactStore(contacts: [sam] + ginas, containers: Fixtures.containers, groups: Fixtures.groups)
}

@Suite("contacts2md and unavailable accounts")
struct AccountCLITests {
    @Test("sync with Google off: WARNING account, nothing removed, exit 0; status and review list explain it")
    func missingAccount() throws {
        let harness = CLIHarness.exported(accountStore())
        #expect(harness.sync().code == 0)
        let before = harness.vault.text("Inbox/Sam Lee.md")
        harness.store.removeContainer("google")
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        let lines = harness.lines(run)
        #expect(
            lines.contains {
                $0.hasPrefix(
                    "WARNING  account    Google (\"Google\", 3 cards) is not visible in Contacts; "
                        + "its cards are kept as last seen")
                    && $0.contains("(2 contacts only there, 1 linked)")
                    && $0.hasSuffix("`review decide account-missing:google forget` [account-missing:google]")
            }, "\(run.out)")
        #expect(harness.vault.text("Inbox/Sam Lee.md") == before)
        #expect(!run.out.contains("updated  md"))

        let status = harness.run(["status", "--root", "/vault"])
        #expect(
            harness.lines(status).contains {
                $0.hasPrefix("account  MISSING  Google \"Google\" (3 cards, last seen ")
                    && $0.contains("kept as last seen")
            }, "\(status.out)")

        let list = harness.run(["review", "list", "--root", "/vault"])
        #expect(list.out.contains("item     account-missing:google  Google (\"Google\", 3 cards) is not visible"))
        #expect(list.out.contains("queue 2 contacts only in this account as deleted"))
        #expect(list.out.contains("Inbox/Sam Lee.md: phones: +1 415 555 0142"))
        #expect(list.out.contains("choices: wait | forget"))
        #expect(list.code == 0)
    }

    @Test("review decide account-missing:<id> forget: the next sync removes what only Google held, queues the rest")
    func forget() throws {
        let harness = CLIHarness.exported(accountStore())
        #expect(harness.sync().code == 0)
        harness.store.removeContainer("google")
        #expect(harness.sync().code == 0)
        let decide = harness.run(["review", "decide", "account-missing:google", "forget", "--root", "/vault"])
        #expect(decide.code == 0, "\(decide.out)\(decide.err)")
        let run = harness.sync()
        #expect(run.code == 1, "\(run.out)\(run.err)")  // the queued deletions need a decision
        #expect(run.out.contains("updated  md     Inbox/Sam Lee.md  (phones)"))
        #expect(harness.lines(run).filter { $0.hasPrefix("WARNING  delete") }.count == 2)
        #expect(!run.out.contains("WARNING  account"))
        #expect(harness.vault.text("Inbox/Gina GoogleA.md") != nil)
    }

    @Test("a one-way export while Google is off keeps the Google-only values and leaves frozen notes alone")
    func exportWhileMissing() throws {
        let harness = CLIHarness.exported(accountStore())
        #expect(harness.sync().code == 0)
        let before = ["Inbox/Sam Lee.md", "Inbox/Gina GoogleA.md"].map { harness.vault.text($0) }
        harness.store.removeContainer("google")
        let export = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(export.code == 0, "\(export.out)\(export.err)")
        #expect(["Inbox/Sam Lee.md", "Inbox/Gina GoogleA.md"].map { harness.vault.text($0) } == before)
    }

    @Test("Overview banner and Activity: Keep Waiting / Forget data, then forget recorded from the app")
    func overviewBanner() throws {
        let harness = CLIHarness.exported(accountStore())
        #expect(harness.sync().code == 0)
        harness.store.removeContainer("google")
        #expect(harness.sync().code == 0)
        let reader = UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
        let data = try #require(try reader.read())
        let counts = UIReviewQueues(data: data).counts
        let overview = UIOverview(data: data, plan: nil, counts: counts, sessionStart: .distantPast)
        let banner = try #require(overview.accounts.first)
        #expect(banner.text == "Google account isn't visible in Contacts — 3 cards kept as last seen")
        #expect(banner.itemID == "account-missing:google")
        #expect(!banner.isReturning)
        #expect(banner.preview?.frozenTitles == ["Gina GoogleA", "Gina GoogleB"])
        #expect(banner.preview?.removals.map(\.path) == ["Inbox/Sam Lee.md"])
        #expect(overview.health == .inSync)
        let rows = UIActivityRow.rows(data.sessions, device: data.device)
        #expect(rows.first?.accounts == banner.text)
        try reader.record([.choice(itemID: banner.itemID, choice: "forget")])
        let decided = try #require(try reader.read())
        let after = UIOverview(
            data: decided, plan: nil, counts: UIReviewQueues(data: decided).counts, sessionStart: .distantPast)
        #expect(after.accounts.first?.forgetPending == true)
    }
}
