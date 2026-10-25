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
        /// Card ids whose person-level commands (person properties, group
        /// adds and removes) fail (`-10000`).
        var failing = Set<String>()
        /// Element classes whose every command (`set`, `make`, `delete`)
        /// fails with this error number, as instant messages do with `-1719`
        /// on macOS 27 (spike S16).
        var elementErrors: [FourCharCode: Int] = [:]
        /// `save` fails with this error number.
        var saveError: Int?
        /// The element class of every element command received, in order.
        var elementCommands: [FourCharCode] = []
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
    var elementCommands: [FourCharCode] { withState { $0.elementCommands } }
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
