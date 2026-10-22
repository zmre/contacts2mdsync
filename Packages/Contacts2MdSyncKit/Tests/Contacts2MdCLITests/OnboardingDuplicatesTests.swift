import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Onboarding step 4 (docs/ui.md §2): the preview's duplicate clusters,
/// answered before the folder is configured, or skipped.
@Suite("Onboarding: review duplicates before the first sync")
struct OnboardingDuplicatesTests {
    static func preview(_ harness: CLIHarness) throws -> PreparedExport {
        try VaultSession(root: URL(filePath: "/vault"), environment: harness.environment())
            .prepare(ExportRequest(), forWriting: false)
    }

    static func chrisNotes(_ harness: CLIHarness) -> [String] {
        harness.vault.paths.filter { $0.contains("Chris Martin") && $0.hasSuffix(".md") }
    }

    @Test("the preview's clusters become partition groups with both cards and their accounts")
    func groups() throws {
        let harness = CLIHarness()
        let groups = UIOnboardingDuplicates.groups(try Self.preview(harness), now: harness.clock.now)
        let chris = try #require(groups.first { $0.title == "Chris Martin" })
        #expect(chris.kind == .contacts)
        #expect(chris.memberCards.count == 2)
        #expect(Set(chris.memberCards.flatMap(\.accounts)) == ["iCloud", "Google"])
        #expect(chris.memberCards.allSatisfy { !$0.lines.isEmpty })
        #expect(!harness.vault.exists(".c2mdsync/config.yaml"))  // a preview writes nothing
    }

    @Test("an answer is recorded before the folder is configured; the next preview and the first export apply it")
    func answered() throws {
        let harness = CLIHarness()
        let prepared = try Self.preview(harness)
        let chris = try #require(
            UIOnboardingDuplicates.groups(prepared, now: harness.clock.now).first {
                $0.title == "Chris Martin"
            })
        let reader = MaintenanceCommandTests.reader(harness)
        let written = try reader.recordPreview(
            [UIDuplicateAction.notDuplicates.decision(itemID: chris.id)].compactMap { $0 },
            items: prepared.plan.reviews)
        #expect(written == 1)
        #expect(!harness.vault.exists(".c2mdsync/config.yaml"))
        let again = UIOnboardingDuplicates.groups(try Self.preview(harness), now: harness.clock.now)
        #expect(!again.contains { $0.title == "Chris Martin" })

        let export = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(export.code == 0, "\(export.out)\(export.err)")
        #expect(Self.chrisNotes(harness).count == 2)
    }

    @Test("Skip for Now: the cluster yields one note and waits in Review")
    func skipped() throws {
        let harness = CLIHarness()
        let export = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(export.code == 1)  // the cluster needs review
        #expect(Self.chrisNotes(harness).count == 1)
    }

    @Test("an answer for an item the preview no longer has is refused")
    func staleItem() throws {
        let harness = CLIHarness()
        #expect(throws: UIReviewError.itemNotFound("dup-gone")) {
            try MaintenanceCommandTests.reader(harness).recordPreview(
                [.choice(itemID: "dup-gone", choice: "distinct")], items: [])
        }
    }
}
