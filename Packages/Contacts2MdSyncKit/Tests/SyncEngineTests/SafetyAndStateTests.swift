import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("Executor safety")
struct ExecutorTests {
    @Test("a note edited between plan and execute is not overwritten")
    func compareAndSwap() throws {
        let harness = ExportHarness()
        try harness.export()
        var contacts = harness.store.contacts
        let index = try #require(contacts.firstIndex { $0.unifiedID == "c03:icloud" })
        contacts[index].contact.jobTitle = "Retired"
        harness.store.replaceContacts(contacts)
        let plan = try harness.plan()
        harness.vault.seed("Inbox/Bob Smith.md", Data("---\ntype: person\ntitle: Bob\n---\nedited meanwhile\n".utf8))
        let result = try ExportExecutor(fs: harness.vault, records: harness.records).execute(plan)
        #expect(result.updated.isEmpty)
        #expect(result.failures.map(\.path) == ["Inbox/Bob Smith.md"])
        #expect(harness.vault.text("Inbox/Bob Smith.md")?.contains("edited meanwhile") == true)
    }

    @Test("a new note whose path appeared meanwhile is not overwritten")
    func createRace() throws {
        let harness = ExportHarness()
        let plan = try harness.plan()
        harness.vault.seed("Inbox/Bob Smith.md", Data("mine\n".utf8))
        let result = try ExportExecutor(fs: harness.vault, records: harness.records).execute(plan)
        #expect(result.failures.map(\.path) == ["Inbox/Bob Smith.md"])
        #expect(harness.vault.text("Inbox/Bob Smith.md") == "mine\n")
        // The failed record is not bound, so the next run retries with a new name.
        #expect(try harness.records.load().records.values.allSatisfy { $0.path != "Inbox/Bob Smith.md" })
    }
}

@Suite("Backups and stamping")
struct StampingTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "c2m-tests-\(UUID().uuidString)")
    }

    @Test("vCard backups keep the newest 10")
    func backupPruning() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Fixtures.store()
        for second in 0..<12 {
            let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000 + Double(second)))
            let receipt = try VCardBackup(directory: directory, clock: clock).backup(store)
            #expect(receipt.byteCount > 0)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        #expect(files.count == 10)
        #expect(files.first == "contacts-20270115T080002Z.vcf")
        #expect(store.vCardExportCount == 12)
    }

    @Test("stamping writes x-c2mdsync stamps to the planned cards with our author")
    func stamping() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = ExportHarness()
        let (plan, _) = try harness.export()
        let receipt = try VCardBackup(directory: directory).backup(harness.store)
        let result = try Stamper.stamp(
            plan.stamps, in: harness.store, backup: receipt, author: "com.zmre.contacts2mdsync.test")
        #expect(result.failed.isEmpty)
        #expect(result.applied.count == plan.stamps.count)
        #expect(harness.store.appliedBatches.map(\.author) == ["com.zmre.contacts2mdsync.test"])
        let sam = try #require(harness.store.contacts.first { $0.unifiedID == "c28:icloud" })
        #expect(sam.cards.first { $0.accountKind == .iCloud }?.stampID != nil)
        #expect(sam.cards.first { $0.accountKind == .google }?.stampID == nil)
        // Google-first unified contact: the stamp still goes to its iCloud card.
        let gail = try #require(harness.store.contacts.first { $0.unifiedID == "c53:google" })
        #expect(gail.cards.first { $0.accountKind == .iCloud }?.stampID != nil)
    }
}

@Suite("State files")
struct StateTests {
    @Test("legacy records.json imports with trusted card ids; lookups ignore the unified id")
    func legacyRecordMap() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "c2m-\(UUID().uuidString)/records.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        let json = """
            {"lastExport":"2027-01-15T08:00:00Z","records":{"\(id.uuidString.lowercased())":\
            {"cardIDs":["u1","g1"],"path":"Inbox/A.md","unifiedID":"u1"}}}
            """
        try Data(json.utf8).write(to: url)
        let map = try #require(try LegacyRecordMapFile.read(url, now: Date()))
        #expect(map[id]?.path == "Inbox/A.md")
        #expect(map[id]?.cards.allSatisfy(\.isTrusted) == true)
        #expect(map.lastExport == Date(timeIntervalSince1970: 1_800_000_000))
        let lookup = RecordMap.Lookup(map)
        #expect(lookup.hits(cardIDs: ["g1"]).map(\.recordID) == [id])
        #expect(lookup.hits(cardIDs: ["u-synthesized"]).isEmpty)
        #expect(try LegacyRecordMapFile.read(url.appending(path: "nope"), now: Date()) == nil)
    }

    @Test("config rendering preserves unknown keys and comments")
    func configPatch() throws {
        let original = """
            # shared vault config
            vault_id: 0d7c0000-0000-4000-8000-0000000000aa
            schema: 1
            default_folder: People
            limits:
              mass_vanish_count: 10
            groups:
              Family: family

            """
        let vault = InMemoryVault(files: [VaultConfig.path: original])
        var (config, text) = try #require(try VaultConfig.load(from: vault))
        #expect(config.defaultFolder == "People")
        #expect(config.render(patching: text) == original)
        config.groups.append(GroupTag(group: "Close Friends", tag: "close_friends"))
        let patched = config.render(patching: text)
        #expect(patched.contains("# shared vault config\n"))
        #expect(patched.contains("limits:\n  mass_vanish_count: 10\n"))
        #expect(patched.contains("groups:\n  Family: family\n  Close Friends: close_friends\n"))
    }

    @Test("local vault: atomic writes, CAS, hidden files skipped")
    func localVault() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "c2m-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = LocalVaultFS(root: root)
        let stamp = try fs.write(Data("one".utf8), to: "A/b.md", expecting: .absent)
        #expect(throws: VaultFSError.conflict(path: "A/b.md")) {
            try fs.write(Data("x".utf8), to: "A/b.md", expecting: .absent)
        }
        _ = try fs.write(Data("two".utf8), to: "A/b.md", expecting: .unchanged(stamp))
        #expect(throws: VaultFSError.conflict(path: "A/b.md")) {
            try fs.write(Data("three".utf8), to: "A/b.md", expecting: .unchanged(stamp))
        }
        _ = try fs.write(Data("cfg".utf8), to: ".c2mdsync/config.yaml", expecting: .any)
        #expect(try fs.enumerate().map(\.path) == ["A/b.md"])
        #expect(String(data: try fs.read("A/b.md").0, encoding: .utf8) == "two")
        #expect(fs.exists(".c2mdsync/config.yaml"))
        #expect(throws: VaultFSError.self) { try fs.read("../escape.md") }
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: "A").path(percentEncoded: false))
        #expect(leftovers == ["b.md"])
    }

    @Test("relative image paths")
    func relativePaths() {
        #expect(VaultPath.relative("_images/x.jpg", fromDirectory: "Inbox") == "../_images/x.jpg")
        #expect(VaultPath.relative("_images/x.jpg", fromDirectory: "") == "_images/x.jpg")
        #expect(VaultPath.relative("_images/x.jpg", fromDirectory: "a/b") == "../../_images/x.jpg")
        #expect(VaultPath.relative("a/x.jpg", fromDirectory: "a") == "x.jpg")
    }
}
