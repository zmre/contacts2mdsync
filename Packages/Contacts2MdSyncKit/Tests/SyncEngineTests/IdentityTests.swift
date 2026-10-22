import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// The id of the plan's duplicate cluster review.
func clusterID(_ plan: ExportPlan) throws -> String {
    try #require(plan.reviews.first { if case .duplicateCluster = $0 { true } else { false } }?.id)
}

@Suite("Decisions")
struct DecisionTests {
    /// An unlinked iCloud + Google pair sharing an email.
    private func pairHarness() -> ExportHarness {
        let email = [Labeled<String>("home", "chris@example.com")]
        let store = Book.store([
            Book.person("c1", "Chris", "Martin") { $0.emails = email },
            Book.person("c2", "Chris", "Martin", accounts: [.google]) { $0.emails = email },
        ])
        return ExportHarness(store: store)
    }

    @Test("`distinct` stops a cluster being reported and exports both members")
    func distinct() throws {
        let harness = pairHarness()
        let first = try harness.export().plan
        #expect(first.creates.map(\.path) == ["Inbox/Chris Martin.md"])
        let id = try clusterID(first)
        #expect(try harness.plan().reviews.map(\.id) == [id])  // stable id across runs
        try harness.decide(id, "distinct")
        let (plan, _) = try harness.export()
        #expect(plan.reviews.isEmpty && !plan.needsReview)
        #expect(plan.creates.map(\.path) == ["Inbox/Chris Martin 2.md"])
        let after = try harness.plan()
        #expect(after.isEmpty && after.reviews.isEmpty)
    }

    @Test("`only:N` excludes the other members silently")
    func syncOnly() throws {
        let harness = pairHarness()
        let id = try clusterID(try harness.export().plan)
        try harness.decide(id, "only:1")
        let plan = try harness.plan()
        #expect(plan.reviews.isEmpty && !plan.needsReview)
        #expect(plan.excludedByDecision == 1)
        #expect(plan.creates.isEmpty && plan.isEmpty)
        #expect(plan.skipped.map(\.needsReview) == [false])
    }

    @Test("`keep:N` settles a copied note; the copy is left alone")
    func duplicateKeep() throws {
        let harness = ExportHarness(store: Book.store([Book.person("bob", "Bob", "Smith")]))
        try harness.export()
        let data = try #require(harness.vault.data("Inbox/Bob Smith.md"))
        harness.vault.seed("Archive/Bob copy.md", data)
        let paused = try harness.plan()
        let review = try #require(paused.reviews.first)
        guard case .duplicateSyncID(_, let paths) = review else {
            Issue.record("expected a copied-note review, got \(review)")
            return
        }
        #expect(paths == ["Archive/Bob copy.md", "Inbox/Bob Smith.md"])
        try harness.decide(review.id, "keep:2")
        try harness.editContact("bob:icloud") { $0.contact.jobTitle = "Retired" }
        let plan = try harness.export().plan
        #expect(plan.reviews.isEmpty)
        #expect(plan.updates.map(\.path) == ["Inbox/Bob Smith.md"])
        #expect(harness.vault.data("Archive/Bob copy.md") == data)
    }

    @Test("decision logs are the union of every device's log; bad lines are reported, unknown kinds ignored")
    func logUnion() throws {
        let vault = InMemoryVault()
        let deviceA = DeviceIdentity(id: "a", name: "A")
        let deviceB = DeviceIdentity(id: "b", name: "B")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try DecisionLog.append(
            [Decision(kind: .ignoreCandidate, createdAt: start, device: deviceA, path: "x.md")], deviceID: "a",
            fs: vault)
        try DecisionLog.append(
            [
                Decision(
                    kind: .adopt, createdAt: start - 10, device: deviceB,
                    contacts: [ContactRef(cardIDs: ["c"], title: "C")], path: "y.md")
            ],
            deviceID: "b", fs: vault)
        try DecisionLog.append(
            [Decision(kind: .ignoreCandidate, createdAt: start + 5, device: deviceA, path: "z.md")], deviceID: "a",
            fs: vault)
        let logB = try #require(vault.text(DecisionLog.path(deviceID: "b")))
        let futureDecision = """
            {"id":"\(UUID().uuidString)","kind":"future-thing","at":"2027-01-15T08:00:00Z","device_id":"b"}
            """
        vault.seed(
            DecisionLog.path(deviceID: "b"),
            Data((logB + "not json\n" + futureDecision + "\n").utf8))
        let (decisions, problems) = try DecisionLog.readAll(vault)
        #expect(decisions.count == 4)
        #expect(decisions.first?.path == "y.md" && decisions.last?.path == "z.md")  // oldest first
        #expect(problems == [".c2mdsync/devices/b/decisions.jsonl:2: unreadable decision"])
        let set = DecisionSet(decisions)
        #expect(set.all.count == 3)
        #expect(set.isIgnored(path: "z.md", syncID: nil))
        #expect(set.adoption(ofNoteAt: "y.md")?.cardIDs == ["c"])
        #expect(throws: DecisionLog.LogError.self) { try DecisionLog.append(decisions, deviceID: "../x", fs: vault) }
    }

    @Test("review items: choices map to decisions; invalid choices are rejected")
    func choices() throws {
        let device = DeviceIdentity(id: "a", name: "A")
        let members = [
            ClusterMember(unifiedID: "u1", title: "X", accounts: [.iCloud], path: nil, cardIDs: ["i"]),
            ClusterMember(unifiedID: "u2", title: "X", accounts: [.google], path: nil, cardIDs: ["g"]),
        ]
        let cluster = ReviewItem.duplicateCluster(members: members, reasons: ["same email"])
        #expect(cluster.choices == ["distinct", "only:1", "only:2"])
        let only = try cluster.decisions(for: "only:2", device: device, at: Date())
        #expect(only.first?.kind == .syncOnly)
        #expect(only.first?.contacts.map(\.cardIDs) == [["g"], ["i"]])
        #expect(throws: ReviewItem.ChoiceError.self) { try cluster.decisions(for: "adopt", device: device, at: Date()) }
        let missing = ReviewItem.missingFile(title: "X", id: UUID(), lastPath: nil)
        #expect(throws: ReviewItem.ChoiceError.self) { try missing.decisions(for: "x", device: device, at: Date()) }
        // Ids do not depend on unified ids or member order.
        let renamed = ReviewItem.duplicateCluster(
            members: members.reversed().map {
                var member = $0; member.unifiedID += "-new"; return member
            },
            reasons: [])
        #expect(renamed.id == cluster.id)
        #expect(cluster.id.hasPrefix("dup-"))
    }
}

@Suite("Linked contacts (spike S4/S9 behaviours)")
struct LinkedContactTests {
    @Test("synthesized unified ids that change every snapshot do not break idempotency")
    func volatileUnifiedIDs() throws {
        let store = Fixtures.store()
        store.setSynthesizeLinkedIDs(true)
        let harness = ExportHarness(store: store)
        let (first, _) = try harness.export()
        harness.vault.resetWrites()
        let second = try harness.export().plan
        #expect(second.isEmpty, "\(second.creates.map(\.path)) \(second.updates.map(\.path))")
        #expect(Set(second.bindings.keys) == Set(first.bindings.keys))
        #expect(harness.vault.writes.isEmpty)
        let linked = try #require(first.bindings.values.first { $0.cards.count > 1 })
        #expect(second.bindings.values.contains { $0.cardIDs == linked.cardIDs && $0.unifiedID != linked.unifiedID })
    }

    @Test("a Google card id that changes after export relinks its record: no duplicate, no delete")
    func googleChurn() throws {
        let store = Book.store([
            Book.person("gail", "Gail", "Green", accounts: [.google]) { $0.emails = [Labeled(nil, "gail@example.com")] }
        ])
        let harness = ExportHarness(store: store)
        let (first, _) = try harness.export()
        let id = try #require(first.bindings.keys.first)
        #expect(first.bindings[id]?.cards.first?.isTrusted == false)  // Google, never seen by stamp
        store.churnGoogleCardIDs()
        harness.vault.resetWrites()
        let (plan, _) = try harness.export()
        #expect(plan.creates.isEmpty && plan.updates.isEmpty)
        #expect(plan.reviews.isEmpty)
        #expect(plan.bindings[id]?.cardIDs == ["gail:google~google-sync"])
        #expect(harness.vault.writes.isEmpty)
        // Next run: the new (still untrusted) id binds, corroborated by the base.
        #expect(try harness.plan().isEmpty)
    }

    @Test("a Google card seen with its stamp becomes a trusted cached id")
    func stampTrust() throws {
        let store = Book.store([Book.person("gail", "Gail", "Green", accounts: [.google])])
        let harness = ExportHarness(store: store)
        let (first, _) = try harness.export()
        _ = try store.apply(
            AppleWriteBatch(operations: first.stamps.map { .stamp(cardID: $0.cardID, id: $0.recordID) }), author: "t")
        let (second, _) = try harness.export()
        #expect(second.bindings.values.first?.cards.first?.isTrusted == true)
    }

    @Test("two stamped contacts linked later: merge-records review, both notes left alone")
    func twoStamps() throws {
        let store = Book.store([
            Book.person("a1", "Ann", "One") { $0.emails = [Labeled(nil, "ann@home.example")] },
            Book.person("a2", "Ann", "One", accounts: [.google]) { $0.emails = [Labeled(nil, "ann@work.example")] },
        ])
        let harness = ExportHarness(store: store)
        // Equal names cluster; the user says they are different people.
        let cluster = try harness.export().plan
        #expect(cluster.creates.map(\.path) == ["Inbox/Ann One.md"])
        try harness.decide(try clusterID(cluster), "distinct")
        let (second, _) = try harness.export()
        #expect(second.creates.map(\.path) == ["Inbox/Ann One 2.md"])
        var stamps: [String: UUID] = [:]
        for stamp in cluster.stamps + second.stamps { stamps[stamp.cardID] = stamp.recordID }
        _ = try store.apply(
            AppleWriteBatch(operations: stamps.sorted { $0.key < $1.key }.map { .stamp(cardID: $0.key, id: $0.value) }),
            author: "t")
        store.link(["a1:icloud", "a2:google"])
        store.setSynthesizeLinkedIDs(true)
        harness.vault.resetWrites()
        let (plan, _) = try harness.export()
        guard case .mergeRecords(_, let ids, let paths)? = plan.reviews.first else {
            Issue.record("expected merge-records, got \(plan.reviews)")
            return
        }
        #expect(ids.count == 2)
        #expect(paths == ["Inbox/Ann One 2.md", "Inbox/Ann One.md"])
        #expect(plan.isEmpty && plan.needsReview)
        #expect(harness.vault.writes.isEmpty)
    }

    @Test("single-valued fields follow card precedence, not the unified view's last-saved blend")
    func cardPrecedence() throws {
        func linked(display: String) -> AppleContact {
            var icloud = CanonicalContact(kind: .person, title: "", name: PersonName(given: "Pat", family: "Lee"))
            icloud.jobTitle = "CEO"
            icloud.emails = [Labeled("home", "pat@example.com")]
            var google = icloud
            google.jobTitle = "Chief Executive"
            google.emails = [Labeled("home", "PAT@example.com"), Labeled("work", "pat@work.example")]
            var unified = google
            unified.jobTitle = display
            return AppleContact(
                unifiedID: "SYNTH-\(display)",
                cards: [
                    AppleCard(id: "g1", containerID: "google", accountKind: .google, values: google),
                    AppleCard(id: "i1", containerID: "icloud", accountKind: .iCloud, values: icloud),
                ],
                contact: unified)
        }
        let store = Book.store([linked(display: "Chief Executive")])
        let harness = ExportHarness(store: store)
        try harness.export()
        let note = try #require(try harness.contact(at: "Inbox/Pat Lee.md"))
        #expect(note.jobTitle == "CEO")
        #expect(note.emails == [Labeled("home", "pat@example.com"), Labeled("work", "pat@work.example")])
        // Google re-saves its card: the unified display flips; nothing changes.
        store.replaceContacts([linked(display: "CEO")])
        #expect(try harness.plan().isEmpty)
    }
}

@Suite("Moves, merge base, problems, iCloud placeholders")
struct VaultSafetyTests {
    @Test("a moved note: relative image path fixed up (not a content change), path recorded")
    func movedImageFixup() throws {
        let harness = ExportHarness()
        try harness.export()
        harness.vault.move("Inbox/Jane Doe.md", to: "People/Family/Jane Doe.md")
        let (plan, _) = try harness.export()
        #expect(plan.updates.map(\.kind) == [.pathFixup])
        #expect(plan.updates.first?.changedFields == ["image"])
        #expect(plan.moves.map(\.newPath) == ["People/Family/Jane Doe.md"])
        #expect(plan.notes.contains("moved Inbox/Jane Doe.md → People/Family/Jane Doe.md"))
        #expect(try harness.contact(at: "People/Family/Jane Doe.md")?.image?.path.hasPrefix("../../_images/") == true)
        let after = try harness.plan()
        #expect(after.isEmpty && after.moves.isEmpty)
    }

    @Test("markdown-only additions survive re-export; values Apple deleted are dropped")
    func mergeBase() throws {
        let store = Book.store([
            Book.person("ann", "Ann", "One") { contact in
                contact.emails = [Labeled("home", "ann@home.example"), Labeled("work", "ann@work.example")]
            }
        ])
        let harness = ExportHarness(store: store)
        try harness.export()
        let text = try #require(harness.vault.text("Inbox/Ann One.md"))
        harness.vault.seed(
            "Inbox/Ann One.md",
            Data(
                text.replacingOccurrences(of: "emails:\n", with: "emails:\n  - other: ann@mine.example\n")
                    .replacingOccurrences(of: "type: person\n", with: "type: person\nsuffix: PhD\n").utf8))
        try harness.editContact("ann:icloud") { $0.contact.emails.removeLast() }
        try harness.export()
        let ann = try #require(try harness.contact(at: "Inbox/Ann One.md"))
        #expect(ann.emails.map(\.value) == ["ann@home.example", "ann@mine.example"])
        #expect(ann.name.suffix == "PhD")  // markdown-only scalar kept
        #expect(try harness.plan().isEmpty)
    }

    @Test("invalid YAML in a non-contact note is reported once and never needs review")
    func nonContactProblem() throws {
        let vault = InMemoryVault(files: ["Journal/broken.md": "---\ntitle: [oops\n---\n"])
        let harness = ExportHarness(store: Book.store([Book.person("cy", "Cy", "Three")]), vault: vault)
        let first = try harness.export().plan
        #expect(first.newProblems.map(\.path) == ["Journal/broken.md"])
        #expect(!first.needsReview)
        let second = try harness.plan()
        #expect(second.newProblems.isEmpty && second.knownProblemCount == 1)
        // Edited (new content hash) → reported again.
        vault.seed("Journal/broken.md", Data("---\ntitle: [still broken\n---\n".utf8))
        #expect(try harness.plan().newProblems.count == 1)
    }

    @Test("invalid YAML in a contact-looking note is a review item")
    func contactProblem() throws {
        let vault = InMemoryVault(files: ["People/x.md": "---\ntype: person\ntitle: [oops\n---\n"])
        let plan = try ExportHarness(store: Book.store([]), vault: vault).plan()
        #expect(plan.reviews.map(\.id).first?.hasPrefix("invalid-") == true)
        #expect(plan.needsReview && plan.newProblems.isEmpty)
    }

    @Test("unknown iCloud placeholders hold back new notes; known ones are present, never deleted")
    func placeholders() throws {
        let vault = InMemoryVault(files: ["People/Who.md": "---\ntype: person\ntitle: Who\n---\n"])
        vault.setDataless("People/Who.md")
        let store = Book.store([Book.person("cy", "Cy", "Three")])
        let harness = ExportHarness(store: store, vault: vault)
        let held = try harness.plan()
        #expect(held.creates.isEmpty)
        #expect(held.reviews.map(\.id) == [ReviewItem.undownloaded(paths: []).id])
        #expect(held.skipped.map(\.title) == ["Cy Three"])
        let allowed = try harness.plan(ExportOptions(allowUndownloaded: true))
        #expect(allowed.creates.map(\.path) == ["Inbox/Cy Three.md"])

        // A bound note that is evicted later is present: skipped, not missing.
        vault.setDataless("People/Who.md", false)
        try harness.export()
        vault.setDataless("Inbox/Cy Three.md")
        try harness.editContact("cy:icloud") { $0.contact.jobTitle = "Now different" }
        let plan = try harness.plan()
        #expect(!plan.reviews.contains { if case .missingFile = $0 { true } else { false } })
        #expect(plan.skipped.map(\.reason) == ["Inbox/Cy Three.md is not downloaded from iCloud yet"])
        #expect(plan.isEmpty)
    }
}
