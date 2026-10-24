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
        /// List fields whose existing elements Contacts.app cannot find (`-1728`), by card.
        var unresolvable: [String: Set<AppleListField>] = [:]
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
    /// Contacts.app cannot find existing `field` elements of `cardID`
    /// (`-1728`, e.g. instant messages, spike S16): as `ScriptingCardWriter`
    /// does, that list edit is left out and reported skipped; the rest of the
    /// operation is applied.
    public func setUnresolvable(_ field: AppleListField, ofCard cardID: String, _ unresolvable: Bool = true) {
        state.withLock { state in
            if unresolvable {
                state.unresolvable[cardID, default: []].insert(field)
            } else {
                state.unresolvable[cardID]?.remove(field)
            }
        }
    }

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
        let (permission, failSession, failing, unresolvable) = state.withLock { state in
            state.calls.append(operations)
            return (state.permission, state.failSession, state.failing, state.unresolvable)
        }
        guard permission == .granted else {
            throw NotesUnavailableError("Automation permission for Contacts not granted", permissionDenied: true)
        }
        if failSession { throw NotesUnavailableError("Contacts.app is not answering") }
        let refused = operations.filter { $0.cardID.map(failing.contains) ?? false }
        var original: [AppleWriteOperation: AppleWriteOperation] = [:]
        var skipped: [AppleWriteSkip] = []
        let sent = operations.filter { !refused.contains($0) }.map { operation in
            let (effective, left) = Self.leavingOut(unresolvable, from: operation)
            original[effective] = operation
            skipped += left
            return effective
        }
        let written = store.scriptedApply(sent)
        let back = { (operation: AppleWriteOperation) in original[operation] ?? operation }
        var result = AppleWriteResult(
            applied: written.applied.map(back),
            failed: written.failed.map { AppleWriteFailure(operation: back($0.operation), message: $0.message) },
            skipped: written.skipped.map {
                AppleWriteSkip(operation: back($0.operation), edit: $0.edit, reason: $0.reason)
            },
            scripted: written.scripted.map(back))
        result.skipped += skipped.filter { result.applied.contains($0.operation) }
        result.failed += refused.map {
            AppleWriteFailure(
                operation: $0, message: "\($0.summary) via Contacts.app: Contacts.app scripting error -1728")
        }
        return result
    }

    /// `operation` without its list edits of unresolvable fields, and those edits as skips.
    private static func leavingOut(
        _ unresolvable: [String: Set<AppleListField>], from operation: AppleWriteOperation
    ) -> (AppleWriteOperation, [AppleWriteSkip]) {
        guard case .update(let cardID, let edits) = operation, let fields = unresolvable[cardID], !fields.isEmpty
        else { return (operation, []) }
        var kept: [CardEdit] = []
        var skipped: [AppleWriteSkip] = []
        for edit in edits {
            if case .list(let field, _) = edit, fields.contains(field) {
                skipped.append(
                    AppleWriteSkip(
                        operation: operation, edit: edit,
                        reason: "Contacts.app could not find the element to change (-1728) (\(field.rawValue))"))
            } else {
                kept.append(edit)
            }
        }
        return (.update(cardID: cardID, edits: kept), skipped)
    }

    public func finishSession() { state.withLock { $0.finishedSessions += 1 } }
}
