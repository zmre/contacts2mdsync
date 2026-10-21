import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("Export: preserving markdown")
struct PreservationTests {
    /// Exports, then lets the user edit Jane's note by hand.
    private func editedJane(_ edit: (String) -> String) throws -> ExportHarness {
        let harness = ExportHarness()
        try harness.export()
        let text = try #require(harness.vault.text("Inbox/Jane Doe.md"))
        harness.vault.seed("Inbox/Jane Doe.md", Data(edit(text).utf8))
        return harness
    }

    @Test("unknown keys, comments, plain aliases, unmanaged tags and mbr-only edges survive an update")
    func markdownOnlyData() throws {
        let harness = try editedJane { text in
            text.replacingOccurrences(of: "type: person\n", with: "type: person\n# keep me\ngender: female\n")
                .replacingOccurrences(
                    of: "  - maiden_name: Jane Smith\n", with: "  - maiden_name: Jane Smith\n  - Janie\n"
                )
                .replacingOccurrences(of: "  - close_friends\n", with: "  - close_friends\n  - vip\n")
                .replacingOccurrences(
                    of: "    label: father\n",
                    with: "    label: father\n    met: 1999\n  - type: employer\n    to: \"[[Acme Corp]]\"\n")
        }
        var contacts = harness.store.contacts
        let index = try #require(contacts.firstIndex { $0.unifiedID == "c01:icloud" })
        contacts[index].contact.department = "Research"
        harness.store.replaceContacts(contacts)
        let (plan, _) = try harness.export()
        #expect(plan.updates.map(\.changedFields) == [["department"]])
        let text = try #require(harness.vault.text("Inbox/Jane Doe.md"))
        #expect(text.contains("# keep me\ngender: female\n"))
        #expect(text.contains("  - Janie\n"))
        #expect(text.contains("  - vip\n"))
        #expect(text.contains("    met: 1999\n  - type: employer\n"))
        #expect(text.contains("department: Research\n"))
    }

    @Test("markdown display forms with the same comparison key are kept")
    func displayForms() throws {
        let harness = try editedJane { text in
            text.replacingOccurrences(of: "  - work: \"(415) 555-0199\"\n", with: "  - work: \"+1 415-555-0199\"\n")
                .replacingOccurrences(of: "jane@example.com", with: "Jane@Example.com")
        }
        harness.vault.resetWrites()
        let (plan, _) = try harness.export()
        #expect(plan.updates.isEmpty)
        #expect(harness.vault.writes.isEmpty)
    }

    @Test("a hand-edited title is kept (title is markdown-owned) and links follow it")
    func title() throws {
        let harness = try editedJane { $0.replacingOccurrences(of: "title: Jane Doe\n", with: "title: Jane Q. Doe\n") }
        let (plan, _) = try harness.export()
        #expect(plan.updates.map(\.path).sorted() == ["Inbox/Bob Smith.md", "Inbox/John Doe.md"])
        #expect(plan.updates.allSatisfy { $0.changedFields == ["relationships"] })
        #expect(try harness.contact(at: "Inbox/Jane Doe.md")?.title == "Jane Q. Doe")
        #expect(try harness.contact(at: "Inbox/John Doe.md")?.relationships.first?.target == .wikilink("Jane Q. Doe"))
    }

    @Test("without the notes entitlement the markdown body is never touched")
    func notesOff() throws {
        let harness = ExportHarness(store: Fixtures.store(notesEntitled: false))
        try harness.export()
        #expect(try harness.contact(at: "Inbox/Jane Doe.md")?.body == nil)
        let text = try #require(harness.vault.text("Inbox/Jane Doe.md"))
        harness.vault.seed("Inbox/Jane Doe.md", Data((text + "My own notes.\n").utf8))
        let (plan, _) = try harness.export()
        #expect(plan.updates.isEmpty)
        #expect(try harness.contact(at: "Inbox/Jane Doe.md")?.body == "My own notes.\n")
    }

    @Test("with notes, the Apple note becomes the body")
    func notesOn() throws {
        let harness = ExportHarness()
        try harness.export()
        #expect(
            try harness.contact(at: "Inbox/Jane Doe.md")?.body == "Met at the **2019** conference.\n\n- likes tea\n")
    }

    @Test("Apple groups become managed tags, recorded in config.yaml")
    func groups() throws {
        let harness = ExportHarness()
        try harness.export()
        #expect(try harness.contact(at: "Inbox/Jane Doe.md")?.tags == ["family", "close_friends"])
        let config = try #require(try VaultConfig.load(from: harness.vault)).config
        #expect(config.groups.map(\.tag) == ["close_friends", "family", "work"])
        #expect(config.vaultID == ExportHarness.vaultID)
    }

    @Test("leaving a group removes only that managed tag")
    func groupRemoval() throws {
        let harness = try editedJane {
            $0.replacingOccurrences(of: "  - close_friends\n", with: "  - close_friends\n  - vip\n")
        }
        var contacts = harness.store.contacts
        let index = try #require(contacts.firstIndex { $0.unifiedID == "c01:icloud" })
        contacts[index].groupIDs = [Fixtures.closeFriends.id]
        harness.store.replaceContacts(contacts)
        try harness.export()
        #expect(try harness.contact(at: "Inbox/Jane Doe.md")?.tags == ["close_friends", "vip"])
    }
}
