import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// Households: spouses sharing a home phone (and their unlinked duplicates).
enum Household {
    static let home = Labeled<String>("home", "+1 303 555 0100")

    static func john(_ id: String = "john", accounts: [AccountKind] = [.iCloud]) -> AppleContact {
        Book.person(id, "John", "Doe", accounts: accounts) {
            $0.phones = [home, Labeled("mobile", "+1 303 555 0111")]
            $0.emails = [Labeled("home", "john@doe.example")]
        }
    }

    static func jane(_ id: String = "jane", accounts: [AccountKind] = [.iCloud]) -> AppleContact {
        Book.person(id, "Jane", "Doe", accounts: accounts) {
            $0.phones = [home]
            $0.emails = [Labeled("home", "jane@doe.example")]
        }
    }

    /// John and Jane, each with an unlinked Google duplicate: the user's
    /// "4 cards considered duplicate".
    static func fourCards() -> [AppleContact] {
        [john(), john("johng", accounts: [.google]), jane(), jane("janeg", accounts: [.google])]
    }

    static func clusters(_ plan: ExportPlan) -> [[ClusterMember]] {
        plan.reviews.compactMap { review in
            if case .duplicateCluster(let members, _) = review { return members }
            return nil
        }
    }
}

@Suite("Duplicates: household signals")
struct HouseholdDetectionTests {
    @Test("spouses sharing a home phone, each with a Google duplicate: two clusters, one per person")
    func spousesWithDuplicates() throws {
        let harness = ExportHarness(store: Book.store(Household.fourCards()))
        let plan = try harness.export().plan
        let clusters = Household.clusters(plan)
        #expect(
            clusters.map { $0.map(\.unifiedID) } == [
                ["jane:icloud", "janeg:google"], ["john:icloud", "johng:google"],
            ])
        #expect(plan.creates.map(\.path).sorted() == ["Inbox/Jane Doe.md", "Inbox/John Doe.md"])
        let why = try #require(clusters.first?.first?.links?.first)
        #expect(why.other == 1)
        #expect(why.reasons.first == "same name \"Jane Doe\"")
    }

    @Test("a husband's contact is not blocked by his wife's hand-written note sharing the home phone")
    func wifesNoteDoesNotBlockHusband() throws {
        let vault = InMemoryVault(files: [
            "People/Jane Doe.md": "---\ntype: person\ntitle: Jane Doe\nphones:\n  - home: +1 303 555 0100\n---\nmine\n"
        ])
        let harness = ExportHarness(store: Book.store([Household.john()]), vault: vault)
        let plan = try harness.export().plan
        #expect(plan.reviews.isEmpty)
        #expect(plan.creates.map(\.path) == ["Inbox/John Doe.md"])
        #expect(plan.markdownOnly == 1)
    }

    @Test("the wife's contact still adopts her note (same phone and name)")
    func wifeAdoptsHerNote() throws {
        let vault = InMemoryVault(files: [
            "People/Jane Doe.md": "---\ntype: person\ntitle: Jane Doe\nphones:\n  - home: +1 303 555 0100\n---\nmine\n"
        ])
        let harness = ExportHarness(store: Book.store([Household.john(), Household.jane()]), vault: vault)
        let plan = try harness.export().plan
        #expect(plan.adoptions.map(\.path) == ["People/Jane Doe.md"])
        #expect(plan.creates.map(\.path) == ["Inbox/John Doe.md"])
    }

    @Test("a shared email with different names is a warning only; a nickname with the same email is proposed")
    func sharedEmail() throws {
        let vault = InMemoryVault(files: [
            "People/Hana Seven.md": "---\ntype: person\ntitle: Hana Seven\nemails:\n  - sevens@example.com\n---\n",
            "People/Bob Smith.md": "---\ntype: person\ntitle: Bob Smith\nemails:\n  - rsmith@example.com\n---\n",
        ])
        let store = Book.store([
            Book.person("gus", "Gus", "Seven") { $0.emails = [Labeled("home", "sevens@example.com")] },
            Book.person("robert", "Robert", "Smith") { $0.emails = [Labeled("home", "rsmith@example.com")] },
        ])
        let harness = ExportHarness(store: store, vault: vault)
        let plan = try harness.plan()
        #expect(plan.creates.map(\.path) == ["Inbox/Gus Seven.md"])
        #expect(plan.warnings.contains { $0.contains("\"Gus Seven\" shares an email with People/Hana Seven.md") })
        let matches = Book.matches(plan)
        #expect(matches.map(\.path) == ["People/Bob Smith.md"])
        #expect(matches.first?.confidence == 0.7)
        #expect(
            plan.reviews.contains {
                if case .possibleMatch(_, _, _, let reasons) = $0 {
                    reasons == ["same email", "names match (Robert / Bob)"]
                } else {
                    false
                }
            })
    }

    @Test("a hand-written note whose title is not plainly a name still blocks a contact sharing its email")
    func decoratedTitle() throws {
        for title in ["Dr. Jane Doe", "Doe, Jane", "Jane Doe (Acme)"] {
            let vault = InMemoryVault(files: [
                "People/Note.md": "---\ntype: person\ntitle: \(title)\nemails:\n  - jane@doe.example\n---\n"
            ])
            let jane = Book.person("jane", "Jane", "Doe") { $0.emails = [Labeled("home", "jane@doe.example")] }
            let plan = try ExportHarness(store: Book.store([jane]), vault: vault).plan()
            #expect(plan.creates.isEmpty, "\(title)")
            #expect(Book.matches(plan).map(\.path) == ["People/Note.md"], "\(title)")
        }
    }

    @Test("a card that fits both spouses (no person name) joins only one of them")
    func noBridge() throws {
        let family = Labeled<String>("home", "family@doe.example")
        let store = Book.store([
            Book.person("john", "John", "Doe") { $0.emails = [family] },
            Book.person("jane", "Jane", "Doe") { $0.emails = [family] },
            Fixtures.contact("doefamily", kind: .organization) {
                $0.company = .plain("Doe Family")
                $0.emails = [family]
            },
        ])
        let clusters = Household.clusters(try ExportHarness(store: store).plan()).map { Set($0.map(\.unifiedID)) }
        #expect(clusters.count == 1)
        #expect(!clusters.contains { $0.isSuperset(of: ["john:icloud", "jane:icloud"]) })
    }

    @Test("two-way create gate: the wife's opted-in note is created despite the husband's shared home phone")
    func createGateHousehold() throws {
        let world = try World.exported([Household.john()])
        world.writeNote(
            "People/Jane Doe.md",
            "---\ntype: person\ntitle: Jane Doe\nfirst_name: Jane\nlast_name: Doe\n"
                + "phones:\n  - home: +1 303 555 0100\n---\n")
        try DecisionLog.append(
            [
                Decision(
                    kind: .createContact, createdAt: world.clock.now, device: world.device, path: "People/Jane Doe.md")
            ],
            deviceID: world.device.id, fs: world.vault)
        let run = try world.sync()
        #expect(run.result?.apple.map(\.kind) == [.create])
        #expect(!run.plan.markdown.reviews.contains { $0.id.hasPrefix("match-") })
    }
}

@Suite("Duplicates: cluster resolution")
struct ClusterResolveTests {
    /// Four cards in one cluster: Chris (iCloud) + Chris (Google) share an
    /// email; a second Chris Martin (iCloud) has the same name; a Google
    /// card shares that one's work email.
    static func fourChris() -> [AppleContact] {
        [
            Book.person("c1", "Chris", "Martin") { $0.emails = [Labeled("home", "chris@example.com")] },
            Book.person("c2", "Chris", "Martin", accounts: [.google]) {
                $0.emails = [Labeled("home", "chris@example.com")]
            },
            Book.person("c3", "Chris", "Martin") { $0.emails = [Labeled("work", "cmartin@globex.example")] },
            Book.person("c4", "Christopher", "Martin", accounts: [.google]) {
                $0.emails = [Labeled("work", "cmartin@globex.example")]
            },
        ]
    }

    @Test("a partition gives each group one note and leaves excluded members out, silently")
    func partition() throws {
        let harness = ExportHarness(store: Book.store(Self.fourChris()))
        let first = try harness.export().plan
        let cluster = try #require(Household.clusters(first).first)
        #expect(cluster.map(\.unifiedID) == ["c1:icloud", "c2:google", "c3:icloud", "c4:google"])
        #expect(first.creates.map(\.path) == ["Inbox/Chris Martin.md"])
        try harness.decide(try clusterID(first), "resolve:1,2/3;exclude:4")
        let (plan, _) = try harness.export()
        #expect(plan.reviews.isEmpty && !plan.needsReview)
        #expect(plan.creates.map(\.path) == ["Inbox/Chris Martin 2.md"])
        #expect(plan.excludedByDecision == 1)
        #expect(plan.skipped.allSatisfy { !$0.needsReview })
        #expect(plan.skipped.contains { $0.reason.hasPrefix("same person as Chris Martin (decision)") })
        let decision = try #require(try DecisionLog.readAll(harness.vault).decisions.last)
        #expect(decision.kind == .clusterResolve)
        #expect(decision.groups?.map { $0.map(\.cardIDs) } == [[["c1:icloud"], ["c2:google"]], [["c3:icloud"]]])
        #expect(decision.excluded?.map(\.cardIDs) == [["c4:google"]])
        #expect(try harness.plan().isEmpty)
    }

    @Test("a new member re-reports the cluster with the earlier answer prefilled and the newcomer undecided")
    func newMember() throws {
        let harness = ExportHarness(store: Book.store(Self.fourChris()))
        let first = try harness.export().plan
        try harness.decide(try clusterID(first), "resolve:1,2/3;exclude:4")
        try harness.export()
        var contacts = harness.store.contacts
        contacts.append(Book.person("c5", "Chris", "Martin", accounts: [.local]))
        harness.store.replaceContacts(contacts)
        let plan = try harness.plan()
        let members = try #require(Household.clusters(plan).first)
        #expect(members.map(\.unifiedID) == ["c1:icloud", "c2:google", "c3:icloud", "c4:google", "c5:local"])
        #expect(members.map(\.prior) == [.person(0), .person(0), .person(1), .excluded, nil])
        #expect(plan.creates.isEmpty)  // unresolved: no new note for the newcomer
        // Answering again settles it.
        try harness.decide(try clusterID(plan), "resolve:1,2,5/3;exclude:4")
        let settled = try harness.plan()
        #expect(settled.reviews.isEmpty && settled.creates.isEmpty)
    }

    @Test("a member that disappears is dropped; the rest stays settled")
    func removedMember() throws {
        let harness = ExportHarness(store: Book.store(Self.fourChris()))
        try harness.decide(try clusterID(try harness.export().plan), "resolve:1,2/3;exclude:4")
        try harness.export()
        harness.store.replaceContacts(harness.store.contacts.filter { $0.unifiedID != "c2:google" })
        let plan = try harness.plan()
        #expect(plan.reviews.isEmpty)
        #expect(plan.creates.isEmpty)
    }

    @Test("back-compat: a sync-only answer is shown as Person A + Not synced when a member is added")
    func legacySyncOnly() throws {
        let harness = ExportHarness(store: Book.store(Array(Self.fourChris().prefix(2))))
        try harness.decide(try clusterID(try harness.export().plan), "only:1")
        #expect(try harness.plan().reviews.isEmpty)
        var contacts = harness.store.contacts
        contacts.append(Book.person("c5", "Chris", "Martin", accounts: [.local]))
        harness.store.replaceContacts(contacts)
        let members = try #require(Household.clusters(try harness.plan()).first)
        #expect(members.map(\.prior) == [.person(0), .excluded, nil])
    }

    @Test("back-compat: distinct members stay apart; a newcomer linked to one is reported with that one")
    func legacyDistinct() throws {
        let harness = ExportHarness(store: Book.store(Array(Self.fourChris().prefix(2))))
        try harness.decide(try clusterID(try harness.export().plan), "distinct")
        try harness.export()
        var contacts = harness.store.contacts
        contacts.append(
            Book.person("c5", "Christopher", "Martin", accounts: [.local]) {
                $0.emails = [Labeled(nil, "chris@example.com")]
            })
        harness.store.replaceContacts(contacts)
        let members = try #require(Household.clusters(try harness.plan()).first)
        #expect(members.map(\.unifiedID) == ["c1:icloud", "c2:google", "c5:local"])
        #expect(members.map(\.prior) == [.person(0), .person(1), nil])
    }

    @Test("two-way sync honours a partition")
    func twoWay() throws {
        let world = try World.exported(Self.fourChris())
        let item = try #require(try world.pending("dup").first)
        try world.decide(item.id, "resolve:1,2/3;exclude:4")
        let run = try world.sync()
        #expect(run.plan.markdown.reviews.filter { $0.id.hasPrefix("dup-") }.isEmpty)
        #expect(
            world.notePaths.filter { $0.hasPrefix("Inbox/") }.sorted() == [
                "Inbox/Chris Martin 2.md", "Inbox/Chris Martin.md",
            ])
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("two-way: Don't Sync on a member that has a note stops syncing it without queuing a deletion")
    func excludeExported() throws {
        let world = try World.exported(Self.fourChris())
        #expect(world.notePaths.filter { $0.hasPrefix("Inbox/") } == ["Inbox/Chris Martin.md"])
        let item = try #require(try world.pending("dup").first)
        try world.decide(item.id, "resolve:2/3;exclude:1,4")
        let run = try world.sync()
        #expect(run.plan.markdown.reviews.isEmpty, "\(run.plan.markdown.reviews.map(\.summary))")
        #expect(run.plan.apple.isEmpty)
        #expect(
            world.notePaths.filter { $0.hasPrefix("Inbox/") }.sorted()
                == ["Inbox/Chris Martin 2.md", "Inbox/Chris Martin 3.md", "Inbox/Chris Martin.md"])
        try world.editNote("Inbox/Chris Martin.md") { $0.jobTitle = "Edited here" }
        world.advance(minutes: 20)
        let later = try world.sync()
        #expect(later.plan.apple.isEmpty)  // the excluded contact is not written
        #expect(later.plan.markdown.reviews.isEmpty)
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("partition choices: parse, round-trip, validation")
    func partitionChoices() throws {
        let partition = try #require(ClusterPartition(choice: "resolve:2,1/3;exclude:4"))
        #expect(partition.groups == [[0, 1], [2]])
        #expect(partition.excluded == [3])
        #expect(partition.choice == "resolve:1,2/3;exclude:4")
        #expect(ClusterPartition(choice: "resolve:;exclude:1,2")?.excluded == [0, 1])
        #expect(ClusterPartition(choice: "resolve:1,x") == nil)
        #expect(ClusterPartition(choice: "resolve:0") == nil)
        #expect(ClusterPartition(choice: "resolve:-9223372036854775808") == nil)
        #expect(ClusterPartition(choice: "resolve:1;exclude:-9223372036854775808") == nil)
        #expect(ClusterPartition(choice: "only:1") == nil)
        #expect(partition.problem(memberCount: 4) == nil)
        #expect(partition.problem(memberCount: 5)?.contains("missing: 5") == true)
        #expect(partition.problem(memberCount: 3)?.contains("no member 4") == true)
        #expect(ClusterPartition(groups: [[0], [0, 1]]).problem(memberCount: 2)?.contains("more than once") == true)

        let device = DeviceIdentity(id: "a", name: "A")
        let members = (1...3).map {
            ClusterMember(unifiedID: "u\($0)", title: "X", accounts: [.iCloud], path: nil, cardIDs: ["c\($0)"])
        }
        let cluster = ReviewItem.duplicateCluster(members: members, reasons: [])
        let decisions = try cluster.decisions(for: "resolve:1,3;exclude:2", device: device, at: Date())
        #expect(decisions.map(\.kind) == [.clusterResolve])
        #expect(decisions.first?.contacts.map(\.cardIDs) == [["c1"], ["c2"], ["c3"]])
        #expect(decisions.first?.groups?.map { $0.map(\.cardIDs) } == [[["c1"], ["c3"]]])
        #expect(throws: ReviewItem.ChoiceError.self) {
            try cluster.decisions(for: "resolve:1,2", device: device, at: Date())
        }
        // Round-trips through JSON; older kinds stay readable.
        let data = try JSONEncoder().encode(decisions[0])
        let decoded = try JSONDecoder().decode(Decision.self, from: data)
        #expect(decoded.groups == decisions[0].groups && decoded.excluded == decisions[0].excluded)
    }
}
