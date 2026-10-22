import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

/// Activity's per-change list and File ▸ Export Log… (docs/ui.md §8).
@Suite("Activity: change log and Export Log")
struct ActivityLogTests {
    @Test("a sync records its changes; the inspector rows say what changed where")
    func changeLog() throws {
        let harness = CLIHarness.exported()
        #expect(harness.run(["config", "--root", "/vault", "--apple-writes", "enabled"]).code == 0)
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        #expect(harness.sync().code == 0)

        let reader = MaintenanceCommandTests.reader(harness)
        let data = try #require(try reader.read())
        let sync = try #require(data.sessions.first { $0.command == "sync" })
        #expect(sync.changeCount == 2)
        let changes = try reader.sessionChanges(of: sync)
        #expect(
            changes.map(\.line).sorted() == [
                "apple updated  Ann One  (job_title)",
                "markdown updated  Bob Two  Inbox/Bob Two.md  (job_title)",
            ])
        let rows = UIActivityChange.rows(changes, records: data.records)
        let markdown = try #require(rows.first { $0.side == "Markdown" })
        #expect(markdown.text == "Updated Bob Two.md — job_title")
        #expect(markdown.path == "Inbox/Bob Two.md" && !markdown.cardIDs.isEmpty)
        let apple = try #require(rows.first { $0.side == "Contacts" })
        #expect(apple.text == "Updated Ann One in Contacts — job_title")
        #expect(apple.path == nil && apple.cardIDs == ["ann:icloud"])

        let activity = UIActivityRow.rows(data.sessions, device: data.device)
        #expect(activity.first { $0.command == "sync" }?.changeCount == 2)

        // The first export recorded the notes it created.
        let export = try #require(data.sessions.first { $0.command == "export" })
        #expect(try reader.sessionChanges(of: export).count == 3)
        // Dry runs record nothing.
        #expect(harness.run(["plan", "--root", "/vault"]).code == 0)
        let plan = try #require(try reader.read()?.sessions.first { $0.command == "plan" })
        let planChanges = try reader.sessionChanges(of: plan)
        #expect(plan.changeCount == nil && planChanges.isEmpty && plan.changeLogID == nil)
    }

    @Test("Export Log: text lists runs newest first with their changes; JSON carries the same")
    func exportLog() throws {
        let harness = CLIHarness.exported()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        #expect(harness.sync().code == 0)
        let reader = MaintenanceCommandTests.reader(harness)

        let text = try reader.activityLog(format: .text)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(
            lines.first?.hasPrefix("Contacts2MdSync activity log  exported 2027-01-15T08:00:00Z  device=Test Mac")
                == true)
        let sync = try #require(
            lines.firstIndex { $0.contains("  sync  CLI  apple c/u/d 0/0/0  md c/u/d 0/1/0  held 1") })
        #expect(lines[sync + 1] == "    markdown updated  Bob Two  Inbox/Bob Two.md  (job_title)")
        let export = try #require(lines.firstIndex { $0.contains("  export  CLI") })
        #expect(export > sync)  // newest first
        #expect(lines.contains("    markdown created  Ann One  Inbox/Ann One.md"))

        let json = try reader.activityLog(format: .json)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["device"] as? String == "Test Mac")
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.count == 2)
        let first = try #require(sessions.first)
        #expect((first["changes"] as? [[String: Any]])?.first?["verb"] as? String == "updated")
        #expect((first["session"] as? [String: Any])?["command"] as? String == "sync")
    }

    @Test("Export Log before this Mac synced: just the header")
    func emptyLog() throws {
        let harness = CLIHarness(store: smallStore())
        let text = try MaintenanceCommandTests.reader(harness).activityLog(format: .text)
        #expect(text.split(separator: "\n").count == 1)
    }
}
