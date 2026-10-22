import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// "N notes outside contacts link to [[Old]]" with Update Links (architecture §8).
@Suite("Links to renamed contacts in other notes")
struct RenamedLinksTests {
    static let journal = "Journal/2027-01-14.md"
    static let text = """
        ---
        title: Thursday
        ---
        Met [[Ann One|Ann]] about [[ann one#Work]]. ![[Ann One]] [[Ann Onesie]] [[Bob Two]]

        """

    static func renamed() throws -> (CLIHarness, UIVaultReader) {
        let harness = CLIHarness.exported()
        harness.vault.seed(Self.journal, Data(Self.text.utf8))
        #expect(harness.sync().code == 0)
        harness.store.editCard("ann:icloud") { $0.name.family = "Smith" }
        let run = harness.sync()
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(harness.vault.text("Inbox/Ann One.md")?.contains("title: Ann Smith") == true)
        return (harness, MaintenanceCommandTests.reader(harness))
    }

    @Test("a regenerated title is reported with the non-contact notes still linking the old one")
    func report() throws {
        let (harness, reader) = try Self.renamed()
        let links = try reader.renamedLinks()
        #expect(links.count == 1, "\(harness.vault.paths)")  // `harness` keeps the state folder alive
        let ann = try #require(links.first)
        #expect(ann.rename.oldTitle == "Ann One" && ann.rename.newTitle == "Ann Smith")
        #expect(ann.paths == [Self.journal])
        #expect(ann.summary == "1 note outside contacts links to [[Ann One]]")
    }

    @Test("Update Links rewrites every form of the link and nothing else; then nothing is reported")
    func update() throws {
        let (harness, reader) = try Self.renamed()
        let ann = try #require(try reader.renamedLinks().first)
        let contactNotes = harness.vault.paths.filter { $0.hasPrefix("Inbox/") }.map { harness.vault.text($0) }
        #expect(try reader.updateLinks(ann) == [Self.journal])
        #expect(
            harness.vault.text(Self.journal)
                == """
                ---
                title: Thursday
                ---
                Met [[Ann Smith|Ann]] about [[Ann Smith#Work]]. ![[Ann Smith]] [[Ann Onesie]] [[Bob Two]]

                """)
        #expect(harness.vault.paths.filter { $0.hasPrefix("Inbox/") }.map { harness.vault.text($0) } == contactNotes)
        #expect(try reader.renamedLinks().isEmpty)
        #expect(harness.sync().code == 0)
    }

    @Test("Dismiss forgets the rename; the note is left as it was")
    func dismiss() throws {
        let (harness, reader) = try Self.renamed()
        let ann = try #require(try reader.renamedLinks().first)
        try reader.dismissRename(ann.rename)
        #expect(try reader.renamedLinks().isEmpty)
        #expect(harness.vault.text(Self.journal) == Self.text)
    }
}
