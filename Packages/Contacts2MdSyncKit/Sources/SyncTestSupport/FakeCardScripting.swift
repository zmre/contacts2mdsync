public import ContactModel
internal import Foundation
internal import Synchronization

/// A `CardScripting` over a `FakeContactStore`: card writes as Contacts.app
/// scripting makes them (spike S15), with a switchable Automation
/// permission and failures. Never touches Apple Events.
public final class FakeCardScripting: CardScripting {
    struct State {
        var permission: NotesPermission = .granted
        var failSession = false
        /// Cards whose scripted writes fail (`-1728`-style, per card).
        var failing = Set<String>()
        var calls: [[AppleWriteOperation]] = []
        var availabilityChecks = 0
        var finishedSessions = 0
    }

    public let store: FakeContactStore
    private let state = Mutex(State())

    /// Creates scripting over `store`.
    public init(store: FakeContactStore, permission: NotesPermission = .granted) {
        self.store = store
        state.withLock { $0.permission = permission }
    }

    // MARK: - Switches

    /// The Automation permission macOS reports.
    public func setPermission(_ permission: NotesPermission) { state.withLock { $0.permission = permission } }
    /// Every call throws a session-level error (Contacts.app not answering).
    public func setFailSession(_ fail: Bool) { state.withLock { $0.failSession = fail } }
    /// Scripted writes to these cards fail.
    public func failCards(_ cardIDs: [String]) { state.withLock { $0.failing.formUnion(cardIDs) } }

    // MARK: - Counters

    /// The operations of each `apply` call.
    public var calls: [[AppleWriteOperation]] { state.withLock { $0.calls } }
    public var availabilityChecks: Int { state.withLock { $0.availabilityChecks } }
    public var finishedSessions: Int { state.withLock { $0.finishedSessions } }

    // MARK: - CardScripting

    public func availability() -> NotesAvailability {
        state.withLock { state in
            state.availabilityChecks += 1
            return .scripting(state.permission)
        }
    }

    public func apply(_ operations: [AppleWriteOperation]) throws -> AppleWriteResult {
        let (permission, failSession, failing) = state.withLock { state in
            state.calls.append(operations)
            return (state.permission, state.failSession, state.failing)
        }
        guard permission == .granted else {
            throw NotesUnavailableError("Automation permission for Contacts not granted", permissionDenied: true)
        }
        if failSession { throw NotesUnavailableError("Contacts.app is not answering") }
        let refused = operations.filter { $0.cardID.map(failing.contains) ?? false }
        var result = store.scriptedApply(operations.filter { !refused.contains($0) })
        result.failed += refused.map {
            AppleWriteFailure(
                operation: $0, message: "\($0.summary) via Contacts.app: Contacts.app scripting error -1728")
        }
        return result
    }

    public func finishSession() { state.withLock { $0.finishedSessions += 1 } }
}
