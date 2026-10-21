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
    let device: DeviceIdentity
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))

    init(
        store: FakeContactStore = Fixtures.store(), vault: InMemoryVault = InMemoryVault(),
        device: DeviceIdentity = DeviceIdentity(id: "00000000-0000-4000-8000-00000000d001", name: "Test Mac")
    ) {
        self.store = store
        self.vault = vault
        self.device = device
        stateDirectory = FileManager.default.temporaryDirectory.appending(path: "c2m-cli-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: stateDirectory) }

    func environment(
        output: CLIOutput = .capturing(), isDirectory: Bool = true, rootAccess: RootAccess = .explicitOnly
    ) -> CLIEnvironment {
        let store = self.store
        let vault = self.vault
        let device = self.device
        return CLIEnvironment(
            makeStore: { store },
            makeVault: { _ in vault },
            isDirectory: { _ in isDirectory },
            stateDirectory: stateDirectory,
            makeKeyer: { PhoneNumberKitKeyer(defaultRegion: $0) },
            ids: ids,
            clock: clock,
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            fallbackRegion: "US",
            output: output,
            device: { device },
            rootAccess: rootAccess,
            lockWait: 0,
            leaseSettle: 0,
            sleep: { _ in }
        )
    }

    func run(_ arguments: [String], isDirectory: Bool = true, rootAccess: RootAccess = .explicitOnly) -> CLIRun {
        let output = CLIOutput.capturing()
        let environment = environment(output: output, isDirectory: isDirectory, rootAccess: rootAccess)
        let code = Contacts2MdCLI.run(arguments, environment: environment)
        return CLIRun(code: code, out: output.stdout, err: output.stderr)
    }

    /// vCard backups in any vault's state folder.
    var backups: [String] {
        let vaults =
            (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path(percentEncoded: false))) ?? []
        return vaults.flatMap { vault in
            let folder = stateDirectory.appending(path: vault).appending(path: "backups")
            return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .filter { $0.hasSuffix(".vcf") }
        }
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
        #expect(Contacts2MdCLI.isCLIInvocation(["sync"]))
        #expect(Contacts2MdCLI.isCLIInvocation(["config"]))
        #expect(Contacts2MdCLI.isCLIInvocation(["review", "list"]))
    }

    @Test("plan prints the dry run with stable prefixes and writes nothing")
    func plan() {
        let harness = CLIHarness()
        let run = harness.run(["plan", "--root", "/vault"])
        let (code, out, err) = (run.code, run.out, run.err)
        #expect(code == 1)  // the Chris Martin duplicate needs review
        #expect(err.isEmpty)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "contacts2md plan  2027-01-15T08:00:00Z  device=Test Mac  root=/vault")
        #expect(lines.contains("create   md     Inbox/Jane Doe.md"))
        #expect(lines.contains("write    image  _images/00000000-0000-4000-8000-000000000002.jpg"))
        #expect(lines.contains("write    config .c2mdsync/config.yaml"))
        #expect(
            lines.contains { $0.hasPrefix("WARNING  duplicate  \"Chris Martin\" (iCloud), \"Chris Martin\" (Google)") })
        #expect(
            lines.contains {
                $0.hasPrefix("summary  apple c/u/d 0/0/0  md c/u/d 59/0/0  adopted 0  unchanged 0  skipped 1")
            })
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
        #expect(second.out.contains("md c/u/d 0/0/0  adopted 0  unchanged 59"))
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
        #expect(after.code == 1)  // the Chris Martin cluster is pending review
        #expect(after.out.contains("review   1 pending (as of 2027-01-15T08:00:00Z"))
        #expect(after.out.contains("vault    configured  id=00000000-0000-4000-8000-000000000001"))
        #expect(after.out.contains("notes    59 contact notes (59 linked, 0 markdown-only), 0 other notes"))
        #expect(after.out.contains("apple    access granted  contacts=60  linked=2  cards=62  notes=available"))
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

    @Test("without --root and without a saved folder: exit 3, never prompts")
    func unconfiguredRoot() {
        let run = CLIHarness().run(["plan"])
        #expect(run.code == 3)
        #expect(run.err.contains("no notes folder"))
    }

    @Test("without --root the saved folder (bookmark) is used and released afterwards")
    func bookmarkRoot() {
        let closed = Counter()
        let access = RootAccess { root in
            #expect(root == nil)
            return ResolvedRoot(url: URL(filePath: "/saved", directoryHint: .isDirectory)) { closed.increment() }
        }
        let harness = CLIHarness()
        let run = harness.run(["export", "--yes"], rootAccess: access)
        #expect(run.code == 1)
        #expect(run.out.hasPrefix("contacts2md export  2027-01-15T08:00:00Z  device=Test Mac  root=/saved\n"))
        #expect(run.out.contains("note     dry run") == false)
        #expect(harness.vault.exists("Inbox/Jane Doe.md"))
        #expect(closed.value == 1)
    }

    @Test("review list → decide → the next plan honours the decision")
    func reviewFlow() throws {
        let harness = CLIHarness()
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        let list = harness.run(["review", "list", "--root", "/vault"])
        #expect(list.code == 1)
        let line = try #require(list.out.split(separator: "\n").first { $0.hasPrefix("item     dup-") })
        let id = String(line.split(separator: " ", omittingEmptySubsequences: true)[1])
        #expect(list.out.contains("choices: distinct | only:1 | only:2"))

        let bad = harness.run(["review", "decide", id, "adopt", "--root", "/vault"])
        #expect(bad.code == 64 && bad.err.contains("invalid choice"))
        #expect(harness.run(["review", "decide", "dup-nope", "distinct", "--root", "/vault"]).code == 64)

        let decided = harness.run(["review", "decide", id, "distinct", "--root", "/vault"])
        #expect(decided.code == 0)
        #expect(decided.out.contains("decided  review \(id) → distinct"))
        let log = try #require(
            harness.vault.text(".c2mdsync/devices/00000000-0000-4000-8000-00000000d001/decisions.jsonl"))
        #expect(log.contains("\"kind\":\"distinct-people\""))
        #expect(harness.run(["review", "list", "--root", "/vault"]).out.contains("1 decided items take effect"))

        let plan = harness.run(["plan", "--root", "/vault"])
        #expect(plan.code == 0, "\(plan.out)")
        #expect(plan.out.contains("create   md     Inbox/Chris Martin 2.md"))
        #expect(!plan.out.contains("WARNING  duplicate"))
    }

    @Test("review adopt-all adopts pending one-to-one matches")
    func adoptAll() {
        let vault = InMemoryVault(files: ["People/Bob Smith.md": "---\ntype: person\ntitle: Bob Smith\n---\nmine\n"])
        let harness = CLIHarness(vault: vault)
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(!harness.vault.exists("Inbox/Bob Smith.md"))
        let adopt = harness.run(["review", "adopt-all", "--root", "/vault"])
        #expect(adopt.out.contains("1 adoptions recorded"), "\(adopt.out)")
        let export = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(export.out.contains("adopted  md     People/Bob Smith.md  ← \"Bob Smith\" adopted (decision)"))
        #expect(export.out.contains("backup   md     "))
        #expect(harness.vault.text("People/Bob Smith.md")?.contains("c2mdsync:\n  id: ") == true)
        #expect(harness.vault.text("People/Bob Smith.md")?.hasSuffix("---\nmine\n") == true)
    }

    @Test("stored status for the app: nil before the first export, then records and pending items")
    func storedStatus() throws {
        let harness = CLIHarness()
        let session = VaultSession(root: URL(filePath: "/vault"), environment: harness.environment())
        #expect(try session.storedStatus() == nil)
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        let status = try #require(try session.storedStatus())
        #expect(status.records == 59 && status.pendingReview == 1)
        #expect(status.lastExport == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("review commands need a configured vault")
    func reviewUnconfigured() {
        let run = CLIHarness().run(["review", "list", "--root", "/vault"])
        #expect(run.code == 3)
        #expect(run.err.contains("not configured"))
    }
}

/// Thread-safe counter for callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }

    var value: Int { lock.withLock { count } }
}
