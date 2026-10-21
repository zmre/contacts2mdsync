import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import SyncTriggers
import Testing
import VaultIndex

/// M5 engine data in the review screens: Activity from live runs and
/// `SessionRecord.sides`, merge records' Keep This File, dry-run details
/// from the plan's own snapshot.
extension UILiveSyncTests {
    // MARK: - Activity

    @Test("live runs show their trigger and the recorded Apple / markdown split")
    func liveActivity() throws {
        let harness = CLIHarness.exported()
        _ = harness.sync()
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        guard case .finished = harness.runner().runNow(SyncRunRequest(SyncTrigger(.live)), progress: { _ in }) else {
            Issue.record("live run did not finish")
            return
        }
        harness.clock.advance(60)
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        _ = harness.runner().runNow(SyncRunRequest(SyncTrigger(.rescanVault)), progress: { _ in })
        let reader = UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
        let data = try #require(try reader.read())
        let rows = UIActivityRow.rows(data.sessions, device: data.device, details: data.sessionDetails)
        let syncs = rows.filter { $0.command == "sync" }
        #expect(syncs.map(\.trigger) == ["Rescan", "Live", "CLI"])
        let rescan = try #require(syncs.first)
        // Apple writes are off: the note edit is held.
        #expect(rescan.contacts == UIChangeCounts())
        #expect(rescan.markdown == UIChangeCounts())
        #expect(rescan.held == 1)
        #expect(rescan.holdReason == "Apple writes off")
        #expect(rescan.appleRead == "incremental")
        let live = syncs[1]
        #expect(live.markdown == UIChangeCounts(updated: 1))
        #expect(live.contacts == UIChangeCounts())
        #expect(live.combined == nil)
        // CLI syncs carry the split too now.
        #expect(syncs[2].markdown != nil)
    }

    @Test("sessions from before M5: the app's stored split, else the combined total")
    func legacyActivity() {
        let device = DeviceIdentity(id: "mac-a", name: "Mac A")
        let app = SessionRecord(
            startedAt: Self.now, finishedAt: Self.now.addingTimeInterval(1), command: "sync", trigger: "GUI",
            deviceID: "mac-a", created: 1, updated: 2)
        let cli = SessionRecord(
            startedAt: Self.now.addingTimeInterval(-60), finishedAt: Self.now, command: "sync", trigger: "CLI",
            deviceID: "mac-a", created: 0, updated: 3, stamped: 1)
        let detail = UISessionDetail(
            startedAt: Self.now, trigger: "GUI", apple: UIChangeCounts(updated: 1),
            markdown: UIChangeCounts(created: 1, updated: 1), held: 2, holdReason: "Apple writes off")
        let rows = UIActivityRow.rows([app, cli], device: device, details: [detail])
        #expect(rows[0].trigger == "Manual")
        #expect(rows[0].contacts == UIChangeCounts(updated: 1))
        #expect(rows[0].markdown == UIChangeCounts(created: 1, updated: 1))
        #expect(rows[0].held == 2)
        #expect(rows[0].appleRead == nil)
        #expect(rows[1].contacts == nil && rows[1].markdown == nil)
        #expect(rows[1].combined == UIChangeCounts(updated: 4))
    }

    @Test("trigger labels: GUI is Manual; coordinator kinds and CLI as recorded")
    func triggerLabels() {
        let device = DeviceIdentity(id: "mac-a", name: "Mac A")
        let recorded = ["GUI", "Live", "Launch", "Wake", "Sweep", "Manual", "CLI", "Rescan", "rescan-vault"]
        let sessions = recorded.map {
            SessionRecord(
                startedAt: Self.now, finishedAt: Self.now, command: "sync", trigger: $0, deviceID: "mac-a")
        }
        #expect(
            UIActivityRow.rows(sessions, device: device).map(\.trigger)
                == ["Manual", "Live", "Launch", "Wake", "Sweep", "Manual", "CLI", "Rescan", "Rescan"])
    }

    // MARK: - Duplicates: merge records

    @Test("merge records: Keep This File records merge-keep for that note")
    func mergeKeep() throws {
        let contact = ContactRef(cardIDs: ["a:icloud", "b:google"], title: "Ann One")
        let ids = [UUID(), UUID()]
        let paths = ["Inbox/Ann One 2.md", "Inbox/Ann One.md"]
        let entry = PendingReview(item: .mergeRecords(contact: contact, ids: ids, paths: paths), firstSeen: Self.now)
        let group = try #require(UIDuplicateGroup(entry, plan: nil, notes: [:]))
        #expect(group.kind == .mergeRecords)
        let actions = group.cards.compactMap(\.action)
        #expect(
            actions == [.pickSurvivingFile(index: 0, path: paths[0]), .pickSurvivingFile(index: 1, path: paths[1])])
        let answer = try #require(actions[1].decision(itemID: group.id))
        #expect(answer == .choice(itemID: group.id, choice: "keep:2"))
        #expect(entry.item.choices.contains("keep:2"))
        let device = DeviceIdentity(id: "mac-a", name: "Mac A")
        let decisions = try entry.item.decisions(for: "keep:2", device: device, at: Self.now)
        #expect(decisions.map(\.kind) == [.mergeKeep])
        #expect(decisions.first?.path == "Inbox/Ann One.md")

        let writing = group.keepFileMessage(keeping: paths[1], appleWrites: true)
        #expect(writing.hasPrefix("Inbox/Ann One.md stays synced with Ann One. The other note (Inbox/Ann One 2.md)"))
        #expect(writing.contains("is detached on the next sync"))
        #expect(writing.contains("nothing is deleted"))
        #expect(writing.hasSuffix("The note's sync IDs are removed from Ann One's cards."))
        let off = group.keepFileMessage(keeping: paths[1], appleWrites: false)
        #expect(off.contains("is held until “Write changes back to Apple Contacts” is on"))
    }

    // MARK: - Dry run details

    @Test("a two-way dry run takes contact details and accounts from the plan's own snapshot")
    func planSnapshot() throws {
        // The 60-contact fixture book, with the Chris Martin duplicate cluster.
        let harness = CLIHarness(vault: InMemoryVault())
        _ = harness.run(["export", "--root", "/vault", "--yes"])
        _ = harness.sync()
        let reader = UIVaultReader(root: URL(filePath: "/vault"), environment: harness.environment())
        let reads = harness.store.snapshotCount
        let plan = try reader.plan()
        #expect(plan.sync != nil)
        #expect(!plan.accounts.isEmpty)
        // Incremental read, review details included: no snapshot at all
        // (before M5 the app took a second one for the duplicate cards).
        #expect(harness.store.snapshotCount == reads)
        let data = try #require(try reader.read())
        let group = try #require(UIReviewQueues(data: data, plan: plan).duplicates.first)
        #expect(group.cards[0].lines.contains("chris@example.com"))
    }
}
