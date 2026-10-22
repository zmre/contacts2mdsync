import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// The app's review view models over a fake store and vault (no real Contacts or files).
@Suite("UI review adapters")
struct UIReviewTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reader(_ harness: CLIHarness) -> UIVaultReader {
        UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
    }

    func exported(_ vault: InMemoryVault = InMemoryVault()) -> (CLIHarness, UIVaultReader) {
        let harness = CLIHarness(vault: vault)
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        return (harness, reader(harness))
    }

    @Test("nothing is read or created before the first export")
    func unconfigured() throws {
        let harness = CLIHarness()
        #expect(try reader(harness).read() == nil)
        #expect(harness.vault.paths.isEmpty)
        #expect(throws: UIReviewError.notConfigured) { try reader(harness).record([.ignoreNote(path: "x.md")]) }
    }

    @Test("stored data after an export: records, notes, the duplicate cluster")
    func storedData() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        let data = try #require(try reader.read())
        #expect(data.status.records == 59)
        #expect(data.notes.count == 59)
        #expect(data.openItems.count == 1)
        #expect(data.device.name == "Test Mac")
        #expect(data.deviceCount == 1)
        let queues = UIReviewQueues(data: data)
        #expect(queues.counts == UIReviewCounts(duplicates: 1))
        let group = try #require(queues.duplicates.first)
        #expect(group.kind == .contacts)
        #expect(group.title == "Chris Martin")
        // Queued by the first export, before the primary's note existed.
        #expect(group.sources == "iCloud+Google")
        #expect(group.counts == "2 contacts")
        #expect(group.cards.map(\.heading) == ["iCloud", "Google"])
        #expect(group.cards.map(\.member) == [0, 1])
        #expect(group.cards.map(\.accounts) == [["iCloud"], ["Google"]])
        #expect(group.cards[0].why.first?.hasPrefix("With 2 · Google: same name \"Chris Martin\"") == true)
        #expect(group.priorPartition == nil)
        #expect(group.startingPartition.undecided == [0, 1])
        #expect(group.actions == [.notDuplicates, .ignoreForNow])
        #expect(group.allCardIDs == ["c26:icloud", "c27:google"])
    }

    @Test("a dry run enriches duplicate cards with contact details")
    func planDetails() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        let plan = try reader.plan()
        #expect(plan.contactsRead == 60)
        #expect(plan.pendingWrites == 0)
        #expect(plan.accounts.first?.account == .iCloud)
        let data = try #require(try reader.read())
        let group = try #require(UIReviewQueues(data: data, plan: plan).duplicates.first)
        #expect(group.cards[0].lines.contains("chris@example.com"))
        #expect(group.cards[1].lines.contains("(303) 555-0142"))
        // The member's note is on its card (no separate note card).
        #expect(group.cards[0].lines.last == "Note: Inbox/Chris Martin.md")
        #expect(group.cards[0].path == "Inbox/Chris Martin.md")
        #expect(group.cards[1].path == nil)
        #expect(group.sources == "iCloud+Google+md")
        #expect(group.counts == "2 contacts, 1 file")
        #expect(group.cards.map(\.heading) == ["iCloud", "Google"])
        // The dry run is recorded as a preview in Activity.
        let rows = UIActivityRow.rows(data.sessions, device: data.device)
        #expect(rows.first?.isPreview == true)
        #expect(rows.first?.contacts == nil)
        #expect(rows.last?.markdown == UIChangeCounts(created: 59))
        #expect(rows.last?.trigger == "CLI")
    }

    @Test("Not Duplicates is written to the decision log and clears the group")
    func notDuplicates() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        let before = try #require(try reader.read())
        let group = try #require(UIReviewQueues(data: before).duplicates.first)
        let answer = try #require(UIDuplicateAction.notDuplicates.decision(itemID: group.id))
        #expect(try reader.record([answer]) == 1)
        let log = try #require(
            harness.vault.text(".c2mdsync/devices/00000000-0000-4000-8000-00000000d001/decisions.jsonl"))
        #expect(log.contains("\"kind\":\"distinct-people\""))
        let data = try #require(try reader.read())
        #expect(UIReviewQueues(data: data).duplicates.isEmpty)
        // The next dry run honours it.
        #expect(try reader.plan().reviews.isEmpty)
    }

    @Test("Apply (a partition), Keep This One and Keep This File map to the CLI's choices")
    func actionChoices() {
        #expect(
            UIDuplicateAction.resolve(ClusterPartition(groups: [[0, 2], [1]], excluded: [3])).decision(itemID: "dup-1")
                == .choice(itemID: "dup-1", choice: "resolve:1,3/2;exclude:4"))
        #expect(
            UIDuplicateAction.keepSyncID(path: 0).decision(itemID: "copy-1")
                == .choice(itemID: "copy-1", choice: "keep:1"))
        #expect(UIDuplicateAction.ignoreForNow.decision(itemID: "dup-1") == nil)
        #expect(
            UIDuplicateAction.pickSurvivingFile(index: 1, path: "b.md").decision(itemID: "merge-1")
                == .choice(itemID: "merge-1", choice: "keep:2"))
    }

    @Test("Ignore for Now hides a group until the snooze is cleared")
    func snooze() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        let data = try #require(try reader.read())
        let id = try #require(UIReviewQueues(data: data).duplicates.first?.id)
        let snoozed = UIReviewQueues(data: data, snoozed: [id])
        #expect(snoozed.duplicates.isEmpty)
        #expect(snoozed.snoozedCount == 1)
        #expect(snoozed.counts.total == 0)
    }

    @Test("a stale item id is reported, not silently dropped")
    func staleItem() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        #expect(throws: UIReviewError.itemNotFound("dup-gone")) {
            try reader.record([.choice(itemID: "dup-gone", choice: "distinct")])
        }
    }

    @Test("copied notes become a same-sync-id group with Keep This One per file")
    func copiedNote() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        let original = try #require(harness.vault.data("Inbox/Jane Doe.md"))
        harness.vault.seed("Work/Jane Doe copy.md", original)
        _ = try reader.plan()
        let data = try #require(try reader.read())
        let group = try #require(UIReviewQueues(data: data).duplicates.first { $0.kind == .sameSyncID })
        #expect(group.cards.map(\.path) == ["Inbox/Jane Doe.md", "Work/Jane Doe copy.md"])
        #expect(group.cards.map(\.action) == [.keepSyncID(path: 0), .keepSyncID(path: 1)])
        #expect(group.title == "Jane Doe")
        let answer = try #require(UIDuplicateAction.keepSyncID(path: 0).decision(itemID: group.id))
        try reader.record([answer])
        #expect(try reader.plan().reviews.allSatisfy { if case .duplicateSyncID = $0 { false } else { true } })
    }

    @Test("Markdown Only: a hand-written note with a possible match; Link adopts it")
    func markdownOnlyLink() throws {
        let vault = InMemoryVault(files: ["People/Bob Smith.md": "---\ntype: person\ntitle: Bob Smith\n---\nmine\n"])
        let (harness, reader) = exported(vault)
        defer { withExtendedLifetime(harness) {} }
        var data = try #require(try reader.read())
        var row = try #require(UIReviewQueues(data: data).markdownOnly.first)
        #expect(row.path == "People/Bob Smith.md")
        #expect(row.folder == "People")
        #expect(row.kind == .person)
        #expect(!row.isOrphaned)
        let match = try #require(row.bestMatch)
        #expect(match.title == "Bob Smith")
        #expect(match.confidence < 0.5)
        #expect(row.defaultAction == .leave)  // name-only: never linked by default
        #expect(UIReviewQueues(data: data).counts.markdownOnly == 1)

        try reader.record(UIMarkdownOnlyAction.link(itemID: match.id).decisions(for: row))
        data = try #require(try reader.read())
        row = try #require(UIReviewQueues(data: data).markdownOnly.first)
        #expect(row.decidedNote == "Will be linked on the next sync")
        #expect(!row.needsReview)
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        data = try #require(try reader.read())
        #expect(UIReviewQueues(data: data).markdownOnly.isEmpty)
    }

    @Test("Markdown Only: Ignore without a match is remembered by path")
    func markdownOnlyIgnore() throws {
        let vault = InMemoryVault(files: ["Archive/Old Landlord.md": "---\ntype: person\ntitle: Old Landlord\n---\n"])
        let (_, reader) = exported(vault)
        var data = try #require(try reader.read())
        let row = try #require(UIReviewQueues(data: data).markdownOnly.first)
        #expect(row.matches.isEmpty)
        #expect(UIMarkdownOnlyAction.ignore.decisions(for: row) == [.ignoreNote(path: "Archive/Old Landlord.md")])
        #expect(row.defaultAction == .addToContacts)
        #expect(
            UIMarkdownOnlyAction.addToContacts.decisions(for: row) == [.addContact(path: "Archive/Old Landlord.md")])
        try reader.record(UIMarkdownOnlyAction.ignore.decisions(for: row))
        data = try #require(try reader.read())
        let queues = UIReviewQueues(data: data)
        #expect(queues.markdownOnly.first?.isIgnored == true)
        #expect(queues.counts.markdownOnly == 0)
    }

    @Test("default action is Link when a strong match exists")
    func defaultLink() {
        let match = UIMatchCandidate(
            id: "match-1", contact: ContactRef(cardIDs: ["a"], title: "Robert Smith"), title: "Robert Smith",
            confidence: 0.9, reasons: ["same email"], accounts: [.iCloud])
        let row = UIMarkdownOnlyRow(
            path: "Work/Bob Smith.md", title: "Bob Smith", kind: .person, note: nil, isOrphaned: false,
            isIgnored: false, decidedNote: nil, matches: [match], firstSeen: nil)
        #expect(row.defaultAction == .link(itemID: "match-1"))
        #expect(UIMarkdownOnlyAction.ignore.decisions(for: row) == [.choice(itemID: "match-1", choice: "ignore")])
        #expect(
            UIMarkdownOnlyAction.notThisPerson(itemID: "match-1").decisions(for: row)
                == [.choice(itemID: "match-1", choice: "distinct")])
    }

    @Test("Overview: needs review, this session vs last export, multi-device warning")
    func overview() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        let data = try #require(try reader.read())
        let counts = UIReviewQueues(data: data).counts
        let overview = UIOverview(data: data, plan: nil, counts: counts, sessionStart: .distantPast)
        #expect(overview.health == .needsReview(1))
        #expect(overview.needsReview.map(\.queue) == [.duplicates])
        #expect(overview.needsReview.first?.title == "Possible duplicates")
        #expect(overview.session?.heading == "This Session")
        #expect(overview.session?.markdown == UIChangeCounts(created: 59))
        #expect(overview.syncedContacts == 59)
        #expect(overview.changedInContacts == nil)
        #expect(!overview.multiDeviceWithoutStamps)

        let later = UIOverview(
            data: data, plan: try reader.plan(), counts: UIReviewCounts(), sessionStart: .distantFuture)
        #expect(later.health == .inSync)
        #expect(later.session?.heading == "Last Export")
        #expect(later.changedInContacts == 0)

        harness.vault.seed(".c2mdsync/devices/other-device/decisions.jsonl", Data())
        let shared = try #require(try reader.read())
        #expect(shared.deviceCount == 2)
        #expect(
            UIOverview(data: shared, plan: nil, counts: counts, sessionStart: .distantPast).multiDeviceWithoutStamps)
        try reader.setOptions(UIVaultOptions(appleWrites: false, stampContacts: true))
        let stamped = try #require(try reader.read())
        #expect(
            !UIOverview(data: stamped, plan: nil, counts: counts, sessionStart: .distantPast).multiDeviceWithoutStamps)
    }
}

/// Library, settings, deletions and formatting.
extension UIReviewTests {
    @Test("All Contacts: every record with its file, sorted and searchable")
    func library() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        let data = try #require(try reader.read())
        let rows = UILibraryRow.rows(data)
        #expect(rows.count == 59)
        #expect(rows.map(\.title) == rows.map(\.title).sorted { $0.localizedLowercase < $1.localizedLowercase })
        let sam = try #require(rows.first { $0.title == "Sam Lee" })
        #expect(sam.accountsText == "iCloud + Google")
        #expect(sam.folder == "Inbox")
        #expect(rows.filter { $0.matches("jane") }.map(\.title).contains("Jane Doe"))
        #expect(rows.filter { $0.matches("GOOGLE") }.contains { $0.title == "Sam Lee" })
        #expect(rows.filter { $0.matches("  ") }.count == 59)
    }

    @Test("Settings: the folder for new notes is changed in config.yaml")
    func defaultFolder() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        try reader.setDefaultFolder("People/New")
        #expect(harness.vault.text(".c2mdsync/config.yaml")?.contains("default_folder: People/New\n") == true)
        #expect(try reader.read()?.config.defaultFolder == "People/New")
        #expect(throws: (any Error).self) { try reader.setDefaultFolder("../outside") }
    }

    @Test("missing notes are listed for Deletions")
    func missingNote() throws {
        let (harness, reader) = exported()
        defer { withExtendedLifetime(harness) {} }
        harness.vault.remove("Inbox/Jane Doe.md")
        _ = try reader.plan()
        let afterRemoval = try #require(try reader.read())
        let queues = UIReviewQueues(data: afterRemoval)
        let missing = try #require(queues.deletions.first)
        #expect(missing.title == "Jane Doe")
        #expect(missing.path == "Inbox/Jane Doe.md")
        #expect(missing.side == .markdown)
        #expect(queues.counts.deletions == 1)
    }

    @Test("formatting: relative days, Contacts links, durations")
    func formatting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = Self.now
        #expect(UIFormat.relativeDay(now, now: now, calendar: calendar, locale: locale).hasPrefix("Today "))
        #expect(
            UIFormat.relativeDay(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale)
                .hasPrefix("Yesterday "))
        #expect(
            UIFormat.relativeDay(now.addingTimeInterval(-86_400 * 5), now: now, calendar: calendar, locale: locale)
                .hasPrefix("Jan 10"))
        let urls = UIFormat.contactsURLs(cardIDs: ["A1:ABPerson", "B2", "A1:ABPerson"])
        #expect(urls.map(\.absoluteString) == ["addressbook://A1:ABPerson", "addressbook://B2"])
        #expect(UIFormat.duration(0.42) == "0.4 s")
        #expect(UIFormat.duration(4.2) == "4 s")
        #expect(UIFormat.duration(600) == "10 min")
    }
}
