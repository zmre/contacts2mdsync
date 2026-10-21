import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// Small address books for focused scenarios.
enum Book {
    static func person(
        _ id: String, _ given: String, _ family: String, accounts: [AccountKind] = [.iCloud], stamp: UUID? = nil,
        _ build: (inout CanonicalContact) -> Void = { _ in }
    ) -> AppleContact {
        Fixtures.contact(id, accounts: accounts, stamp: stamp) { contact in
            contact.name = PersonName(given: given, family: family)
            build(&contact)
        }
    }

    static func store(_ contacts: [AppleContact]) -> FakeContactStore {
        FakeContactStore(contacts: contacts, containers: Fixtures.containers, groups: [], notesEntitled: false)
    }

    static func reviews<T>(_ plan: ExportPlan, _ pick: (ReviewItem) -> T?) -> [T] { plan.reviews.compactMap(pick) }

    struct Match {
        var id: String
        var path: String
        var confidence: Double
    }

    static func matches(_ plan: ExportPlan) -> [Match] {
        reviews(plan) { review in
            if case .possibleMatch(_, let path, let confidence, _) = review {
                return Match(id: review.id, path: path, confidence: confidence)
            }
            return nil
        }
    }
}

@Suite("Adoption of existing notes")
struct AdoptionTests {
    static let annNote = """
        ---
        type: person
        title: Ann One
        # my own notes on Ann
        gender: female
        emails:
          - home: Ann@Example.com
          - work: ann@work.example
        ---
        Met at the library.

        """

    @Test("an unambiguous email + name match is adopted on the first import, keeping user content")
    func autoAdopt() throws {
        let store = Book.store([
            Book.person("ann", "Ann", "One") { contact in
                contact.emails = [Labeled("home", "ann@example.com")]
                contact.phones = [Labeled("mobile", "(415) 555-0100")]
                contact.jobTitle = "Librarian"
            },
            Book.person("cy", "Cy", "Three"),
        ])
        let harness = ExportHarness(store: store, vault: InMemoryVault(files: ["People/Ann.md": Self.annNote]))
        let (plan, _) = try harness.export()
        #expect(plan.autoAdopt)
        #expect(plan.adoptions.map(\.path) == ["People/Ann.md"])
        #expect(plan.adoptions.first?.detail == "adopted (same email, same name)")
        #expect(plan.creates.map(\.path) == ["Inbox/Cy Three.md"])
        #expect(plan.markdownOnly == 0)
        let text = try #require(harness.vault.text("People/Ann.md"))
        #expect(text.contains("# my own notes on Ann\ngender: female\n"))
        #expect(text.hasSuffix("---\nMet at the library.\n"))
        let ann = try #require(try harness.contact(at: "People/Ann.md"))
        #expect(ann.title == "Ann One")
        #expect(ann.sync.id != nil)
        // Apple's email keeps the markdown spelling; the markdown-only email stays.
        #expect(ann.emails == [Labeled("home", "Ann@Example.com"), Labeled("work", "ann@work.example")])
        #expect(ann.phones == [Labeled("mobile", "(415) 555-0100")])
        #expect(ann.jobTitle == "Librarian")
        #expect(try harness.records.load()[try #require(ann.sync.id)]?.path == "People/Ann.md")

        harness.vault.resetWrites()
        let again = try harness.export().plan
        #expect(again.isEmpty && again.reviews.isEmpty, "\(again.updates.map(\.path)) \(again.reviews)")
        #expect(harness.vault.writes.isEmpty)
    }

    @Test("two notes with the same email: proposed, nothing adopted or created")
    func ambiguousNotes() throws {
        let store = Book.store([Book.person("ann", "Ann", "One") { $0.emails = [Labeled("home", "ann@example.com")] }])
        let vault = InMemoryVault(files: ["People/Ann.md": Self.annNote, "Archive/Ann (old).md": Self.annNote])
        let plan = try ExportHarness(store: store, vault: vault).plan()
        #expect(plan.adoptions.isEmpty && plan.creates.isEmpty)
        #expect(Book.matches(plan).map(\.path) == ["Archive/Ann (old).md"])
        #expect(plan.skipped.map(\.title) == ["Ann One"])
        #expect(plan.markdownOnly == 2)
        #expect(plan.needsReview)
    }

    @Test("a note matching nothing stays a markdown-only candidate")
    func noMatch() throws {
        let store = Book.store([Book.person("cy", "Cy", "Three") { $0.emails = [Labeled(nil, "cy@example.com")] }])
        let vault = InMemoryVault(files: ["People/Zed.md": "---\ntype: person\ntitle: Zed Zero\n---\n"])
        let plan = try ExportHarness(store: store, vault: vault).plan()
        #expect(plan.creates.map(\.path) == ["Inbox/Cy Three.md"])
        #expect(plan.markdownOnly == 1)
        #expect(plan.reviews.isEmpty && !plan.needsReview)
    }

    @Test("a name-only match is proposed and blocks creation")
    func nameOnly() throws {
        let store = Book.store([Book.person("bob", "Bob", "Smith") { $0.emails = [Labeled(nil, "bob@example.com")] }])
        let vault = InMemoryVault(files: ["People/Bob Smith.md": "---\ntype: person\ntitle: Bob Smith\n---\nFriend.\n"])
        let plan = try ExportHarness(store: store, vault: vault).plan()
        #expect(plan.creates.isEmpty)
        #expect(Book.matches(plan).map(\.confidence) == [0.3])
    }

    @Test("after the first import a strong match is proposed; `adopt` binds it on the next run")
    func decidedAdoption() throws {
        let store = Book.store([Book.person("cy", "Cy", "Three")])
        let harness = ExportHarness(store: store)
        try harness.export()
        harness.vault.seed(
            "People/Dee.md", Data("---\ntype: person\ntitle: Dee Four\nemails: dee@example.com\n---\n".utf8))
        store.replaceContacts(
            store.contacts + [Book.person("dee", "Dee", "Four") { $0.emails = [Labeled(nil, "dee@example.com")] }])
        let proposed = try harness.plan()
        #expect(!proposed.autoAdopt)
        let match = try #require(Book.matches(proposed).first)
        #expect(match.confidence == 0.9 && match.path == "People/Dee.md")
        #expect(proposed.creates.isEmpty)

        try harness.decide(match.id, "adopt")
        let (adopted, _) = try harness.export()
        #expect(adopted.adoptions.map(\.path) == ["People/Dee.md"])
        #expect(adopted.adoptions.first?.detail == "adopted (decision)")
        #expect(adopted.reviews.isEmpty)
        #expect(try harness.contact(at: "People/Dee.md")?.sync.id != nil)
        #expect(try harness.plan().isEmpty)
    }

    @Test("`ignore` and `distinct` let the contact get its own note")
    func ignoreAndDistinct() throws {
        for choice in ["ignore", "distinct"] {
            let store = Book.store([Book.person("bob", "Bob", "Smith")])
            let vault = InMemoryVault(files: ["People/Bob Smith.md": "---\ntype: person\ntitle: Bob Smith\n---\n"])
            let harness = ExportHarness(store: store, vault: vault)
            let match = try #require(Book.matches(try harness.plan()).first)
            try harness.decide(match.id, choice)
            let plan = try harness.plan()
            #expect(plan.creates.map(\.path) == ["Inbox/Bob Smith 2.md"], "\(choice)")
            #expect(plan.reviews.isEmpty, "\(choice)")
            #expect(plan.markdownOnly == (choice == "ignore" ? 0 : 1))
            #expect(plan.ignoredCandidates == (choice == "ignore" ? 1 : 0))
            #expect(!plan.needsReview)
        }
    }

    @Test("an organization note is adopted by an organization contact")
    func organization() throws {
        let store = Book.store([
            Fixtures.contact("acme", kind: .organization) { contact in
                contact.company = .plain("Acme Corp")
                contact.emails = [Labeled("work", "info@acme.example")]
            }
        ])
        let note = "---\ntype: organization\ntitle: Acme Corp\nemails:\n  - info@acme.example\n---\n"
        let harness = ExportHarness(store: store, vault: InMemoryVault(files: ["Orgs/Acme.md": note]))
        let plan = try harness.plan()
        #expect(plan.adoptions.map(\.path) == ["Orgs/Acme.md"])
    }
}
