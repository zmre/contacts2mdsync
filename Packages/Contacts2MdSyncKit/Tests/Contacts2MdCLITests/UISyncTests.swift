import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// The app's two-way sync adapters (conflicts, deletions, Add to Contacts,
/// vault options, Sync Now outcomes and banners) over a fake store and vault.
@Suite("UI sync adapters")
struct UISyncTests {
    /// The app's reader: same environment as the CLI harness, trigger `GUI`.
    func reader(_ harness: CLIHarness) -> UIVaultReader {
        var environment = harness.environment()
        environment.trigger = "GUI"
        return UIVaultReader(root: URL(filePath: "/vault"), environment: environment)
    }

    func data(_ reader: UIVaultReader) throws -> UIVaultData { try #require(try reader.read()) }

    func queues(_ reader: UIVaultReader) throws -> UIReviewQueues { UIReviewQueues(data: try data(reader)) }

    func enableWrites(_ reader: UIVaultReader, stamp: Bool = false) throws {
        try reader.setOptions(UIVaultOptions(appleWrites: true, stampContacts: stamp))
    }

    /// Ann: job title and email edited differently on both sides; Bob: job title.
    func conflicted() throws -> (CLIHarness, UIVaultReader) {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        try enableWrites(reader)
        _ = try reader.sync()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: Markdown")
        harness.editNote("Inbox/Ann One.md", "ann@example.com", with: "ann@markdown.example")
        harness.store.editCard("ann:icloud") { contact in
            contact.jobTitle = "Contacts"
            contact.emails = [Labeled("home", "ann@contacts.example")]
        }
        harness.editNote("Inbox/Bob Two.md", "job_title: Engineer", with: "job_title: Chef")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Baker" }
        _ = try reader.plan()
        return (harness, reader)
    }

    // MARK: - Conflicts

    @Test("conflicts are grouped per record, one field per conflict, with engine options")
    func conflictGrouping() throws {
        let (harness, reader) = try conflicted()
        defer { withExtendedLifetime(harness) {} }
        let queues = try queues(reader)
        #expect(queues.conflicts.map(\.title) == ["Ann One", "Bob Two"])
        #expect(queues.counts.conflicts == 2)
        let ann = try #require(queues.conflicts.first)
        #expect(ann.path == "Inbox/Ann One.md")
        #expect(ann.folderText == "Inbox/")
        #expect(ann.cardIDs == ["ann:icloud"])
        #expect(ann.since == harness.clock.now)
        let job = try #require(ann.fields.first { $0.name == "Job" })
        #expect(job.contacts == "Contacts")
        #expect(job.markdown == "Markdown")
        #expect(job.previous == "Engineer")
        #expect(job.since == harness.clock.now)
        #expect(job.changeSummary() == "Contacts → “Contacts”, Markdown → “Markdown”")
        #expect(job.options == [.keepContacts, .keepMarkdown])
        #expect(job.id.hasPrefix("conflict-"))
        let email = try #require(ann.fields.first { $0.name == "Email" })
        #expect(email.label == "home")
        #expect(email.contacts == "ann@contacts.example")
        #expect(email.markdown == "ann@markdown.example")
        #expect(email.options.contains(.keepBoth))
        // The stored status agrees (one per field).
        #expect(try data(reader).status.conflicts == 3)
    }

    @Test("resolutions map to `review decide` choices; Keep Both only where offered")
    func conflictChoices() throws {
        let (harness, reader) = try conflicted()
        defer { withExtendedLifetime(harness) {} }
        let ann = try #require(try queues(reader).conflicts.first)
        let both = ann.choices(preferring: .keepBoth)
        #expect(both.count == 1)
        #expect(both.first?.fieldID == ann.fields.first { $0.name == "Email" }?.id)
        #expect(ann.choices(preferring: .keepMarkdown).count == 2)
        let job = try #require(ann.fields.first { $0.name == "Job" })
        let choice = UIConflictChoice(recordID: ann.id, fieldID: job.id, resolution: .keepMarkdown)
        #expect(choice.decision == .choice(itemID: job.id, choice: "markdown"))
        #expect(UIConflictResolution.keepContacts.engine == .keepApple)
        #expect(UIConflictResolution(.keepBoth) == .keepBoth)

        try reader.record([choice.decision])
        let log = try #require(
            harness.vault.text(".c2mdsync/devices/00000000-0000-4000-8000-00000000d001/decisions.jsonl"))
        #expect(log.contains("\"kind\":\"resolve-conflict\"") && log.contains("\"choice\":\"markdown\""))
        // Decided: gone from the queue, applied by the next sync.
        #expect(try queues(reader).conflicts.first?.fields.contains { $0.id == job.id } == false)
        _ = try reader.sync()
        #expect(harness.store.contact(withCard: "ann:icloud")?.contact.jobTitle == "Markdown")
    }

    @Test("field names read as plain English")
    func fieldNames() {
        #expect(UIConflictField.displayName("job_title") == "Job")
        #expect(UIConflictField.displayName("phones") == "Phone")
        #expect(UIConflictField.displayName("apple.nickname") == "Nickname")
        #expect(UIConflictField.displayName("phonetic_given_name") == "Phonetic given name")
    }

    // MARK: - Deletions

    @Test("deletion options map to the engine's choices, defaults first")
    func deletionChoices() {
        #expect(UIDeletionOption.options(for: .contacts).map(\.choice) == ["keep", "trash", "restore"])
        #expect(UIDeletionOption.options(for: .markdown).map(\.choice) == ["restore", "unlink", "delete-contact"])
        #expect(UIDeletionOption.options(for: .contacts).first?.isDestructive == false)
        #expect(UIDeletionOption.options(for: .markdown).first?.isDestructive == false)
        #expect(UIDeletionOption.allCases.filter(\.isDestructive) == [.deleteFile, .deleteAppleContact])
        #expect(
            UIDeletionChoice(id: "deleted-1", option: .deleteFile).decision
                == .choice(itemID: "deleted-1", choice: "trash"))
    }

    @Test("Deleted in Contacts: queued after the second snapshot; Delete File trashes the note")
    func deletedInContacts() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        harness.store.deleteContact(withCard: "cy:icloud")
        _ = try reader.sync()
        #expect(try queues(reader).deletions.isEmpty)  // first sighting only
        harness.clock.advance(11 * 60)
        _ = try reader.sync()
        let row = try #require(try queues(reader).deletions.first)
        #expect(row.side == .contacts)
        #expect(row.title == "Cy Three")
        #expect(row.path == "Inbox/Cy Three.md")
        #expect(row.isActionable)
        #expect(row.options == [.keepFileUnlink, .deleteFile, .restoreContact])
        #expect(try queues(reader).counts.deletions == 1)
        try reader.record([UIDeletionChoice(id: row.id, option: .deleteFile).decision])
        #expect(try queues(reader).deletions.isEmpty)
        _ = try reader.sync()
        #expect(!harness.vault.exists("Inbox/Cy Three.md"))
    }

    @Test("Deleted in Markdown: an export only lists it; a sync makes it actionable with the contact's cards")
    func deletedInMarkdown() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        harness.vault.remove("Inbox/Bob Two.md")
        _ = harness.run(["plan", "--root", "/vault", "--one-way"])
        let listed = try #require(try queues(reader).deletions.first)
        #expect(listed.side == .markdown)
        #expect(!listed.isActionable)
        _ = try reader.sync()
        let row = try #require(try queues(reader).deletions.first)
        #expect(row.id == listed.id)  // same item id (`missing-…`)
        #expect(row.isActionable)
        #expect(row.path == "Inbox/Bob Two.md")
        #expect(row.cardIDs == ["bob:icloud"])
        #expect(row.accountsText == "iCloud")
        try reader.record([UIDeletionChoice(id: row.id, option: .restoreFile).decision])
        _ = try reader.sync()
        #expect(harness.vault.exists("Inbox/Bob Two.md"))
    }

    // MARK: - Add to Contacts

    @Test("Add to Contacts: default for notes without a match; recorded, then created by the next sync")
    func addToContacts() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        harness.vault.seed("People/Zed Four.md", Data("---\ntype: person\nfirst_name: Zed\n---\n".utf8))
        _ = try reader.plan()
        var row = try #require(try queues(reader).markdownOnly.first)
        #expect(row.path == "People/Zed Four.md")
        #expect(row.defaultAction == .addToContacts)
        #expect(UIMarkdownOnlyAction.addToContacts.decisions(for: row) == [.addContact(path: "People/Zed Four.md")])
        try reader.record(UIMarkdownOnlyAction.addToContacts.decisions(for: row))
        row = try #require(try queues(reader).markdownOnly.first)
        #expect(row.decidedNote == "Will be added to Contacts on the next sync")
        #expect(!row.needsReview)
        try enableWrites(reader)
        let before = harness.store.contacts.count
        let summary = try #require(try reader.sync().summary)
        #expect(summary.apple.created == 1)
        #expect(harness.store.contacts.count == before + 1)
        #expect(try queues(reader).markdownOnly.isEmpty)
    }

    // MARK: - Vault options

    @Test("vault options round-trip through config.yaml; other keys stay")
    func optionsRoundTrip() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        #expect(try data(reader).options == UIVaultOptions(appleWrites: false, stampContacts: false))
        let before = try #require(harness.vault.text(".c2mdsync/config.yaml"))
        let saved = try reader.setOptions(UIVaultOptions(appleWrites: true, stampContacts: true))
        #expect(saved == UIVaultOptions(appleWrites: true, stampContacts: true))
        let text = try #require(harness.vault.text(".c2mdsync/config.yaml"))
        #expect(text.contains("apple_writes: enabled\n") && text.contains("stamp_contacts: true\n"))
        #expect(try data(reader).options == saved)
        #expect(try data(reader).status.appleWritesEnabled)
        try reader.setOptions(UIVaultOptions(appleWrites: false, stampContacts: false))
        let after = try #require(harness.vault.text(".c2mdsync/config.yaml"))
        #expect(after.contains("apple_writes: disabled\n"))
        #expect(after.contains("default_folder: Inbox\n") && before.contains("default_folder: Inbox\n"))
    }
}
