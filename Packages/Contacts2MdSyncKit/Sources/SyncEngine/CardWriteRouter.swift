public import ContactModel
public import Foundation
internal import Synchronization

/// What the write routing did during one run of a `CardWriteRouter`.
public struct CardWriteRouteLog: Hashable, Sendable {
    /// Operations sent to Contacts.app scripting, and how many of them were applied.
    public var scriptedAttempted = 0
    public var scriptedApplied = 0
    /// Operations the Contacts framework refused with 134092 and that were
    /// sent again through Contacts.app scripting.
    public var retriedAfterRejection = 0
    /// Operations held for the Automation permission.
    public var held = 0

    /// Creates an empty log.
    public init() {}
}

/// A `ContactStore` that sends each card write the way it can succeed
/// (architecture §6 "Write routing", spike S15):
///
/// | Operation                                        | Route                    |
/// |--------------------------------------------------|--------------------------|
/// | create, delete (and every operation of a card being deleted) | Contacts framework |
/// | `removeMember` (a CN no-op on iCloud)            | Contacts.app scripting   |
/// | update, stamp, unstamp, `addMember` with the notes entitlement | Contacts framework |
/// | … of a card known to have a note                 | Contacts.app scripting   |
/// | … of a card known to have none                   | Contacts framework; on 134092 → scripting |
/// | … note unknown                                   | scripting when permitted, else framework; on 134092 → scripting |
///
/// Writes that need scripting while it is not permitted (no Automation
/// permission; a headless run never prompts) are **held**, not failed:
/// `AppleWriteResult.held` with `permissionReason`. Contacts.app scripting
/// saves carry no `transactionAuthor`; the executor reads the history token
/// after the batch, so their events are older than the next run's token
/// (the same rule as scripted notes, §8).
///
/// Everything else (reads, history, backups) goes to `inner` unchanged.
public final class CardWriteRouter: ContactStore {
    public let inner: any ContactStore
    /// `nil`: scripting is not available in this build or environment
    /// (writes that need it are held).
    public let scripting: (any CardScripting)?
    private let state = Mutex(CardWriteRouteLog())

    /// The `held` reason of writes that need Contacts.app scripting without permission.
    public static let permissionReason = "needs permission for Contacts2MdSync to control Contacts"

    /// Creates a router over `inner`.
    public init(inner: any ContactStore, scripting: (any CardScripting)?) {
        self.inner = inner
        self.scripting = scripting
    }

    /// What the routing did so far.
    public var log: CardWriteRouteLog { state.withLock { $0 } }

    // MARK: - ContactStore (reads go to `inner`)

    public var capabilities: StoreCapabilities { get throws { try inner.capabilities } }
    public func snapshot() throws -> AppleSnapshot { try inner.snapshot() }
    public func fetch(unifiedIDs: [String]) throws -> [AppleContact] { try inner.fetch(unifiedIDs: unifiedIDs) }
    public func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult {
        try inner.changes(since: token, excluding: authors)
    }
    public func currentHistoryToken() throws -> Data? { try inner.currentHistoryToken() }
    public func refetch(cardIDs: [String], siblingHints: [String]) throws -> AppleRefetch {
        try inner.refetch(cardIDs: cardIDs, siblingHints: siblingHints)
    }
    public func exportVCards() throws -> Data { try inner.exportVCards() }

    // MARK: - Writes

    /// Where one operation goes.
    enum Route: Equatable {
        case framework
        case scripting
    }

    public func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        guard !batch.operations.isEmpty else { return AppleWriteResult(applied: []) }
        let entitled = (try? inner.capabilities.notesAvailable) == true
        // Asked at most once per batch, and only for a card whose note is unknown.
        var permitted: NotesAvailability?
        let scriptingPermitted = { [scripting] () -> Bool in
            let answer = permitted ?? scripting?.availability() ?? .unavailable("no scripting")
            permitted = answer
            return answer == .scripting(.granted)
        }
        let routes = Self.routes(batch, entitled: entitled, scriptingPermitted: scriptingPermitted)

        var result = AppleWriteResult(applied: [])
        var scripted = batch.operations.filter { routes[$0] == .scripting }
        let framework = batch.operations.filter { routes[$0] != .scripting }
        if !framework.isEmpty {
            let saved = try inner.apply(
                AppleWriteBatch(operations: framework, cardNotes: batch.cardNotes), author: author)
            result.applied += saved.applied
            result.createdCardIDs = saved.createdCardIDs
            result.skipped += saved.skipped
            result.held += saved.held
            let rejected = saved.failed.filter { $0.rejectedForNote && $0.operation.cardID != nil }
            result.failed += saved.failed.filter { !rejected.contains($0) }
            let retry = Set(rejected.map(\.operation))
            scripted += framework.filter(retry.contains)
            state.withLock { $0.retriedAfterRejection += retry.count }
        }
        guard !scripted.isEmpty else { return result }
        state.withLock { $0.scriptedAttempted += scripted.count }
        guard let scripting else {
            hold(scripted, in: &result)
            return result
        }
        do {
            let written = try scripting.apply(scripted)
            result.applied += written.applied
            result.scripted += written.applied
            result.failed += written.failed
            result.skipped += written.skipped
            result.held += written.held
            state.withLock { $0.scriptedApplied += written.applied.count }
        } catch let error as NotesUnavailableError where error.permissionDenied {
            hold(scripted, in: &result)
        } catch {
            result.failed += scripted.map {
                AppleWriteFailure(operation: $0, message: "\($0.summary) via Contacts.app: \(error)")
            }
        }
        return result
    }

    private func hold(_ operations: [AppleWriteOperation], in result: inout AppleWriteResult) {
        result.held += operations.map { AppleWriteHold(operation: $0, reason: Self.permissionReason) }
        state.withLock { $0.held += operations.count }
    }

    /// The route of every operation in `batch`. A card with a delete goes
    /// to the framework whole (its other edits are moot).
    static func routes(
        _ batch: AppleWriteBatch, entitled: Bool, scriptingPermitted: () -> Bool
    ) -> [AppleWriteOperation: Route] {
        let deleted = Set(
            batch.operations.compactMap { operation -> String? in
                if case .delete(let id) = operation { id } else { nil }
            })
        var routes: [AppleWriteOperation: Route] = [:]
        for operation in batch.operations {
            guard let cardID = operation.cardID, !deleted.contains(cardID) else {
                routes[operation] = .framework  // creates, deletes
                continue
            }
            if case .removeMember = operation {
                routes[operation] = .scripting
                continue
            }
            if entitled {
                routes[operation] = .framework
                continue
            }
            switch batch.cardNotes[cardID] {
            case true?: routes[operation] = .scripting
            case false?: routes[operation] = .framework
            case nil: routes[operation] = scriptingPermitted() ? .scripting : .framework
            }
        }
        return routes
    }
}
