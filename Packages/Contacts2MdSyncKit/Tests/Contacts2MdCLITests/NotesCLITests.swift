import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// A small address book without the notes entitlement: Ann has a Contacts
/// note, Bob a hand-written markdown body (added after the export).
func notesStore() -> FakeContactStore {
    let people = [("ann", "Ann", "One"), ("bob", "Bob", "Two")].map { id, given, family in
        Fixtures.contact(id) { contact in
            contact.name = PersonName(given: given, family: family)
            contact.emails = [Labeled("home", "\(id)@example.com")]
            contact.body = id == "ann" ? "Met at the 2019 conference." : nil
        }
    }
    return FakeContactStore(
        contacts: people, containers: Fixtures.containers, groups: Fixtures.groups, notesEntitled: false)
}

extension CLIHarness {
    /// Exported and synced once with notes off; Bob's note gets a body.
    static func notesReady() -> CLIHarness {
        let harness = CLIHarness.exported(notesStore())
        #expect(harness.sync().code == 0)
        let path = "Inbox/Bob Two.md"
        harness.vault.seed(path, Data(((harness.vault.text(path) ?? "") + "\nPrivate notes\nline two\n").utf8))
        return harness
    }

    var notesSettings: NotesSettings { NotesSettingsStore(directory: stateDirectory).load() }
}

@Suite("contacts2md: Contacts notes")
struct NotesCLITests {
    @Test("config --notes on|off saves this Mac's setting (not the vault config) and explains the next steps")
    func configNotes() throws {
        let harness = CLIHarness.notesReady()
        harness.notes.setPermission(.notDetermined)
        let enabled = harness.run(["config", "--root", "/vault", "--notes", "on"])
        #expect(enabled.code == 0, "\(enabled.out)\(enabled.err)")
        #expect(harness.notesSettings.notesSync)
        #expect(harness.vault.text(".c2mdsync/config.yaml")?.contains("notes") == false)
        #expect(enabled.out.contains("wrote    settings notes_sync=on  quit_contacts_after_sync=true (this Mac)"))
        #expect(
            enabled.out.contains(
                "notes    notes_sync=on  source=Contacts.app scripting  permission=not-determined  "
                    + "quit_contacts_after_sync=true"
            ))
        #expect(enabled.out.contains("Settings ▸ Advanced ▸ Contact notes (the command line never asks)"))
        #expect(enabled.out.contains("preview it with `contacts2md plan`"))
        #expect(harness.notes.permissionRequests == 0)
        let off = harness.run(["config", "--root", "/vault", "--notes", "off"])
        #expect(off.code == 0)
        #expect(!harness.notesSettings.notesSync)
        #expect(off.out.contains("source=off (bodies are markdown-only)"))
    }

    @Test("plan previews the first notes sync: counts, and each markdown body bound for Contacts")
    func planPreview() throws {
        let harness = CLIHarness.notesReady()
        _ = harness.run(["config", "--root", "/vault", "--notes", "on"])
        let plan = harness.run(["plan", "--root", "/vault"])
        #expect(plan.code == 0, "\(plan.out)\(plan.err)")
        let lines = harness.lines(plan)
        #expect(
            lines.contains {
                $0.hasPrefix("notes    Contacts.app scripting: first notes sync on this Mac")
            })
        #expect(
            lines.contains(
                "notes    1 into markdown, 1 into Contacts (largest 22 chars: Bob Two), 0 already equal, 0 conflicts"))
        #expect(
            lines.contains("notes    apple  Bob Two  (markdown body → Contacts: 22 chars, 2 lines)  Inbox/Bob Two.md"))
        #expect(lines.contains("update   md     Inbox/Ann One.md  (body)"))
        #expect(lines.contains("held     apple  Bob Two  (body 22 chars) — apple writes disabled"))
        #expect(lines.contains { $0.contains("1 markdown bodies held for Contacts — apple writes disabled") })
        #expect(harness.notes.writes.isEmpty)
        #expect(harness.vault.text("Inbox/Ann One.md")?.contains("Met at the 2019 conference.") == false)
    }

    @Test("sync with apple_writes: Contacts note into markdown, markdown body into Contacts; then a no-op")
    func syncBothWays() throws {
        let harness = CLIHarness.notesReady()
        _ = harness.run(["config", "--root", "/vault", "--notes", "on", "--apple-writes", "enabled"])
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(run.out.contains("updated  apple  Bob Two  (body 22 chars)"))
        #expect(harness.vault.text("Inbox/Ann One.md")?.hasSuffix("Met at the 2019 conference.\n") == true)
        #expect(harness.store.scriptedNotes()["bob:icloud"] == .some("Private notes\nline two"))
        // The notes being overwritten were backed up first.
        let backups = try FileManager.default.subpathsOfDirectory(atPath: harness.stateDirectory.path())
        #expect(backups.contains { $0.contains("backups/apple-notes-") })
        #expect(harness.notes.finishedSessions >= 1)
        let again = harness.sync()
        #expect(!again.out.contains("updated ") && !again.out.contains("first notes sync"))
    }

    @Test("headless without Automation permission: WARNING notes, nothing about notes changes, exit 0")
    func headlessDenied() throws {
        let harness = CLIHarness.notesReady()
        _ = harness.run(["config", "--root", "/vault", "--notes", "on", "--apple-writes", "enabled"])
        harness.notes.setPermission(.denied)
        let before = harness.vault.text("Inbox/Ann One.md")
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(
            harness.lines(run).contains(
                "WARNING  notes      Automation permission for Contacts not granted; notes skipped"))
        #expect(harness.vault.text("Inbox/Ann One.md") == before)
        #expect(harness.notes.writes.isEmpty)
        #expect(harness.notes.permissionRequests == 0)
        let json = harness.run(["sync", "--root", "/vault", "--json"])
        #expect(json.out.contains("\"notes\" : \"skipped\"") || json.out.contains("\"notes\":\"skipped\""))
    }

    @Test("status reports the notes source and permission")
    func status() {
        let harness = CLIHarness.notesReady()
        _ = harness.run(["config", "--root", "/vault", "--notes", "on"])
        let run = harness.run(["status", "--root", "/vault"])
        #expect(run.out.contains("notes    notes_sync=on  source=Contacts.app scripting  permission=granted"))
        let quit = harness.run(["config", "--root", "/vault", "--quit-contacts", "false"])
        #expect(quit.code == 0)
        #expect(!harness.notesSettings.quitContactsAfterSync && harness.notesSettings.notesSync)
    }
}

@Suite("UI: Contact notes")
struct NotesUITests {
    @Test("line diff of a body conflict: common lines once, one-sided lines marked")
    func textDiff() {
        let lines = UITextDiff.lines(markdown: "a\nb\nc\nd", contacts: "a\r\nB\r\nc\r\nd\r\ne")
        #expect(lines.map(\.side) == [.both, .markdown, .contacts, .both, .both, .contacts])
        #expect(lines.map(\.text) == ["a", "b", "B", "c", "d", "e"])
        #expect(UITextDiff.lines(markdown: "", contacts: "x").map(\.side) == [.contacts])
    }

    @Test("a skipped notes run gives a banner pointing at Settings; Activity shows notes counts")
    func bannerAndActivity() throws {
        let harness = CLIHarness.notesReady()
        _ = harness.run(["config", "--root", "/vault", "--notes", "on", "--apple-writes", "enabled"])
        #expect(harness.sync().code == 0)
        harness.notes.setPermission(.denied)
        // A run that reads no notes (incremental, nothing touched) never asks;
        // a full run does, and skips notes.
        #expect(harness.sync(["--full"]).code == 0)
        let reader = UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
        let plan = try reader.plan()
        let banners = UIBanner.banners(
            status: nil, plan: plan.sync, outcome: nil, deviceID: harness.device.id, now: harness.clock.now)
        let banner = try #require(banners.first { $0.id == "notes-skipped" })
        #expect(banner.message.contains("Settings ▸ Advanced ▸ Contact notes"))
        #expect(banner.severity == .warning)
        let data = try #require(try reader.read())
        let rows = UIActivityRow.rows(data.sessions, device: harness.device)
        let syncs = rows.filter { $0.command == "sync" }.map(\.notes)
        #expect(syncs.contains("skipped"))
        #expect(syncs.contains("1 → Contacts · 1 → notes"))
    }
}

/// Apple writes to contacts with notes without the entitlement (spike S15,
/// architecture §6 "Write routing").
@Suite("contacts2md: writes to contacts with notes")
struct NotedWritesCLITests {
    @Test("headless without permission: the card with a note is held (exit 0), the others are written")
    func heldHeadless() throws {
        let store = notesStore()
        let harness = CLIHarness.exported(store)
        #expect(harness.run(["config", "--root", "/vault", "--apple-writes", "enabled"]).code == 0)
        #expect(harness.sync().code == 0)
        store.setModelsFrameworkWithoutNotesEntitlement(true)
        harness.cards.setPermission(.notDetermined)
        harness.editNote("Inbox/Ann One.md", "title: Ann One", with: "title: Ann One\njob_title: CTO")
        harness.editNote("Inbox/Bob Two.md", "title: Bob Two", with: "title: Bob Two\njob_title: Chef")
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        let lines = harness.lines(run)
        #expect(lines.contains("updated  apple  Bob Two  (job_title)"), "\(run.out)")
        #expect(lines.contains("held     apple  Ann One — needs permission for Contacts2MdSync to control Contacts"))
        #expect(
            lines.contains { $0.hasPrefix("WARNING  held       contacts with notes are edited through Contacts.app") })
        #expect(lines.contains { $0.hasPrefix("summary") && $0.contains("held 1") })
        #expect(run.err.isEmpty, "a hold is not an error")
        #expect(store.values(ofCard: "ann:icloud")?.jobTitle == nil)

        harness.cards.setPermission(.granted)
        let granted = harness.sync()
        #expect(granted.code == 0)
        #expect(harness.lines(granted).contains("updated  apple  Ann One  (job_title)"), "\(granted.out)")
        #expect(store.values(ofCard: "ann:icloud")?.jobTitle == "CTO")
        #expect(store.scriptedNotes()["ann:icloud"] == .some("Met at the 2019 conference."), "note intact")
        #expect(!harness.lines(harness.sync()).contains { $0.hasPrefix("updated") }, "fixpoint")
    }

    @Test("changes held for Contacts.app control give a banner after Sync Now")
    func contactsControlBanner() {
        var summary = UISyncSummary(held: 2)
        summary.heldForContactsControl = 2
        let banners = UIBanner.banners(
            status: nil, plan: nil, outcome: .synced(summary), deviceID: "d", now: Date())
        #expect(banners == [.contactsControlNeeded(held: 2)])
        #expect(banners.first?.message.hasPrefix("2 changes for Apple Contacts are waiting") == true)
        #expect(banners.first?.severity == .warning)
    }
}
