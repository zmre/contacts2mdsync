import ContactModel
import SyncEngine
import SyncTestSupport
import Testing

/// Cluster answers meeting later changes: cards linked or unlinked in
/// Contacts, legacy answers, notes detached by an earlier answer.
@Suite("Duplicates: cluster answers after the fact")
struct ClusterAnswerLifecycleTests {
    @Test("a kept card linked in Contacts with an excluded one keeps its person synced")
    func linkedAfterExclusion() throws {
        let harness = ExportHarness(store: Book.store(Array(ClusterResolveTests.fourChris().prefix(2))))
        try harness.decide(try clusterID(try harness.export().plan), "resolve:1;exclude:2")
        try harness.export()
        harness.store.link(["c1:icloud", "c2:google"])
        let plan = try harness.plan()
        #expect(plan.excludedByDecision == 0)
        #expect(!plan.skipped.contains { $0.reason.hasPrefix("excluded by") })
    }

    @Test("halves of a contact unlinked since the decision are asked about again, not silently joined")
    func unlinkedAfterDecision() throws {
        let store = Book.store([
            Book.person("a", "Pat", "Lee"), Book.person("b", "Pat", "Lee", accounts: [.google]),
            Book.person("c", "Pat", "Lee"),
        ])
        store.link(["a:icloud", "b:google"])
        let harness = ExportHarness(store: store)
        try harness.decide(try clusterID(try harness.export().plan), "distinct")
        try harness.export()
        // The user unlinks a and b: two contacts now answer to one reference.
        let linked = try #require(store.contacts.first { $0.cards.count > 1 })
        let halves = linked.cards.map { card in
            AppleContact(unifiedID: card.id, cards: [card], contact: card.values ?? linked.contact)
        }
        store.replaceContacts(store.contacts.filter { $0.cards.count == 1 } + halves)
        let plan = try harness.plan()
        #expect(!plan.skipped.contains { $0.reason.contains("(decision)") })
        // Both halves stay apart from c (the earlier answer), and are asked about as undecided.
        let members = try #require(Household.clusters(plan).first)
        #expect(members.map(\.unifiedID) == ["a:icloud", "b:google"])
        #expect(members.map(\.prior) == [nil, nil])
    }

    @Test("back-compat: a sync-only member that kept its note is shown as its own person, never as not synced")
    func legacySyncOnlyWithNote() throws {
        let harness = ExportHarness(store: Book.store(Array(ClusterResolveTests.fourChris().prefix(2))))
        // c1 (iCloud, the primary) already has a note when the user keeps only c2.
        try harness.decide(try clusterID(try harness.export().plan), "only:2")
        try harness.export()
        var contacts = harness.store.contacts
        contacts.append(Book.person("c5", "Chris", "Martin", accounts: [.local]))
        harness.store.replaceContacts(contacts)
        let members = try #require(Household.clusters(try harness.plan()).first)
        #expect(members.map(\.unifiedID) == ["c1:icloud", "c2:google", "c5:local"])
        #expect(members.map(\.prior) == [.person(0), .person(1), nil])
    }

    @Test("a cluster answered before its first export never stands in an excluded member for its note")
    func decidedBeforeExport() throws {
        let harness = ExportHarness(store: Book.store(Array(ClusterResolveTests.fourChris().prefix(2))))
        try harness.decide(try clusterID(try harness.plan()), "resolve:2;exclude:1")
        var contacts = harness.store.contacts
        contacts.append(Book.person("c5", "Chris", "Martin", accounts: [.local]))
        harness.store.replaceContacts(contacts)
        #expect(try harness.plan().creates.count == 1)
    }

    @Test("a decided pair that is also linked keeps its reasons, one link per pair")
    func decidedLinkReasons() throws {
        let harness = ExportHarness(store: Book.store(ClusterResolveTests.fourChris()))
        try harness.decide(try clusterID(try harness.export().plan), "resolve:1,2/3;exclude:4")
        try harness.export()
        var contacts = harness.store.contacts
        contacts.append(Book.person("c5", "Chris", "Martin", accounts: [.local]))
        harness.store.replaceContacts(contacts)
        let plan = try harness.plan()
        let members = try #require(Household.clusters(plan).first)
        let toSecond = (members[0].links ?? []).filter { $0.other == 1 }
        #expect(toSecond.count == 1)
        #expect(toSecond.first?.reasons.contains("same email chris@example.com") == true)
        #expect(toSecond.first?.reasons.last == "same person (your decision)")
        let reasons = plan.reviews.compactMap { review -> [String]? in
            if case .duplicateCluster(_, let reasons) = review { return reasons }
            return nil
        }
        #expect(reasons.first?.contains("same email") == true)
    }

    @Test("members are numbered in card order, whatever unified ids Contacts synthesizes")
    func memberOrder() throws {
        let store = Book.store([
            Book.person("m", "Pat", "Lee"), Book.person("n", "Pat", "Lee", accounts: [.google]),
            Book.person("d", "Pat", "Lee"),
        ])
        store.link(["m:icloud", "n:google"])
        store.setSynthesizeLinkedIDs(true)
        let members = try #require(Household.clusters(try ExportHarness(store: store).plan()).first)
        #expect(members.map(\.cardIDs) == [["d:icloud"], ["m:icloud", "n:google"]])
    }

    @Test("two-way: a member whose note was detached never keeps its person's note")
    func detachedKeeper() throws {
        let world = try World.exported(ClusterResolveTests.fourChris(), stamps: .always)
        try world.decide(try #require(try world.pending("dup").first).id, "resolve:2/3;exclude:1,4")
        try world.sync()
        var contacts = world.store.contacts
        contacts.append(Book.person("c5", "Chris", "Martin", accounts: [.local]))
        world.store.replaceContacts(contacts)
        try world.sync()
        let item = try #require(try world.pending("dup").first)
        try world.decide(item.id, "resolve:1,5/2/3;exclude:4")
        let run = try world.sync()
        #expect(!run.plan.markdown.skipped.contains { $0.reason.hasPrefix("same person as") })
        #expect(run.plan.markdown.creates.count == 1)
    }
}
