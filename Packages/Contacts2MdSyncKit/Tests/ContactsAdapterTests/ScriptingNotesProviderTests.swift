import ContactModel
import ContactsAdapter
import Foundation
import Synchronization
import Testing

/// Reads an object specifier back as text (`note of person id "x"`).
private func describe(_ descriptor: NSAppleEventDescriptor?) -> String {
    guard let descriptor else { return "nil" }
    if descriptor.descriptorType == ContactsScriptingEvents.fourCC("null") { return "app" }
    guard let record = descriptor.coerce(toDescriptorType: ContactsScriptingEvents.fourCC("reco")) else {
        return "?"
    }
    let code = { (key: String) in record.forKeyword(ContactsScriptingEvents.fourCC(key)) }
    let container = describe(code("from"))
    let suffix = container == "app" ? "" : " of \(container)"
    let want = code("want")?.typeCodeValue
    let form = code("form")?.enumCodeValue
    let data = code("seld")
    switch form {
    case ContactsScriptingEvents.fourCC("prop"):
        let property = data?.typeCodeValue == ContactsScriptingEvents.Code.note ? "note" : "id"
        return property + suffix
    case ContactsScriptingEvents.fourCC("indx"):
        return (want == ContactsScriptingEvents.Code.person ? "every person" : "every ?") + suffix
    case ContactsScriptingEvents.fourCC("ID  "):
        return "person id \"\(data?.stringValue ?? "")\"" + suffix
    default:
        return "?"
    }
}

private func code(_ event: NSAppleEventDescriptor) -> String {
    let text = { (value: FourCharCode) in
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }
    return text(event.eventClass) + "/" + text(event.eventID)
}

/// Contacts.app as Apple Events see it: people (card ids) with notes.
final class FakeContactsApp: AppleEventSending, ContactsAppControlling, @unchecked Sendable {
    struct State {
        var people: [(id: String, note: String?)] = []
        var running = false
        var hidden = true
        var active = false
        var launches = 0
        var quits = 0
        var permission: Int32 = 0
        var asked = 0
        var sent: [String] = []
        /// Errors to return for the next events (OSStatus), in order.
        var transportErrors: [Int] = []
        /// Ids changed between the bulk reads this many times.
        var shuffleReads = 0
        var refuse = Set<String>()
        var classic = false
        var permissionOnPrompt: Int32 = 0
        /// S14: a launch that comes up visible despite `hides`.
        var launchVisible = false
        /// `hide()` calls before Contacts.app reports hidden.
        var hidesNeeded = 1
        /// The first answered event shows the window again.
        var showOnFirstEvent = false
        var hides = 0
    }

    let state = Mutex(State())

    init(people: [(String, String?)], running: Bool = true) {
        state.withLock {
            $0.people = people.map { (id: $0.0, note: $0.1) }
            $0.running = running
        }
    }

    // MARK: AppleEventSending

    // swiftlint:disable:next cyclomatic_complexity
    func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        try state.withLock { state in
            let target = describe(event.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("----")))
            state.sent.append("\(code(event)) \(target)")
            if !state.transportErrors.isEmpty {
                let number = state.transportErrors.removeFirst()
                throw ContactsScriptingError(number: number, message: "transport \(number)")
            }
            guard state.running else { throw ContactsScriptingError(number: -600, message: "not running") }
            if state.showOnFirstEvent {
                state.showOnFirstEvent = false
                state.hidden = false
                state.hidesNeeded = 1
            }
            let reply = NSAppleEventDescriptor.appleEvent(
                withEventClass: ContactsScriptingEvents.fourCC("aevt"),
                eventID: ContactsScriptingEvents.fourCC("ansr"), targetDescriptor: nil, returnID: 0, transactionID: 0)
            switch (code(event), target) {
            case ("core/getd", "id of every person"):
                if state.shuffleReads > 0 {
                    state.shuffleReads -= 1
                    state.people.append((id: "NEW-\(state.shuffleReads):ABPerson", note: nil))
                }
                reply.setParam(Self.list(state.people.map(\.id)), forKeyword: ContactsScriptingEvents.fourCC("----"))
            case ("core/getd", "note of every person"):
                reply.setParam(Self.list(state.people.map(\.note)), forKeyword: ContactsScriptingEvents.fourCC("----"))
            case ("core/getd", let spec) where spec.hasPrefix("note of person id"):
                guard let person = state.people.first(where: { spec.contains("\"\($0.id)\"") }) else {
                    Self.fail(reply, -1728, "Can't get person id.")
                    return reply
                }
                reply.setParam(Self.value(person.note), forKeyword: ContactsScriptingEvents.fourCC("----"))
            case ("core/setd", let spec) where spec.hasPrefix("note of person id"):
                guard let index = state.people.firstIndex(where: { spec.contains("\"\($0.id)\"") }) else {
                    Self.fail(reply, -1728, "Can't get person id.")
                    return reply
                }
                let id = state.people[index].id
                guard !state.refuse.contains(id) else { return reply }
                var text = event.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("data"))?.stringValue
                if state.classic { text = text?.replacingOccurrences(of: "\n", with: "\r") }
                state.people[index].note = text?.isEmpty == true ? nil : text
            case ("core/save", _), ("core/cnte", _):
                reply.setParam(NSAppleEventDescriptor(int32: Int32(state.people.count)), forKeyword: 0x2D2D_2D2D)
            default:
                Self.fail(reply, -1708, "not handled")
            }
            return reply
        }
    }

    func permissionStatus(askUserIfNeeded: Bool) -> Int32 {
        state.withLock { state in
            guard state.running else { return -600 }
            if askUserIfNeeded {
                state.asked += 1
                if state.permission == -1744 { state.permission = state.permissionOnPrompt }
            }
            return state.permission
        }
    }

    // MARK: ContactsAppControlling

    var isRunning: Bool { state.withLock { $0.running } }
    var isInUse: Bool { state.withLock { !$0.hidden || $0.active } }

    var isHidden: Bool { state.withLock { $0.hidden } }

    func launchHidden(timeout: TimeInterval) throws {
        state.withLock {
            $0.running = true
            $0.hidden = !$0.launchVisible
            $0.launches += 1
        }
    }

    func hide() {
        state.withLock {
            $0.hides += 1
            $0.hidesNeeded -= 1
            if $0.hidesNeeded <= 0 { $0.hidden = true }
        }
    }

    func quit() {
        state.withLock {
            $0.running = false
            $0.quits += 1
        }
    }

    // MARK: Helpers

    static func value(_ text: String?) -> NSAppleEventDescriptor {
        text.map { NSAppleEventDescriptor(string: $0) }
            ?? NSAppleEventDescriptor(typeCode: ContactsScriptingEvents.fourCC("msng"))
    }

    static func list(_ values: [String?]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (offset, text) in values.enumerated() { list.insert(value(text), at: offset + 1) }
        return list
    }

    static func fail(_ reply: NSAppleEventDescriptor, _ number: Int32, _ message: String) {
        reply.setParam(NSAppleEventDescriptor(int32: number), forKeyword: ContactsScriptingEvents.fourCC("errn"))
        reply.setParam(NSAppleEventDescriptor(string: message), forKeyword: ContactsScriptingEvents.fourCC("errs"))
    }

    var sent: [String] { state.withLock { $0.sent } }
}

func provider(
    _ app: FakeContactsApp, quitWhenDone: Bool = true, bulkThreshold: Int = 2
)
    -> ScriptingNotesProvider
{
    ScriptingNotesProvider(
        sender: app, app: app, quitWhenDone: quitWhenDone, bulkThreshold: bulkThreshold, launchTimeout: 1,
        sleep: { _ in }, refusals: NotesRefusalMemo())
}

@Suite("Contacts.app scripting: Apple Events")
struct ContactsScriptingEventsTests {
    @Test("bulk reads ask for a property of every person")
    func bulkSpecifiers() {
        let ids = ContactsScriptingEvents.idsOfEveryPerson()
        #expect(code(ids) == "core/getd")
        #expect(
            describe(ids.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("----"))) == "id of every person")
        let notes = ContactsScriptingEvents.notesOfEveryPerson()
        #expect(
            describe(notes.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("----")))
                == "note of every person")
        #expect(notes.attributeDescriptor(forKeyword: ContactsScriptingEvents.fourCC("addr")) != nil)
    }

    @Test("a card id travels as a descriptor, never as script source")
    func personByID() {
        let id = "9DE3\" & do shell script \"x:ABPerson"
        let event = ContactsScriptingEvents.setNote(ofPerson: id, to: "line 1\nline \"2\"")
        #expect(code(event) == "core/setd")
        let target = event.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("----"))
        #expect(describe(target) == "note of person id \"\(id)\"")
        #expect(
            event.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("data"))?.stringValue
                == "line 1\nline \"2\"")
        #expect(code(ContactsScriptingEvents.save()) == "core/save")
        #expect(code(ContactsScriptingEvents.countPeople()) == "core/cnte")
    }

    @Test("codes match Contacts.sdef (person azf4, note az37, id 'ID  ')")
    func codes() {
        #expect(ContactsScriptingEvents.Code.person == 0x617A_6634)
        #expect(ContactsScriptingEvents.Code.note == 0x617A_3337)
        #expect(ContactsScriptingEvents.Code.id == 0x4944_2020)
    }

    @Test("replies: missing value is nil; errors carry their number")
    func replies() throws {
        let list = FakeContactsApp.list(["a", nil, "", "b\rc"])
        #expect(ContactsScriptingEvents.optionalStrings(list) == ["a", nil, "", "b\rc"])
        #expect(ContactsScriptingEvents.optionalStrings(FakeContactsApp.value("one")) == ["one"])
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: 0, eventID: 0, targetDescriptor: nil, returnID: 0, transactionID: 0)
        FakeContactsApp.fail(reply, -1743, "Not authorized")
        #expect(throws: ContactsScriptingError(number: -1743, message: "Not authorized")) {
            try ContactsScriptingEvents.result(of: reply)
        }
        #expect(ContactsScriptingError(number: -1743, message: "").isSessionLevel)
        #expect(!ContactsScriptingError(number: -1728, message: "").isSessionLevel)
    }
}

@Suite("Contacts.app scripting: ScriptingNotesProvider")
struct ScriptingNotesProviderTests {
    static let people: [(String, String?)] = [
        ("A:ABPerson", "Alpha\rsecond line"), ("B:ABPerson", nil), ("C:ABPerson", "Gamma"),
    ]

    @Test("bulk read: ids, notes, ids again; missing value → nil")
    func bulk() throws {
        let app = FakeContactsApp(people: Self.people)
        let notes = try provider(app).readAll(cardIDs: nil)
        #expect(notes.count == 3)
        #expect(notes["A:ABPerson"] == .some("Alpha\rsecond line"))
        #expect(notes["B:ABPerson"] == .some(nil))
        #expect(
            Array(app.sent.suffix(3)) == [
                "core/getd id of every person", "core/getd note of every person", "core/getd id of every person",
            ])
    }

    @Test("bulk read retries when a person appears between the reads, then gives up")
    func bulkRetry() throws {
        let app = FakeContactsApp(people: Self.people)
        app.state.withLock { $0.shuffleReads = 1 }
        #expect(try provider(app).readAll(cardIDs: nil).count == 4)
        let busy = FakeContactsApp(people: Self.people)
        busy.state.withLock { $0.shuffleReads = 10 }
        #expect(throws: NotesUnavailableError.self) { try provider(busy).readAll(cardIDs: nil) }
    }

    @Test("a few cards are read one by one; an unknown card is absent, not empty")
    func perCard() throws {
        let app = FakeContactsApp(people: Self.people)
        let notes = try provider(app).readAll(cardIDs: ["C:ABPerson", "GONE:ABPerson"])
        #expect(notes == ["C:ABPerson": "Gamma"])
        #expect(app.sent.contains("core/getd note of person id \"GONE:ABPerson\""))
        #expect(!app.sent.contains { $0.contains("every person") && $0.contains("note") })
    }

    @Test("more cards than the threshold: one bulk read, filtered")
    func bulkForMany() throws {
        let app = FakeContactsApp(people: Self.people)
        let notes = try provider(app, bulkThreshold: 1).readAll(cardIDs: ["A:ABPerson", "C:ABPerson"])
        #expect(Set(notes.keys) == ["A:ABPerson", "C:ABPerson"])
        #expect(app.sent.contains("core/getd note of every person"))
    }

    @Test("write: set + save per card, verified by reading back")
    func write() throws {
        let app = FakeContactsApp(people: Self.people)
        app.state.withLock { $0.refuse = ["C:ABPerson"] }
        let result = try provider(app).write([
            "A:ABPerson": "New\nnote", "B:ABPerson": nil, "C:ABPerson": "Refused", "X:ABPerson": "Unknown",
        ])
        #expect(Set(result.written) == ["A:ABPerson", "B:ABPerson"])
        #expect(result.failed["C:ABPerson"] == "Contacts kept a different note")
        #expect(result.failed["X:ABPerson"]?.contains("-1728") == true)
        #expect(app.state.withLock { $0.people.first?.note } == "New\nnote")
        #expect(app.sent.filter { $0.hasPrefix("core/save") }.count == 3)
    }

    @Test("Contacts converting line endings still verifies")
    func classicLineEndings() throws {
        let app = FakeContactsApp(people: Self.people)
        app.state.withLock { $0.classic = true }
        let result = try provider(app).write(["A:ABPerson": "one\ntwo"])
        #expect(result.written == ["A:ABPerson"])
    }

    @Test("permission: granted / denied / not determined; never prompts outside requestPermission")
    func permission() throws {
        let denied = FakeContactsApp(people: Self.people)
        denied.state.withLock { $0.permission = -1743 }
        #expect(provider(denied).availability() == .scripting(.denied))
        #expect(throws: NotesUnavailableError.self) { try provider(denied).readAll(cardIDs: nil) }
        #expect(!denied.sent.contains { $0.contains("note") })
        let undecided = FakeContactsApp(people: Self.people)
        undecided.state.withLock {
            $0.permission = -1744
            $0.permissionOnPrompt = 0
        }
        let scripting = provider(undecided)
        #expect(scripting.availability() == .scripting(.notDetermined))
        #expect(throws: NotesUnavailableError.self) { try scripting.write(["A:ABPerson": "x"]) }
        #expect(undecided.state.withLock { $0.asked } == 0)
        #expect(scripting.requestPermission() == .scripting(.granted))
        #expect(undecided.state.withLock { $0.asked } == 1)
        #expect(try scripting.readAll(cardIDs: ["A:ABPerson"]).count == 1)
    }

    @Test("a refusal is remembered: the next runs skip without launching Contacts.app; asking clears it")
    func refusalMemo() throws {
        let app = FakeContactsApp(people: Self.people, running: false)
        app.state.withLock { $0.permission = -1743 }
        let memo = NotesRefusalMemo()
        let make = {
            ScriptingNotesProvider(sender: app, app: app, launchTimeout: 1, sleep: { _ in }, refusals: memo)
        }
        let first = make()
        #expect(throws: NotesUnavailableError.self) { try first.readAll(cardIDs: nil) }
        first.finishSession()
        #expect(app.state.withLock { ($0.launches, $0.quits) } == (1, 1))
        #expect(throws: NotesUnavailableError.self) { try make().readAll(cardIDs: nil) }
        #expect(app.state.withLock { $0.launches } == 1)  // not launched again
        app.state.withLock { $0.permission = 0 }  // allowed in System Settings
        let asking = make()
        #expect(asking.requestPermission() == .scripting(.granted))
        asking.finishSession()
        #expect(try make().readAll(cardIDs: nil).count == 3)
    }

    @Test("permission without launching: unknown while Contacts.app is not running")
    func currentPermission() {
        let app = FakeContactsApp(people: Self.people, running: false)
        #expect(provider(app).currentPermission() == .unknown)
        #expect(app.state.withLock { $0.launches } == 0)
    }

    @Test("a freshly launched Contacts.app that does not answer yet is retried")
    func notReadyYet() throws {
        let app = FakeContactsApp(people: Self.people)
        app.state.withLock { $0.transportErrors = [-609, -600] }
        #expect(try provider(app).readAll(cardIDs: nil).count == 3)
    }

    @Test("session-level failures become NotesUnavailableError; per-card ones do not")
    func sessionFailures() throws {
        let app = FakeContactsApp(people: Self.people)
        let scripting = provider(app)
        _ = try scripting.readAll(cardIDs: nil)  // ready
        app.state.withLock { $0.transportErrors = [-1712] }
        #expect(throws: NotesUnavailableError.self) { try scripting.readAll(cardIDs: ["A:ABPerson"]) }
    }
}
