import Contacts2MdCLI
import Foundation
import SyncEngine
import Testing

/// The Conflicts screen's "which side changed what" wording.
@Suite("UI conflict summaries")
struct UIConflictSummaryTests {
    let locale = Locale(identifier: "en_US_POSIX")
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
    /// 2026-10-18 09:02 UTC.
    let seen = Date(timeIntervalSince1970: 1_792_314_120)

    func field(
        name: String = "Job", label: String? = nil, previous: String? = "Engineer", contacts: String = "Sr Engineer",
        markdown: String = "Staff Eng", since: Date? = nil
    ) -> UIConflictField {
        UIConflictField(
            id: "conflict-\(name)", name: name, label: label, previous: previous, contacts: contacts,
            markdown: markdown, options: [.keepContacts, .keepMarkdown], since: since)
    }

    @Test("each side's new value, named by side")
    func bothChanged() {
        #expect(field().changeSummary() == "Contacts → “Sr Engineer”, Markdown → “Staff Eng”")
    }

    @Test("removed, added and unchanged sides read as such")
    func sideKinds() {
        #expect(
            field(contacts: UIConflictField.removedText).changeSummary()
                == "Contacts removed it, Markdown → “Staff Eng”")
        #expect(
            field(previous: nil, contacts: "a@x.example", markdown: "b@x.example").changeSummary()
                == "Contacts added “a@x.example”, Markdown added “b@x.example”")
        #expect(field(markdown: "Engineer").changeSummary() == "Contacts → “Sr Engineer”, Markdown unchanged")
    }

    @Test("the line says since when, in the screen's relative-day format")
    func changeLine() throws {
        let now = try #require(calendar.date(byAdding: .day, value: 3, to: seen))
        let line = field(since: seen).changeLine(now: now, calendar: calendar, locale: locale)
        #expect(line.hasPrefix("Changed in both since Oct 18"))
        #expect(line.hasSuffix(": Contacts → “Sr Engineer”, Markdown → “Staff Eng”"))
        #expect(field().changeLine() == "Changed in both: Contacts → “Sr Engineer”, Markdown → “Staff Eng”")
    }

    @Test("long and multi-line values are clipped to their first line")
    func clipping() {
        #expect(UIConflictField.clip("short", limit: 10) == "short")
        #expect(UIConflictField.clip("abcdefghijkl", limit: 6) == "abcde…")
        #expect(UIConflictField.clip("\nfirst line\nsecond", limit: 40) == "first line …")
        let body = String(repeating: "word ", count: 40)
        let summary = field(name: "Notes", contacts: body, markdown: body).changeSummary(limit: 20)
        #expect(summary.count < 70)
        #expect(summary.contains("…"))
    }

    @Test("list rows: one field spelled out, several named")
    func listSummary() {
        let one = UIConflictRecord(
            recordID: UUID(), title: "Jane Doe", path: "Work/Jane Doe.md", since: seen, cardIDs: [],
            fields: [field(name: "Phone", label: "mobile", previous: "1", contacts: "2", markdown: "3")])
        #expect(one.listSummary == "Phone (mobile): Contacts → “2”, Markdown → “3”")
        let many = UIConflictRecord(
            recordID: UUID(), title: "Jane Doe", path: "Work/Jane Doe.md", since: seen, cardIDs: [],
            fields: [field(name: "Job"), field(name: "Email"), field(name: "Email"), field(name: "Notes")])
        #expect(many.listSummary == "Job, Email and Notes changed in both")
        #expect(many.changeLines(calendar: calendar, locale: locale).split(separator: "\n").count == 4)
        #expect(many.changeLines().hasPrefix("Job: Changed in both: Contacts → "))
    }

    @Test("fields built from engine conflicts carry when they were first seen")
    func fieldSince() {
        let conflict = SyncConflict(
            id: "conflict-0123456789", recordID: UUID(), title: "Ann", path: "Ann.md", field: "job_title", element: nil,
            base: ConflictSide(value: "Engineer"), apple: ConflictSide(value: nil),
            markdown: ConflictSide(value: "Chef"), options: [.keepApple, .keepMarkdown], appleHash: "a",
            markdownHash: "m")
        let field = UIConflictField(conflict, since: seen)
        #expect(field.since == seen)
        #expect(field.changeSummary() == "Contacts removed it, Markdown → “Chef”")
    }
}
