import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// A small address book (no duplicate clusters, so exit codes are clean).
func smallStore() -> FakeContactStore {
    let people = [("ann", "Ann", "One"), ("bob", "Bob", "Two"), ("cy", "Cy", "Three")].map { id, given, family in
        Fixtures.contact(id) { contact in
            contact.name = PersonName(given: given, family: family)
            contact.emails = [Labeled("home", "\(id)@example.com")]
            contact.jobTitle = "Engineer"
        }
    }
    return FakeContactStore(contacts: people, containers: Fixtures.containers, groups: Fixtures.groups)
}

extension CLIHarness {
    /// `export --yes` (the first import) on a small book.
    static func exported(_ store: FakeContactStore = smallStore()) -> CLIHarness {
        let harness = CLIHarness(store: store)
        let first = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(first.code == 0, "\(first.out)\(first.err)")
        return harness
    }

    func sync(_ extra: [String] = []) -> CLIRun { run(["sync", "--root", "/vault"] + extra) }

    func editNote(_ path: String, _ replace: String, with: String) {
        let text = vault.text(path) ?? ""
        vault.seed(path, Data(text.replacingOccurrences(of: replace, with: with).utf8))
    }

    var lines: (CLIRun) -> [String] { { $0.out.split(separator: "\n").map(String.init) } }
}

@Suite("contacts2md sync")
struct SyncCommandTests {
    @Test("before the first export: exit 3 on stderr")
    func notConfigured() {
        let run = CLIHarness(store: smallStore()).sync()
        #expect(run.code == 3)
        #expect(run.err.contains("not configured"))
    }

    @Test("apple_writes disabled (default): markdown synced, Apple changes held, exit 0, nothing written to Apple")
    func held() throws {
        let harness = CLIHarness.exported()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        let lines = harness.lines(run)
        #expect(lines.first?.hasPrefix("contacts2md sync  2027-01-15T08:00:00Z  device=Test Mac  root=/vault") == true)
        #expect(lines.contains("updated  md     Inbox/Bob Two.md  (job_title)"))
        #expect(lines.contains("held     apple  Ann One  (job_title) — apple writes disabled"))
        #expect(lines.contains { $0.hasPrefix("summary  apple c/u/d 0/0/0  md c/u/d 0/1/0") && $0.contains("held 1") })
        #expect(harness.store.appliedBatches.isEmpty)
        #expect(harness.backups.isEmpty)
    }

    @Test("config --apple-writes enabled, then sync: backup first, card written with the device author")
    func enabled() throws {
        let harness = CLIHarness.exported()
        let config = harness.run(["config", "--root", "/vault", "--apple-writes", "enabled"])
        #expect(config.code == 0)
        #expect(config.out.contains("config   apple_writes=enabled  stamp_contacts=false"))
        #expect(harness.vault.text(".c2mdsync/config.yaml")?.contains("apple_writes: enabled\n") == true)
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        let backup = try #require(run.out.range(of: "backup   apple  "))
        let updated = try #require(run.out.range(of: "updated  apple  Ann One  (job_title)"))
        #expect(backup.lowerBound < updated.lowerBound)
        #expect(harness.backups.count == 1)
        #expect(harness.store.appliedBatches.map(\.author) == ["com.zmre.contacts2mdsync.\(harness.device.id)"])
        // Second run: nothing to do.
        let again = harness.sync()
        #expect(again.code == 0 && !again.out.contains("updated "))
    }

    @Test("conflict: WARNING line, exit 1; review decide markdown; next sync applies it")
    func conflict() throws {
        let harness = CLIHarness.exported()
        _ = harness.run(["config", "--root", "/vault", "--apple-writes", "enabled"])
        _ = harness.sync()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: Markdown")
        harness.store.editCard("ann:icloud") { $0.jobTitle = "Contacts" }
        let run = harness.sync()
        #expect(run.code == 1)
        let warning = try #require(harness.lines(run).first { $0.hasPrefix("WARNING  conflict") })
        #expect(warning.contains("Ann One: job_title differs (Contacts \"Contacts\" vs Markdown \"Markdown\")"))
        let id = try #require(warning.split(separator: "[").last?.dropLast()).description
        let list = harness.run(["review", "list", "--root", "/vault"])
        #expect(list.out.contains("choices: apple | markdown"))
        #expect(harness.run(["review", "decide", id, "markdown", "--root", "/vault"]).code == 0)
        let resolved = harness.sync()
        #expect(resolved.code == 0, "\(resolved.out)")
        #expect(harness.store.contact(withCard: "ann:icloud")?.contact.jobTitle == "Markdown")
    }

    @Test("blast radius: exit 2, Apple writes skipped, markdown written; --max-apple-changes approves")
    func blastRadius() {
        let people = (1...27).map { number in
            Fixtures.contact("p\(number)") { $0.name = PersonName(given: "Person", family: "N\(number)") }
        }
        let harness = CLIHarness.exported(FakeContactStore(contacts: people, containers: Fixtures.containers))
        _ = harness.run(["config", "--root", "/vault", "--apple-writes", "enabled"])
        for number in 1...27 {
            let lastName = "last_name: N\(number)\n"
            harness.editNote("Inbox/Person N\(number).md", lastName, with: lastName + "job_title: Staff\n")
        }
        let run = harness.sync()
        #expect(run.code == 2, "\(run.out)")
        #expect(run.out.contains("WARNING  limit      27 Apple changes exceed the limit of 25"))
        #expect(harness.store.appliedBatches.isEmpty)
        let approved = harness.sync(["--max-apple-changes", "30"])
        #expect(approved.code == 0)
        #expect(harness.store.appliedOperations.count == 27)
    }

    @Test("mass-vanish breaker: exit 4, error on stderr, nothing written")
    func breaker() {
        let people = (1...12).map { number in
            Fixtures.contact("p\(number)") { $0.name = PersonName(given: "Person", family: "N\(number)") }
        }
        let harness = CLIHarness.exported(FakeContactStore(contacts: people, containers: Fixtures.containers))
        harness.store.replaceContacts([])
        harness.vault.resetWrites()
        let run = harness.sync()
        #expect(run.code == 4)
        #expect(run.err.contains("error    mass-vanish breaker: 12 of 12 synced records vanished from Contacts"))
        #expect(harness.vault.writes == [".c2mdsync/lease.json"])  // only the lease; no note, no config
    }

    @Test("another device holds the lease: no-op, exit 0; --take-over takes it")
    func lease() throws {
        let harness = CLIHarness.exported()
        let other = LeaseManager(
            fs: harness.vault, device: DeviceIdentity(id: "device-b", name: "Mac B"), clock: harness.clock, settle: 0)
        _ = try other.takeOver()  // the export made this Mac the leader
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let run = harness.sync()
        #expect(run.code == 0)
        #expect(run.out.contains("note     following Mac B: it leads syncing for this vault until"))
        #expect(run.out.contains("follow   leader still to do: apple 0 changes  md 0 new, 1 updates"))
        #expect(!(harness.vault.text("Inbox/Bob Two.md") ?? "").contains("Chef"))
        let taken = harness.sync(["--take-over"])
        #expect(taken.code == 0 && (harness.vault.text("Inbox/Bob Two.md") ?? "").contains("Chef"))
        let lease = LeaseManager(fs: harness.vault, device: harness.device, clock: harness.clock).read()
        #expect(lease?.deviceName == "Test Mac")
        // An expired lease is simply taken.
        harness.clock.advance(3600)
        _ = try other.acquire(otherDevicesKnown: true)
        harness.clock.advance(21 * 60)
        #expect(harness.sync().out.contains("leads syncing") == false)
    }

    @Test("a run already in progress on this Mac: no-op, exit 0")
    func localLock() throws {
        let harness = CLIHarness.exported()
        let vaultID = try #require(try VaultConfig.load(from: harness.vault)?.config.vaultID.uuidString.lowercased())
        let lock = try #require(
            try LocalLock.acquire(at: harness.stateDirectory.appending(path: "\(vaultID)/sync.lock"), wait: 0))
        let run = harness.sync()
        #expect(run.code == 0 && run.out.contains("another sync is running on this Mac"))
        lock.release()
        #expect(!harness.sync().out.contains("another sync is running"))
    }

    @Test("--json prints one document with items, reviews and the exit code")
    func json() throws {
        let harness = CLIHarness.exported()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let run = harness.sync(["--json"])
        #expect(run.code == 0)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.out.utf8)) as? [String: Any])
        #expect(object["exit_code"] as? Int == 0)
        #expect(object["command"] as? String == "sync")
        let items = try #require(object["items"] as? [[String: String]])
        #expect(items.contains { $0["verb"] == "updated" && $0["side"] == "md" })
        #expect(items.contains { $0["verb"] == "held" && $0["side"] == "apple" })
        #expect((object["settings"] as? [String: String])?["apple_writes"] == "disabled")
    }

    @Test("--quiet prints only warnings")
    func quiet() {
        let harness = CLIHarness.exported()
        harness.vault.seed("People/Zed.md", Data("---\ntype: person\ntitle: Zed\n---\n".utf8))
        let run = harness.sync(["--quiet"])
        #expect(run.out == "WARNING  pending    1 markdown-only files await review\n")
    }

    @Test("plan after the first export shows the two-way plan and writes nothing")
    func plan() {
        let harness = CLIHarness.exported()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        harness.vault.resetWrites()
        let run = harness.run(["plan", "--root", "/vault"])
        #expect(run.code == 0)
        #expect(run.out.contains("update   md     Inbox/Bob Two.md  (job_title)"))
        #expect(run.out.contains("held     apple  Ann One  (job_title) — apple writes disabled"))
        #expect(run.out.contains("note     dry run: nothing written; run `contacts2md sync --root /vault` to sync"))
        #expect(harness.vault.writes.isEmpty)
        let oneWay = harness.run(["plan", "--root", "/vault", "--one-way"])
        #expect(oneWay.out.contains("dry run: nothing written; run `contacts2md export"))
    }

    @Test("status shows the sync switches and devices")
    func status() {
        let harness = CLIHarness.exported()
        _ = harness.sync()
        let run = harness.run(["status", "--root", "/vault"])
        #expect(run.out.contains("sync     apple_writes=disabled  stamp_contacts=false  devices=1"))
        #expect(run.out.contains("lease    Test Mac until"))
    }

    @Test("deleted in Contacts: queued after 10 minutes, decided with review, trashed on the next sync")
    func appleDelete() throws {
        let harness = CLIHarness.exported()
        harness.store.deleteContact(withCard: "cy:icloud")
        #expect(harness.sync().out.contains("1 contacts missing from Contacts"))
        harness.clock.advance(11 * 60)
        let queued = harness.sync()
        #expect(queued.code == 1)
        let warning = try #require(harness.lines(queued).first { $0.hasPrefix("WARNING  delete") })
        #expect(warning.contains("\"Cy Three\" was deleted in Contacts; Inbox/Cy Three.md kept"))
        let id = try #require(warning.split(separator: "[").last?.dropLast()).description
        #expect(harness.run(["review", "decide", id, "trash", "--root", "/vault"]).code == 0)
        let trashed = harness.sync()
        #expect(trashed.out.contains("trashed  md     Inbox/Cy Three.md"))
        #expect(!harness.vault.exists("Inbox/Cy Three.md"))
    }
}
