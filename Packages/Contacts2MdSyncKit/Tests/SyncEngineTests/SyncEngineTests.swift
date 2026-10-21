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

    @Test("a lost record map without stamps never duplicates: existing notes block creation")
    func lostMapCreateGate() throws {
        let harness = ExportHarness()
        try harness.export()
        try harness.records.save(RecordMap())
        let plan = try harness.plan()
        let reviewed = plan.reviews.filter { if case .possibleMatch = $0 { true } else { false } }
        // Every previously exported contact (all but Stella, who is stamped) matches its old note.
        #expect(plan.creates.isEmpty, "\(plan.creates.map(\.path))")
        #expect(reviewed.count == harness.files.keys.filter { $0.hasPrefix("Inbox/") }.count - 1)
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

    @Test("clustering joins on email, E.164 phone, or name+company; never on name alone")
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
            person("a", "Ann", "One") { $0.phones = [Labeled(nil, "(415) 555-0100")] },
            person("b", "Ann", "Uno") { $0.phones = [Labeled(nil, "+1 415 555 0100")] },
            person("c", "Bo", "Two") { $0.company = .plain("Acme") },
            person("d", "bo", "TWO") { $0.company = .plain("ACME") },
            person("e", "Cy", "Three"),
            person("f", "Cy", "Three"),
            person("g", "Di", "Four") { $0.phones = [Labeled(nil, "911")] },
            person("h", "Ed", "Five") { $0.phones = [Labeled(nil, "911")] },
        ]
        let clusters = Clustering.clusters(of: contacts, keyer: ExportHarness().keyer)
        #expect(clusters.map(\.memberIDs) == [["a:icloud", "b:icloud"], ["c:icloud", "d:icloud"]])
        #expect(clusters[0].reasons == ["same phone"])
        #expect(clusters[1].reasons == ["same name and company"])
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
                if case .possibleMatch(let title, let path, let reason) = $0 {
                    title == "Gail Both" && path == "People/Gail.md" && reason == "same email"
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
