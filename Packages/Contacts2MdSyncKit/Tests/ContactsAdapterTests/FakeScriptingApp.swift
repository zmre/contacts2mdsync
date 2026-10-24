import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

// MARK: - A fake Contacts.app that interprets the card-write Apple Events

/// An object specifier read back from an Apple Event.
indirect enum Spec: Equatable {
    case person(String)
    case element(FourCharCode, id: String, parent: Spec)
    case every(FourCharCode, parent: Spec)
    case property(FourCharCode, parent: Spec)
    case group(String)
    /// `first <element> of <parent> whose <terms all equal>`.
    case firstWhose(FourCharCode, terms: [ScriptProperty], parent: Spec)
    case app

    static func decode(_ descriptor: NSAppleEventDescriptor?) -> Spec? {
        guard let descriptor else { return nil }
        if descriptor.descriptorType == ContactsScriptingEvents.fourCC("null") { return .app }
        guard let record = descriptor.coerce(toDescriptorType: ContactsScriptingEvents.fourCC("reco")) else {
            return nil
        }
        let key = { (code: String) in record.forKeyword(ContactsScriptingEvents.fourCC(code)) }
        let want = key("want")?.typeCodeValue ?? 0
        let form = key("form")?.enumCodeValue ?? 0
        let data = key("seld")
        let container = decode(key("from")) ?? .app
        switch form {
        case ContactsScriptingEvents.fourCC("prop"):
            return .property(data?.typeCodeValue ?? 0, parent: container)
        case ContactsScriptingEvents.fourCC("indx"):
            if data?.enumCodeValue == ContactsScriptingEvents.fourCC("firs") || data.map(isFirst) == true,
                case .whose(let terms, let parent) = decodeTest(key("from"))
            {
                return .firstWhose(want, terms: terms, parent: parent)
            }
            return .every(want, parent: container)
        case ContactsScriptingEvents.fourCC("ID  "):
            let id = data?.stringValue ?? ""
            if want == ContactsScriptingEvents.Code.person { return .person(id) }
            if want == ContactsScriptingEvents.CardCode.group { return .group(id) }
            return .element(want, id: id, parent: container)
        default:
            return nil
        }
    }

    private static func isFirst(_ ordinal: NSAppleEventDescriptor) -> Bool {
        ordinal.data.count == 4
            && ordinal.data.withUnsafeBytes { $0.load(as: FourCharCode.self) }
                == ContactsScriptingEvents.fourCC("firs")
    }

    /// A `whose` test specifier: the equal-to terms and the container.
    enum Test { case whose([ScriptProperty], Spec), none }

    static func decodeTest(_ descriptor: NSAppleEventDescriptor?) -> Test {
        let reco = ContactsScriptingEvents.fourCC("reco")
        guard let record = descriptor?.coerce(toDescriptorType: reco),
            record.forKeyword(ContactsScriptingEvents.fourCC("form"))?.enumCodeValue
                == ContactsScriptingEvents.fourCC("test"),
            let test = record.forKeyword(ContactsScriptingEvents.fourCC("seld"))
        else { return .none }
        let parent = decode(record.forKeyword(ContactsScriptingEvents.fourCC("from"))) ?? .app
        var comparisons: [NSAppleEventDescriptor] = [test]
        if test.descriptorType == ContactsScriptingEvents.fourCC("logi"),
            let logical = test.coerce(toDescriptorType: reco),
            logical.forKeyword(ContactsScriptingEvents.fourCC("logc"))?.enumCodeValue
                == ContactsScriptingEvents.fourCC("AND "),
            let list = logical.forKeyword(ContactsScriptingEvents.fourCC("term")), list.numberOfItems > 0
        {
            comparisons = (1...list.numberOfItems).compactMap { list.atIndex($0) }
        }
        var terms: [ScriptProperty] = []
        for comparison in comparisons {
            guard comparison.descriptorType == ContactsScriptingEvents.fourCC("cmpd"),
                let fields = comparison.coerce(toDescriptorType: reco),
                fields.forKeyword(ContactsScriptingEvents.fourCC("relo"))?.enumCodeValue
                    == ContactsScriptingEvents.fourCC("=   "),
                let lhs = fields.forKeyword(ContactsScriptingEvents.fourCC("obj1"))?.coerce(toDescriptorType: reco),
                lhs.forKeyword(ContactsScriptingEvents.fourCC("from"))?.descriptorType
                    == ContactsScriptingEvents.fourCC("exmn"),
                let property = lhs.forKeyword(ContactsScriptingEvents.fourCC("seld"))?.typeCodeValue,
                let rhs = fields.forKeyword(ContactsScriptingEvents.fourCC("obj2"))
            else { return .none }
            let value: ScriptValue =
                rhs.descriptorType == ContactsScriptingEvents.fourCC("enum")
                ? .enumerated(rhs.enumCodeValue) : .text(rhs.stringValue ?? "")
            terms.append(ScriptProperty(property, value))
        }
        return .whose(terms, parent)
    }
}

/// Contacts.app as the card-write events see it: people are in-memory
/// `CNMutableContact`s keyed by card id (the S15 facts: `person id` = card
/// id, element `id` = `CNLabeledValue.identifier`). Edits are pending until
/// `save`, as in Contacts.app; the reader sees saved state only.
final class FakeScriptingApp: AppleEventSending, ContactsAppControlling, ScriptingCardReading, @unchecked Sendable {
    struct State {
        var pending: [String: CNMutableContact] = [:]
        var saved: [String: CNContact] = [:]
        var pendingGroups: [String: Set<String>] = [:]
        var savedGroups: [String: Set<String>] = [:]
        var running = true
        var launches = 0
        var quits = 0
        var permission: Int32 = 0
        var events: [String] = []
        var saves = 0
        /// Card ids whose element edits fail (`-10000`, per card).
        var failing = Set<String>()
        /// `instant message id E` does not resolve (`-1728`), as on macOS 27 (spike S16).
        var imByIDUnresolvable = false
        /// `first instant message whose …` does not resolve either (`-1728`).
        var imWhoseUnresolvable = false
        /// `person id P` does not resolve in Contacts.app (`-1728`) for these cards.
        var missingPeople = Set<String>()
    }

    private let lock = NSLock()
    private var storage = State()

    /// Runs `body` on the state under the lock (`CNMutableContact` is not `Sendable`).
    func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }

    init(cards: [String: CNContact], groups: [String: Set<String>] = [:], running: Bool = true) {
        withState { state in
            for (id, card) in cards {
                state.saved[id] = card.copy() as? CNContact
                state.pending[id] = card.mutableCopy() as? CNMutableContact
            }
            state.savedGroups = groups
            state.pendingGroups = groups
            state.running = running
        }
    }

    var events: [String] { withState { $0.events } }
    var saves: Int { withState { $0.saves } }
    func saved(_ id: String) -> CNContact? { withState { $0.saved[id] } }
    func members(_ group: String) -> Set<String> { withState { $0.savedGroups[group] ?? [] } }

    // MARK: ScriptingCardReading (the Contacts framework view: saved state)

    func cards(_ ids: [String]) throws -> [String: CNContact] {
        withState { state in state.saved.filter { ids.contains($0.key) } }
    }

    func memberIDs(ofGroup id: String) throws -> Set<String> { withState { $0.savedGroups[id] ?? [] } }

    // MARK: ContactsAppControlling

    var isRunning: Bool { withState { $0.running } }
    var isInUse: Bool { false }
    var isHidden: Bool { true }
    func launchHidden(timeout: TimeInterval) throws {
        withState {
            $0.running = true
            $0.launches += 1
        }
    }
    func hide() {}
    func quit() {
        withState {
            $0.running = false
            $0.quits += 1
        }
    }

    // MARK: AppleEventSending

    func permissionStatus(askUserIfNeeded: Bool) -> Int32 {
        withState { $0.running ? $0.permission : -600 }
    }

    func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        try withState { state in
            guard state.running else { throw ContactsScriptingError(number: -600, message: "not running") }
            let reply = NSAppleEventDescriptor.appleEvent(
                withEventClass: ContactsScriptingEvents.fourCC("aevt"),
                eventID: ContactsScriptingEvents.fourCC("ansr"), targetDescriptor: nil, returnID: 0, transactionID: 0)
            let code = Self.text(event.eventClass) + "/" + Self.text(event.eventID)
            state.events.append(code)
            do {
                try Self.handle(code, event, &state)
            } catch let error as ContactsScriptingError {
                reply.setParam(NSAppleEventDescriptor(int32: Int32(error.number)), forKeyword: Self.code("errn"))
                reply.setParam(NSAppleEventDescriptor(string: error.message), forKeyword: Self.code("errs"))
            }
            return reply
        }
    }
}
