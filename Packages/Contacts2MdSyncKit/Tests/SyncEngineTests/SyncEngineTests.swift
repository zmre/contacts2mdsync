import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("Export: golden files and round trip")
struct ExportGoldenTests {
    @Test("exporting the fixture address book matches the committed goldens")
    func golden() throws {
        let harness = ExportHarness()
        try harness.export()
        let differences = try GoldenFiles.compare(harness.files, with: GoldenFiles.directory("export"))
        #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
    }

    @Test("every exported note parses back to what was emitted (parse ∘ emit = id)")
    func roundTrip() throws {
        let harness = ExportHarness()
        let (plan, _) = try harness.export()
        #expect(plan.creates.count >= 55)
        for change in plan.creates {
            let text = try #require(String(data: change.data, encoding: .utf8))
            let parsed = try #require(try MarkdownCodec.parse(text).contact)
            #expect(try MarkdownCodec.encode(parsed) == text, "\(change.path)")
            #expect(MarkdownCodec.normalize(parsed) == parsed, "\(change.path)")
        }
    }

    @Test("the planner writes nothing")
    func planIsDry() throws {
        let harness = ExportHarness()
        let plan = try harness.plan()
        #expect(!plan.creates.isEmpty)
        #expect(harness.vault.paths.isEmpty)
        #expect(harness.vault.writes.isEmpty)
    }
}

@Suite("Export: idempotency and identity")
struct IdempotencyTests {
    @Test("exporting twice writes nothing the second time")
    func twice() throws {
        let harness = ExportHarness()
        try harness.export()
        harness.vault.resetWrites()
        let (plan, result) = try harness.export()
        #expect(plan.isEmpty, "creates: \(plan.creates.map(\.path)), updates: \(plan.updates.map(\.path))")
        #expect(result.created.isEmpty && result.updated.isEmpty)
        #expect(harness.vault.writes.isEmpty)
        #expect(plan.unchanged == plan.bindings.count)
    }

    @Test("a note moved to a subfolder is updated in place, not duplicated")
    func moved() throws {
        let harness = ExportHarness()
        try harness.export()
        harness.vault.move("Inbox/Jane Doe.md", to: "People/Family/Jane Doe.md")
        var contacts = harness.store.contacts
        let index = try #require(contacts.firstIndex { $0.unifiedID == "c01:icloud" })
        contacts[index].contact.jobTitle = "CEO"
        harness.store.replaceContacts(contacts)

        let (plan, _) = try harness.export()
        #expect(plan.creates.isEmpty)
        #expect(plan.updates.map(\.path) == ["People/Family/Jane Doe.md"])
        #expect(plan.updates.first?.changedFields == ["job_title", "image"])
        #expect(!harness.vault.exists("Inbox/Jane Doe.md"))
        let jane = try #require(try harness.contact(at: "People/Family/Jane Doe.md"))
        #expect(jane.jobTitle == "CEO")
        // The image path is recomputed relative to the note's new folder.
        #expect(jane.image?.path == "../../_images/00000000-0000-4000-8000-000000000001.jpg")
    }

    @Test("identity survives a lost record map when the contact is stamped")
    func stampIdentity() throws {
        let harness = ExportHarness()
        let (first, _) = try harness.export()
        // Stamp every exported contact, then forget the per-device map.
        _ = try harness.store.apply(
            AppleWriteBatch(operations: first.stamps.map { .stamp(cardID: $0.cardID, id: $0.recordID) }), author: "test"
        )
        try harness.records.save(RecordMap())
        harness.vault.resetWrites()
        let (second, _) = try harness.export()
        #expect(second.creates.isEmpty)
        #expect(harness.vault.writes.isEmpty)
    }

    @Test("a lost record map without stamps never duplicates: notes are relinked or proposed")
    func lostMapCreateGate() throws {
        let harness = ExportHarness()
        try harness.export()
        try harness.records.save(RecordMap())
        let plan = try harness.plan()
        let proposed = plan.reviews.compactMap { review -> String? in
            if case .possibleMatch(_, let path, _, _) = review { return path }
            return nil
        }
        // Every previously exported contact (all but Stella, who is stamped)
        // is either matched back to its old note (email/phone + name, first
        // import → auto) or proposed for review; nothing is created.
        #expect(plan.creates.isEmpty, "\(plan.creates.map(\.path))")
        let notes = harness.files.keys.filter { $0.hasPrefix("Inbox/") }
        let bound = Set(plan.bindings.values.map(\.path))
        #expect(notes.allSatisfy { bound.contains($0) || proposed.contains($0) })
        #expect(!proposed.isEmpty && !bound.isEmpty)
        #expect(plan.updates.isEmpty)  // same ids, same content: nothing to rewrite
    }

    @Test("a contact already stamped by another vault keeps its id here")
    func foreignStamp() throws {
        let harness = ExportHarness()
        let (plan, _) = try harness.export()
        let stella = try #require(plan.creates.first { $0.title == "Stella Stamped" })
        #expect(stella.recordID == Fixtures.stellaID)
        #expect(!plan.stamps.contains { $0.recordID == Fixtures.stellaID })
    }

    @Test("a deleted note is reported, and re-created only with restoreMissing")
    func missing() throws {
        let harness = ExportHarness()
        try harness.export()
        harness.vault.remove("Inbox/Bob Smith.md")
        let plan = try harness.plan()
        #expect(plan.creates.isEmpty)
        #expect(
            plan.reviews.contains { if case .missingFile(let title, _, _) = $0 { title == "Bob Smith" } else { false } }
        )
        let restored = try harness.plan(ExportOptions(restoreMissing: true))
        #expect(restored.creates.map(\.path) == ["Inbox/Bob Smith.md"])
    }

    @Test("a copied note (duplicate c2mdsync.id) pauses that record")
    func copied() throws {
        let harness = ExportHarness()
        try harness.export()
        let data = try #require(harness.vault.data("Inbox/Bob Smith.md"))
        harness.vault.seed("Archive/Bob Smith copy.md", data)
        var contacts = harness.store.contacts
        let index = try #require(contacts.firstIndex { $0.unifiedID == "c03:icloud" })
        contacts[index].contact.jobTitle = "Retired"
        harness.store.replaceContacts(contacts)
        let plan = try harness.plan()
        #expect(plan.updates.isEmpty)
        #expect(
            plan.reviews.contains { if case .duplicateSyncID(_, let paths) = $0 { paths.count == 2 } else { false } })
        #expect(plan.skipped.contains { $0.title == "Bob Smith" })
    }
}

@Suite("Export: duplicates and create gate")
struct DuplicateTests {
    @Test("an unlinked iCloud + Google pair produces one note and a review item")
    func unlinkedPair() throws {
        let harness = ExportHarness()
        let (plan, _) = try harness.export()
        let chrisNotes = plan.creates.filter { $0.title == "Chris Martin" }
        #expect(chrisNotes.count == 1)
        #expect(chrisNotes.first?.path == "Inbox/Chris Martin.md")
        let note = try #require(try harness.contact(at: "Inbox/Chris Martin.md"))
        // The iCloud member (c26) is the one exported.
        #expect(note.emails == [Labeled("home", "chris@example.com")])
        let cluster = plan.reviews.compactMap { review -> [ClusterMember]? in
            if case .duplicateCluster(let members, let reasons) = review, reasons.contains("same email") {
                return members
            }
            return nil
        }
        #expect(cluster.first?.map(\.unifiedID) == ["c26:icloud", "c27:google"])
        #expect(plan.skipped.contains { $0.title == "Chris Martin" })
    }

    @Test("once the primary has a note, other cluster members stay skipped")
    func clusterStable() throws {
        let harness = ExportHarness()
        try harness.export()
        let plan = try harness.plan()
        #expect(plan.creates.isEmpty)
        #expect(plan.skipped.contains { $0.title == "Chris Martin" })
    }

    @Test("clustering joins on equal names or email + compatible names; never on a phone alone")
    func clustering() {
        func person(
            _ id: String, _ given: String, _ family: String, _ build: (inout CanonicalContact) -> Void = { _ in }
        )
            -> AppleContact
        {
            Fixtures.contact(id) { contact in
                contact.name = PersonName(given: given, family: family)
                build(&contact)
            }
        }
        let contacts = [
            // A shared unlabeled phone alone joins nobody.
            person("a", "Ann", "One") { $0.phones = [Labeled(nil, "(415) 555-0100")] },
            person("b", "Ann", "Uno") { $0.phones = [Labeled(nil, "+1 415 555 0100")] },
            person("c", "Bo", "Two") { $0.company = .plain("Acme") },
            person("d", "bo", "TWO") { $0.company = .plain("ACME") },
            // Equal names cluster (no organization on either).
            person("e", "Cy", "Three"),
            person("f", "Cy", "Three"),
            person("g", "Di", "Four") { $0.phones = [Labeled(nil, "911")] },
            person("h", "Ed", "Five") { $0.phones = [Labeled(nil, "911")] },
            // Equal names, different organizations: different people.
            person("i", "Flo", "Six") { $0.company = .plain("Initech") },
            person("j", "Flo", "Six") { $0.company = .plain("Globex") },
            // Same email, incompatible names (a couple sharing an address).
            person("k", "Gus", "Seven") { $0.emails = [Labeled("home", "sevens@example.com")] },
            person("l", "Hana", "Seven") { $0.emails = [Labeled("home", "sevens@example.com")] },
        ]
        let clusters = Clustering.clusters(of: contacts, keyer: ExportHarness().keyer)
        #expect(clusters.map(\.memberIDs) == [["c:icloud", "d:icloud"], ["e:icloud", "f:icloud"]])
        #expect(clusters[0].reasons == ["same name and company"])
        #expect(clusters[1].reasons == ["same name"])
        #expect(clusters[1].links.map(\.reasons) == [["same name \"Cy Three\""]])
    }

    @Test("spouses sharing a home phone, each with an unlinked duplicate: two clusters, one per person")
    func spouses() {
        let home = Labeled<String>("home", "+1 303 555 0100")
        let contacts = [
            Fixtures.contact("john") {
                $0.name = PersonName(given: "John", family: "Doe")
                $0.phones = [home, Labeled("mobile", "+1 303 555 0111")]
                $0.emails = [Labeled("home", "john@doe.example")]
            },
            Fixtures.contact("johng", accounts: [.google]) {
                $0.name = PersonName(given: "John", family: "Doe")
                $0.phones = [home]
            },
            Fixtures.contact("jane") {
                $0.name = PersonName(given: "Jane", family: "Doe")
                $0.phones = [home, Labeled("mobile", "+1 303 555 0122")]
                $0.emails = [Labeled("home", "jane@doe.example")]
            },
            Fixtures.contact("janeg", accounts: [.google]) {
                $0.name = PersonName(given: "Jane", family: "Doe")
                $0.phones = [Labeled("home", "(303) 555-0100")]
                $0.emails = [Labeled("work", "JANE@doe.example")]
            },
        ]
        let clusters = Clustering.clusters(of: contacts, keyer: ExportHarness().keyer)
        #expect(clusters.map(\.memberIDs) == [["jane:icloud", "janeg:google"], ["john:icloud", "johng:google"]])
        #expect(clusters[0].reasons == ["same email", "same name"])
        #expect(
            clusters[0].links.first?.reasons == [
                "same name \"Jane Doe\"", "same email jane@doe.example", "names match (Jane / Jane)",
            ])
    }

    @Test("nickname + same email clusters; siblings sharing a mobile do not")
    func nicknamesAndSiblings() {
        let contacts = [
            Fixtures.contact("bob") {
                $0.name = PersonName(given: "Bob", family: "Smith")
                $0.emails = [Labeled("home", "rsmith@example.com")]
                $0.phones = [Labeled("mobile", "+1 212 555 0100")]
            },
            Fixtures.contact("robert", accounts: [.google]) {
                $0.name = PersonName(given: "Robert", family: "Smith")
                $0.emails = [Labeled(nil, "RSmith@example.com")]
                $0.phones = [Labeled("iphone", "(212) 555-0100")]
            },
            Fixtures.contact("amy") {
                $0.name = PersonName(given: "Amy", family: "Park")
                $0.phones = [Labeled("mobile", "+1 646 555 0100")]
            },
            Fixtures.contact("beth") {
                $0.name = PersonName(given: "Beth", family: "Park")
                $0.phones = [Labeled("mobile", "+1 646 555 0100")]
            },
        ]
        let clusters = Clustering.clusters(of: contacts, keyer: ExportHarness().keyer)
        #expect(clusters.map(\.memberIDs) == [["bob:icloud", "robert:google"]])
        #expect(clusters[0].reasons == ["same email", "same phone"])
        #expect(
            clusters[0].links.first?.reasons == [
                "same email rsmith@example.com", "same mobile +1 212 555 0100", "names match (Bob / Robert)",
            ])
    }

    @Test("organization-only contacts cluster on the same organization name")
    func organizations() {
        let contacts = [
            Fixtures.contact("o1", kind: .organization) { $0.company = .plain("Acme Corp") },
            Fixtures.contact("o2", kind: .organization, accounts: [.google]) { $0.company = .plain("ACME corp") },
            Fixtures.contact("p1") {
                $0.name = PersonName(given: "Wendy", family: "Worker")
                $0.company = .plain("Acme Corp")
            },
        ]
        let clusters = Clustering.clusters(of: contacts, keyer: ExportHarness().keyer)
        #expect(clusters.map(\.memberIDs) == [["o1:icloud", "o2:google"]])
        #expect(clusters[0].reasons == ["same organization"])
    }

    @Test("an existing unlinked note with the same email blocks creation")
    func createGate() throws {
        let vault = InMemoryVault(files: [
            "People/Gail.md": "---\ntype: person\ntitle: Gail\nemails: gail@example.com\n---\nhand-written\n"
        ])
        let harness = ExportHarness(vault: vault)
        let plan = try harness.plan()
        #expect(!plan.creates.contains { $0.title == "Gail Both" })
        #expect(
            plan.reviews.contains {
                if case .possibleMatch(let contact, let path, let confidence, let reasons) = $0 {
                    contact.title == "Gail Both" && path == "People/Gail.md"
                        && reasons == ["same email", "names match (Gail / Gail)"] && confidence == 0.7
                } else {
                    false
                }
            })
        #expect(plan.markdownOnly == 1)
    }

    @Test("new filenames avoid stems anywhere in the vault")
    func filenameCollision() throws {
        let vault = InMemoryVault(files: ["Elsewhere/Bob Smith.md": "# not a contact\n"])
        let plan = try ExportHarness(vault: vault).plan()
        #expect(plan.creates.contains { $0.path == "Inbox/Bob Smith 2.md" })
        #expect(plan.creates.contains { $0.path == "Inbox/John Smith.md" })
        #expect(plan.creates.contains { $0.path == "Inbox/John Smith (Globex).md" })
    }
}
