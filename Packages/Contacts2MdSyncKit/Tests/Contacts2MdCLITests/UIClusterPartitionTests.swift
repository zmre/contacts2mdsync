import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// The Duplicates card multi-select: the partition model and the cluster adapter.
@Suite("UI duplicates: cluster partition")
struct UIClusterPartitionTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func member(
        _ number: Int, _ title: String, _ account: AccountKind, path: String? = nil, links: [ClusterLink]? = nil,
        prior: ClusterPriorAnswer? = nil
    ) -> ClusterMember {
        ClusterMember(
            unifiedID: "u\(number)", title: title, accounts: [account], path: path, cardIDs: ["card\(number)"],
            links: links, prior: prior)
    }

    static func group(_ members: [ClusterMember]) throws -> UIDuplicateGroup {
        let entry = PendingReview(item: .duplicateCluster(members: members, reasons: ["same name"]), firstSeen: now)
        return try #require(UIDuplicateGroup(entry, plan: nil, notes: [:]))
    }

    @Test("Same Person, Different People and Don't Sync build a partition; chips summarize it")
    func editing() throws {
        var partition = UIClusterPartition(memberCount: 6)
        #expect(!partition.isComplete && partition.partition == nil)
        #expect(partition.summary == "Undecided: 6")
        partition.samePerson([0, 1, 2])
        partition.samePerson([3, 4])
        #expect(partition.summary == "Person A: 3 cards · Person B: 2 cards · Undecided: 1")
        #expect(partition.decision(itemID: "dup-1") == nil)
        partition.dontSync([5])
        #expect(partition.isComplete)
        #expect(partition.summary == "Person A: 3 cards · Person B: 2 cards · Not synced: 1")
        #expect(partition.badge(for: 4) == "Person B")
        #expect(partition.badge(for: 5) == "Not synced")
        #expect(partition.decision(itemID: "dup-1") == .choice(itemID: "dup-1", choice: "resolve:1,2,3/4,5;exclude:6"))
        // Different People splits the selection; people are renumbered by their first card.
        partition.differentPeople([0, 1])
        #expect(partition.people.map { partition.members(of: $0) } == [[0], [1], [2], [3, 4]])
        #expect(partition.partition == ClusterPartition(groups: [[0], [1], [2], [3, 4]], excluded: [5]))
        // Undo and Reset.
        partition.undo()
        #expect(partition.people.map { partition.members(of: $0) } == [[0, 1, 2], [3, 4]])
        #expect(partition.canUndo && partition.isEdited)
        partition.reset()
        #expect(partition.undecided == Array(0..<6) && !partition.isEdited)
        partition.undo()
        #expect(partition.isComplete)
        // Clearing sends cards back to undecided; out-of-range selections are ignored.
        partition.clear([5, 9])
        #expect(partition.undecided == [5])
    }

    @Test("the user's case: two of six cards' people synced, the rest left out")
    func twoOfSix() throws {
        var partition = UIClusterPartition(memberCount: 6)
        partition.samePerson([0, 1])
        partition.samePerson([2, 3])
        partition.dontSync([4, 5])
        #expect(partition.decision(itemID: "dup-x") == .choice(itemID: "dup-x", choice: "resolve:1,2/3,4;exclude:5,6"))
    }

    @Test("back-compat: an earlier answer (cluster-resolve, distinct, sync-only) prefills; newcomers are undecided")
    func prior() throws {
        let group = try Self.group([
            Self.member(1, "Chris Martin", .iCloud, prior: .person(0)),
            Self.member(2, "Chris Martin", .google, prior: .excluded),
            Self.member(3, "Chris Martin", .local),
        ])
        let partition = try #require(group.priorPartition)
        #expect(group.startingPartition == partition)
        #expect(partition.badge(for: 0) == "Person A")
        #expect(partition.badge(for: 1) == "Not synced")
        #expect(partition.undecided == [2])
        #expect(!partition.isEdited)
        // A distinct answer: one person per member, renumbered from Person A.
        let distinct = try Self.group([
            Self.member(1, "A", .iCloud, prior: .person(1)), Self.member(2, "A", .google, prior: .person(0)),
        ])
        #expect(distinct.priorPartition?.badge(for: 0) == "Person A")
        #expect(distinct.priorPartition?.badge(for: 1) == "Person B")
        #expect(try Self.group([Self.member(1, "A", .iCloud), Self.member(2, "A", .google)]).priorPartition == nil)
    }

    @Test("cards: one per member with accounts, its note, and why it is in the cluster")
    func cards() throws {
        let group = try Self.group([
            Self.member(
                1, "Jane Doe", .iCloud, path: "People/Jane Doe.md",
                links: [ClusterLink(other: 1, reasons: ["same email jane@doe.example", "names match (Jane / Jane)"])]),
            Self.member(
                2, "Jane Doe", .google,
                links: [ClusterLink(other: 0, reasons: ["same email jane@doe.example", "names match (Jane / Jane)"])]),
        ])
        #expect(group.cards.count == 2)
        #expect(group.memberCards.map(\.member) == [0, 1])
        #expect(group.cards[0].accounts == ["iCloud"])
        #expect(group.cards[0].path == "People/Jane Doe.md")
        #expect(group.cards[0].lines == ["Note: People/Jane Doe.md"])
        #expect(group.cards[0].why == ["With 2 · Google: same email jane@doe.example · names match (Jane / Jane)"])
        #expect(group.cards[1].why.first?.hasPrefix("With 1 · iCloud:") == true)
        var partition = group.startingPartition
        partition.samePerson([0, 1])
        #expect(group.cardIDs(of: 0, in: partition) == ["card1", "card2"])
        #expect(
            group.applyMessage(partition)
                == "Person A: Jane Doe (iCloud), Jane Doe (Google) are one person and sync to one note; "
                + "link them in Contacts.")
    }

    @Test("Apply says when one person already has several notes, and when an excluded note stops syncing")
    func applyMessageWithNotes() throws {
        let group = try Self.group([
            Self.member(1, "Ann One", .iCloud, path: "Inbox/Ann One.md"),
            Self.member(2, "Ann One", .google, path: "Inbox/Ann One 2.md"),
            Self.member(3, "Ann One", .local, path: "Inbox/Ann One 3.md"),
        ])
        var partition = group.startingPartition
        partition.samePerson([0, 1])
        partition.dontSync([2])
        let message = group.applyMessage(partition)
        #expect(message.contains("are one person, but 2 of them already have a note; each note keeps syncing"))
        #expect(message.hasSuffix("Nothing is deleted; a note they already have stops syncing."))
    }

    @Test("the detail is keyed by membership: linking cards keeps the item id but not the identity")
    func memberIdentity() throws {
        let separate = try Self.group([
            Self.member(1, "Pat Lee", .iCloud), Self.member(2, "Pat Lee", .google), Self.member(3, "Pat Lee", .local),
        ])
        let linked = try Self.group([
            ClusterMember(
                unifiedID: "u12", title: "Pat Lee", accounts: [.iCloud, .google], path: nil,
                cardIDs: ["card1", "card2"]),
            Self.member(3, "Pat Lee", .local),
        ])
        #expect(separate.id == linked.id)
        #expect(separate.memberIdentity != linked.memberIdentity)
        #expect(separate.memberIdentity == [separate.id, "card1", "card2", "card3"])
    }

    @Test("a dry run shows household numbers de-emphasized and personal numbers as details")
    func householdPhones() throws {
        let home = Labeled<String>("home", "+1 303 555 0100")
        let store = FakeContactStore(
            contacts: [
                Fixtures.contact("jane") {
                    $0.name = PersonName(given: "Jane", family: "Doe")
                    $0.phones = [home, Labeled("mobile", "+1 303 555 0122")]
                    $0.emails = [Labeled("home", "jane@doe.example")]
                },
                Fixtures.contact("janeg", accounts: [.google]) {
                    $0.name = PersonName(given: "Jane", family: "Doe")
                    $0.phones = [home]
                },
            ],
            containers: Fixtures.containers, groups: [], notesEntitled: false)
        let harness = CLIHarness(store: store)
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        let reader = UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
        let plan = try reader.plan()
        let data = try #require(try reader.read())
        let group = try #require(UIReviewQueues(data: data, plan: plan).duplicates.first)
        #expect(group.cards[0].lines == ["jane@doe.example", "+1 303 555 0122", "Note: Inbox/Jane Doe.md"])
        #expect(group.cards[0].quietLines == ["+1 303 555 0100 (home)"])
        #expect(group.cards[1].quietLines == ["+1 303 555 0100 (home)"])
        #expect(group.cards[0].why == ["With 2 · Google: same name \"Jane Doe\""])
        // Apply records one cluster-resolve decision; the group leaves the queue.
        var partition = group.startingPartition
        partition.samePerson([0, 1])
        let answer = try #require(partition.decision(itemID: group.id))
        #expect(try reader.record([answer]) == 1)
        #expect(try reader.plan().reviews.isEmpty)
    }
}
