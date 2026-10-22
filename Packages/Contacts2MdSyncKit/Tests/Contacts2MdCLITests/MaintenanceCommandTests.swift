import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// `contacts2md rescan` and `contacts2md reset-state` (docs/ui.md §9 Advanced).
@Suite("contacts2md rescan / reset-state")
struct MaintenanceCommandTests {
    static func synced(stamps: Bool = false) -> CLIHarness {
        let harness = CLIHarness.exported()
        if stamps {
            let config = harness.run([
                "config", "--root", "/vault", "--apple-writes", "enabled", "--stamp-contacts", "true",
            ])
            #expect(config.code == 0, "\(config.out)\(config.err)")
        }
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        return harness
    }

    static func reader(_ harness: CLIHarness) -> UIVaultReader {
        UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
    }

    /// Markdown files in the vault (notes, not state).
    static func notes(_ harness: CLIHarness) -> [String] {
        harness.vault.paths.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted()
    }

    static func stateBackups(_ harness: CLIHarness) -> [String] {
        let root = harness.stateDirectory
        let vaults = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return vaults.flatMap { vault in
            let folder = root.appending(path: vault).appending(path: "backups")
            return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
                .filter { $0.hasPrefix("state-") && $0.hasSuffix(".sqlite") }
        }
    }

    @Test("rescan clears the caches; the next sync reads everything again and changes nothing")
    func rescan() throws {
        let harness = Self.synced()
        let incremental = harness.sync()
        #expect(incremental.out.contains("apple    incremental"), "\(incremental.out)")
        let run = harness.run(["rescan", "--root", "/vault"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(run.out.contains("cleared  cache  file cache (3 files), Contacts mirror and history token"))
        let next = harness.sync()
        #expect(next.code == 0)
        #expect(next.out.contains("apple    full snapshot (no cached snapshot)"), "\(next.out)")
        #expect(next.out.contains("md c/u/d 0/0/0"))
        #expect(try Self.reader(harness).read()?.records.records.count == 3)
    }

    @Test("rescan before this Mac synced the folder: exit 3")
    func rescanNotSynced() {
        let run = CLIHarness(store: smallStore()).run(["rescan", "--root", "/vault"])
        #expect(run.code == 3)
    }

    @Test("reset-state without --yes changes nothing")
    func resetPreview() throws {
        let harness = Self.synced()
        let run = harness.run(["reset-state", "--root", "/vault"])
        #expect(run.code == 0)
        #expect(run.out.contains("reset    state  3 records"))
        #expect(run.out.contains("nothing changed"))
        #expect(Self.stateBackups(harness).isEmpty)
        #expect(harness.sync().code == 0)
    }

    @Test(
        "reset-state --yes: backup first, then the next export binds like a joining device; nothing duplicated",
        arguments: [false, true])
    func reset(stamps: Bool) throws {
        let harness = Self.synced(stamps: stamps)
        let before = Self.notes(harness)
        let sessions = try Self.reader(harness).read()?.sessions.count ?? 0
        let run = harness.run(["reset-state", "--root", "/vault", "--yes"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(run.out.contains("backup   state  "))
        #expect(run.out.contains("reset    state  3 records"))
        #expect(Self.stateBackups(harness).count == 1)
        let data = try #require(try Self.reader(harness).read())
        #expect(data.records.records.isEmpty && data.records.lastExport == nil)
        #expect(data.sessions.count >= sessions)  // Activity history kept

        // Two-way sync needs the first export again.
        #expect(harness.sync().code == 3)
        let export = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(export.code == 0, "\(export.out)\(export.err)")
        #expect(!export.out.contains("created  md"), "\(export.out)")
        #expect(Self.notes(harness) == before)
        #expect(try Self.reader(harness).read()?.records.records.count == 3)
        let after = harness.sync()
        #expect(after.code == 0, "\(after.out)\(after.err)")
        #expect(after.out.contains("md c/u/d 0/0/0"), "\(after.out)")
        #expect(Self.notes(harness) == before)
        #expect(!harness.store.appliedOperations.contains { if case .create = $0 { true } else { false } })
    }
}
