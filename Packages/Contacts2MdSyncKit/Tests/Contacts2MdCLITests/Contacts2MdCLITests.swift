import ContactModel
import Contacts2MdCLI
import Foundation
import PhoneNumberKeys
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// The outcome of one CLI invocation.
struct CLIRun {
    let code: Int32
    let out: String
    let err: String
}

/// A CLI run against fakes: `FakeContactStore`, `InMemoryVault`, a temp state dir.
final class CLIHarness: Sendable {
    let store: FakeContactStore
    let vault: InMemoryVault
    let stateDirectory: URL
    let ids = SequentialIDGenerator()

    init(store: FakeContactStore = Fixtures.store(), vault: InMemoryVault = InMemoryVault()) {
        self.store = store
        self.vault = vault
        stateDirectory = FileManager.default.temporaryDirectory.appending(path: "c2m-cli-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: stateDirectory) }

    func run(_ arguments: [String], isDirectory: Bool = true) -> CLIRun {
        let output = CLIOutput.capturing()
        let store = self.store
        let vault = self.vault
        let environment = CLIEnvironment(
            makeStore: { store },
            makeVault: { _ in vault },
            isDirectory: { _ in isDirectory },
            stateDirectory: stateDirectory,
            makeKeyer: { PhoneNumberKitKeyer(defaultRegion: $0) },
            ids: ids,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            fallbackRegion: "US",
            output: output
        )
        let code = Contacts2MdCLI.run(arguments, environment: environment)
        return CLIRun(code: code, out: output.stdout, err: output.stderr)
    }

    var backups: [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: stateDirectory.appending(path: "backups").path(percentEncoded: false)))
            ?? []
    }
}

@Suite("contacts2md CLI")
struct CLITests {
    @Test("subcommand detection for the app binary")
    func detection() {
        #expect(Contacts2MdCLI.isCLIInvocation(["export", "--root", "x"]))
        #expect(Contacts2MdCLI.isCLIInvocation(["status"]))
        #expect(Contacts2MdCLI.isCLIInvocation(["--help"]))
        #expect(!Contacts2MdCLI.isCLIInvocation([]))
        #expect(!Contacts2MdCLI.isCLIInvocation(["-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!Contacts2MdCLI.isCLIInvocation(["sync"]))  // M3
    }

    @Test("plan prints the dry run with stable prefixes and writes nothing")
    func plan() {
        let harness = CLIHarness()
        let run = harness.run(["plan", "--root", "/vault"])
        let (code, out, err) = (run.code, run.out, run.err)
        #expect(code == 1)  // the Chris Martin duplicate needs review
        #expect(err.isEmpty)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "contacts2md plan  2027-01-15T08:00:00Z  root=/vault")
        #expect(lines.contains("create   md     Inbox/Jane Doe.md"))
        #expect(lines.contains("write    image  _images/00000000-0000-4000-8000-000000000002.jpg"))
        #expect(lines.contains("write    config .c2mdsync/config.yaml"))
        #expect(
            lines.contains { $0.hasPrefix("WARNING  duplicate  \"Chris Martin\" (iCloud), \"Chris Martin\" (Google)") })
        #expect(lines.contains { $0.hasPrefix("summary  apple c/u/d 0/0/0  md c/u/d 59/0/0  unchanged 0  skipped 1") })
        #expect(lines.last?.hasPrefix("note     dry run: nothing written") == true)
        #expect(harness.vault.paths.isEmpty)
    }

    @Test("export without --yes is a dry run")
    func exportDry() {
        let harness = CLIHarness()
        let out = harness.run(["export", "--root", "/vault"]).out
        #expect(out.contains("note     dry run"))
        #expect(harness.vault.paths.isEmpty)
    }

    @Test("export --yes writes; a second run writes nothing")
    func exportTwice() {
        let harness = CLIHarness()
        let first = harness.run(["export", "--root", "/vault", "--yes", "--default-folder", "People"])
        #expect(first.code == 1)
        #expect(first.out.contains("created  md     People/Jane Doe.md\n"))
        #expect(first.out.contains("wrote    config .c2mdsync/config.yaml\n"))
        #expect(harness.vault.exists("People/Jane Doe.md"))
        #expect(harness.vault.text(".c2mdsync/config.yaml")?.contains("default_folder: People\n") == true)
        #expect(harness.backups.isEmpty)  // no --stamp, no Apple writes, no backup
        #expect(harness.store.appliedBatches.isEmpty)

        harness.vault.resetWrites()
        let second = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(second.out.contains("md c/u/d 0/0/0  unchanged 59"))
        #expect(!second.out.contains("created "))
        #expect(harness.vault.writes.isEmpty)
    }

    @Test("--stamp requires --yes")
    func stampNeedsYes() {
        let run = CLIHarness().run(["export", "--root", "/vault", "--stamp"])
        let (code, out, err) = (run.code, run.out, run.err)
        #expect(code == 64)
        #expect(out.isEmpty)
        #expect(err.contains("--stamp writes to Contacts and requires --yes"))
    }

    @Test("--stamp backs up first, then stamps exported contacts")
    func stamp() throws {
        let harness = CLIHarness()
        let out = harness.run(["export", "--root", "/vault", "--yes", "--stamp"]).out
        #expect(harness.backups.count == 1)
        #expect(out.contains("backup   apple  "))
        #expect(out.contains("stamped  apple  Jane Doe\n"))
        let batches = harness.store.appliedBatches
        #expect(batches.count == 1)
        #expect(batches.first?.author == "com.zmre.contacts2mdsync.cli")
        let backupIndex = try #require(out.range(of: "backup   apple"))
        let createdIndex = try #require(out.range(of: "created  md"))
        #expect(backupIndex.lowerBound < createdIndex.lowerBound)
        // Re-running stamps nothing new.
        let again = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(!again.out.contains("stamped "))
        #expect(harness.store.appliedBatches.count == 1)
    }

    @Test("no Contacts access → exit 3 on stderr, nothing written")
    func noAccess() {
        let harness = CLIHarness()
        harness.store.denyAccess()
        let run = harness.run(["export", "--root", "/vault", "--yes"])
        let (code, _, err) = (run.code, run.out, run.err)
        #expect(code == 3)
        #expect(err.contains("error    Contacts access has not been granted"))
        #expect(harness.vault.paths.isEmpty)
    }

    @Test("missing root → exit 3")
    func missingRoot() {
        let run = CLIHarness().run(["plan", "--root", "/nope"], isDirectory: false)
        let (code, _, err) = (run.code, run.out, run.err)
        #expect(code == 3)
        #expect(err.contains("is not an existing folder"))
    }

    @Test("status before and after the first export")
    func status() {
        let harness = CLIHarness()
        let before = harness.run(["status", "--root", "/vault"])
        #expect(before.code == 3)
        #expect(before.out.contains("vault    not configured"))
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        let after = harness.run(["status", "--root", "/vault"])
        #expect(after.code == 0)
        #expect(after.out.contains("vault    configured  id=00000000-0000-4000-8000-000000000001"))
        #expect(after.out.contains("notes    59 contact notes (59 linked, 0 markdown-only), 0 other notes"))
        #expect(after.out.contains("apple    access granted  contacts=60  notes=available"))
        #expect(after.out.contains("export   last 2027-01-15T08:00:00Z  records=59"))
    }

    @Test("--quiet prints only warnings")
    func quiet() {
        let out = CLIHarness().run(["plan", "--root", "/vault", "--quiet"]).out
        #expect(out.split(separator: "\n").allSatisfy { $0.hasPrefix("WARNING") })
        #expect(out.contains("WARNING  duplicate"))
    }

    @Test("help exits 0")
    func help() {
        let run = CLIHarness().run(["--help"])
        let (code, out, _) = (run.code, run.out, run.err)
        #expect(code == 0)
        #expect(out.contains("USAGE: contacts2md"))
        #expect(out.contains("export"))
    }
}
