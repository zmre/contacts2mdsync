import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Apple writes outside `SyncExecutor` go through the same `CardWriteRouter`
/// (architecture §6 "Write routing", spike S15): the fake framework refuses
/// every update of a card with a note (134092), as the real one does
/// without the notes entitlement. Ann's card has a note, Bob's has none.
@Suite("contacts2md: stamps and other writes outside sync, for contacts with notes")
struct NotedStampCLITests {
    /// Exported (no stamps), the framework then refusing noted cards.
    static func exported() -> CLIHarness {
        let harness = CLIHarness.exported(notesStore())
        harness.store.setModelsFrameworkWithoutNotesEntitlement(true)
        return harness
    }

    static func stampedCards(_ harness: CLIHarness) -> Set<String> {
        Set(harness.store.contacts.flatMap(\.cards).filter { $0.stampID != nil }.map(\.id))
    }

    static func scriptedStamps(_ harness: CLIHarness) -> [String] {
        harness.store.scriptedOperations.compactMap { if case .stamp(let card, _) = $0 { card } else { nil } }
    }

    static func note(_ harness: CLIHarness) -> String? { harness.store.scriptedNotes()["ann:icloud"].flatMap { $0 } }

    @Test("export --stamp, notes unknown, Contacts.app permitted: stamped through Contacts.app, nothing refused")
    func stampUnknownPermitted() {
        let harness = Self.exported()
        let run = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(run.out.contains("stamped  apple  Ann One\n"), "\(run.out)")
        #expect(run.out.contains("stamped  apple  Bob Two\n"))
        #expect(!run.out.contains("WARNING  stamp"), "no 134092 failure")
        #expect(harness.store.rejectedForNote.isEmpty)
        #expect(Self.stampedCards(harness) == ["ann:icloud", "bob:icloud"])
        #expect(Set(Self.scriptedStamps(harness)) == ["ann:icloud", "bob:icloud"])
        #expect(Self.note(harness) == "Met at the 2019 conference.", "note intact")
        #expect(harness.cards.finishedSessions == 1, "the Contacts.app session ends with the export")
    }

    @Test("export --stamp headless without permission: Bob stamped, Ann held (exit 0); stamped once permitted")
    func stampHeldWithoutPermission() {
        let harness = Self.exported()
        harness.cards.setPermission(.notDetermined)
        let run = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        let lines = harness.lines(run)
        #expect(lines.contains("stamped  apple  Bob Two"), "\(run.out)")
        #expect(lines.contains("held     apple  Ann One — \(CardWriteRouter.permissionReason)"), "\(run.out)")
        let warning = "WARNING  held       contacts with notes are edited through Contacts.app"
        #expect(lines.contains { $0.hasPrefix(warning) })
        #expect(!run.out.contains("WARNING  stamp"), "a hold is not a failure")
        #expect(run.err.isEmpty)
        #expect(harness.store.rejectedForNote.map(\.cardID) == ["ann:icloud"], "framework first, 134092, then held")
        #expect(Self.stampedCards(harness) == ["bob:icloud"])

        harness.cards.setPermission(.granted)
        let granted = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(granted.code == 0, "\(granted.out)\(granted.err)")
        #expect(harness.lines(granted).contains("stamped  apple  Ann One"), "\(granted.out)")
        #expect(!granted.out.contains("held "))
        #expect(Self.stampedCards(harness) == ["ann:icloud", "bob:icloud"])
        #expect(Self.note(harness) == "Met at the 2019 conference.")
    }

    @Test("export --stamp with control of Contacts.app denied: the noted card is held, not failed")
    func stampHeldPermissionDenied() {
        let harness = Self.exported()
        harness.cards.setPermission(.denied)
        let run = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(harness.lines(run).contains("held     apple  Ann One — \(CardWriteRouter.permissionReason)"))
        #expect(Self.stampedCards(harness) == ["bob:icloud"])
    }

    @Test("export --stamp uses the mirror's notes: the noted card straight to Contacts.app, the other to the framework")
    func stampMirrorNotes() {
        let harness = CLIHarness.exported(notesStore())
        #expect(harness.run(["config", "--root", "/vault", "--notes", "on"]).code == 0)
        #expect(harness.sync().code == 0)  // the mirror now carries the notes
        #expect(harness.run(["config", "--root", "/vault", "--notes", "off"]).code == 0)
        harness.store.setModelsFrameworkWithoutNotesEntitlement(true)
        harness.cards.setPermission(.notDetermined)
        let reads = harness.notes.cardReads.count + harness.notes.bulkReads
        let run = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(harness.store.rejectedForNote.isEmpty, "known to have a note: never refused first")
        #expect(harness.lines(run).contains("held     apple  Ann One — \(CardWriteRouter.permissionReason)"))
        #expect(Self.stampedCards(harness) == ["bob:icloud"])
        #expect(Self.scriptedStamps(harness).isEmpty)
        #expect(harness.notes.cardReads.count + harness.notes.bulkReads == reads, "notes off: no notes read")
    }

    @Test("export --stamp with notes_sync on and no mirror reads the stamped cards' notes to route them")
    func stampProviderNotes() {
        let harness = Self.exported()
        #expect(harness.run(["config", "--root", "/vault", "--notes", "on"]).code == 0)
        let run = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(harness.notes.cardReads.last.map(Set.init) == ["ann:icloud", "bob:icloud"])
        #expect(harness.store.rejectedForNote.isEmpty)
        #expect(Self.scriptedStamps(harness) == ["ann:icloud"], "only the noted card through Contacts.app")
        #expect(Self.stampedCards(harness) == ["ann:icloud", "bob:icloud"])
        #expect(harness.notes.finishedSessions >= 1 && harness.cards.finishedSessions == 1)
    }

    @Test("export --stamp, notes read fails (no permission): unknown, so framework first and the refused card held")
    func stampProviderReadFails() {
        let harness = Self.exported()
        #expect(harness.run(["config", "--root", "/vault", "--notes", "on"]).code == 0)
        harness.notes.setPermission(.notDetermined)
        harness.cards.setPermission(.notDetermined)
        let run = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(harness.store.rejectedForNote.map(\.cardID) == ["ann:icloud"])
        #expect(harness.lines(run).contains("held     apple  Ann One — \(CardWriteRouter.permissionReason)"))
        #expect(harness.notes.permissionRequests == 0, "never prompts")
        #expect(Self.stampedCards(harness) == ["bob:icloud"])
    }

    @Test("reset-state, then export --stamp: stamps are routed like on a first export")
    func resetThenStamp() {
        let harness = CLIHarness.exported(notesStore())
        #expect(harness.sync().code == 0)
        harness.store.setModelsFrameworkWithoutNotesEntitlement(true)
        #expect(harness.run(["reset-state", "--root", "/vault", "--yes"]).code == 0)
        harness.cards.setPermission(.notDetermined)
        let run = harness.run(["export", "--root", "/vault", "--yes", "--stamp"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(!run.out.contains("created  md"), "rebinds, nothing duplicated: \(run.out)")
        #expect(harness.lines(run).contains("held     apple  Ann One — \(CardWriteRouter.permissionReason)"))
        #expect(!run.out.contains("WARNING  stamp"))
        harness.cards.setPermission(.granted)
        #expect(harness.run(["export", "--root", "/vault", "--yes", "--stamp"]).code == 0)
        #expect(Self.stampedCards(harness) == ["ann:icloud", "bob:icloud"])
        #expect(harness.sync().code == 0)
    }

    @Test("rescan writes nothing to Contacts; the next sync with stamp_contacts on routes the stamps")
    func rescanThenSyncStamps() {
        let harness = CLIHarness.exported(notesStore())
        #expect(harness.sync().code == 0)
        harness.store.setModelsFrameworkWithoutNotesEntitlement(true)
        let batches = harness.store.appliedBatches.count
        #expect(harness.run(["rescan", "--root", "/vault"]).code == 0)
        #expect(harness.store.appliedBatches.count == batches && harness.store.scriptedOperations.isEmpty)
        let config = harness.run([
            "config", "--root", "/vault", "--apple-writes", "enabled", "--stamp-contacts", "true",
        ])
        #expect(config.code == 0, "\(config.out)\(config.err)")
        let run = harness.sync(["--max-apple-changes", "10"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(harness.store.rejectedForNote.isEmpty)
        #expect(Self.stampedCards(harness) == ["ann:icloud", "bob:icloud"])
        #expect(Self.note(harness) == "Met at the 2019 conference.")
    }

    @Test("the app's first export (Run First Sync) writes nothing to Contacts, so nothing can be refused")
    func appFirstExport() throws {
        let harness = CLIHarness(store: notesStore())
        harness.store.setModelsFrameworkWithoutNotesEntitlement(true)
        let reader = UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
        let summary = try reader.export()
        #expect(summary.created == 2 && summary.failures.isEmpty)
        #expect(harness.store.appliedBatches.isEmpty && harness.store.scriptedOperations.isEmpty)
        #expect(harness.store.rejectedForNote.isEmpty)
    }
}
