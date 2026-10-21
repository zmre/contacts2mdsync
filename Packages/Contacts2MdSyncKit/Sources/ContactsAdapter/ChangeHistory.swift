public import ContactModel
public import Contacts
internal import ContactsShim
public import Foundation

extension ContactsAdapter {
    /// One drained page of Contacts change history.
    public struct ChangeHistoryBatch {
        /// Events in the order the store reported them.
        public let events: [CNChangeHistoryEvent]
        /// Token to persist and pass as `since` on the next call.
        public let currentToken: Data?
    }

    /// Reads all change-history events since `token` (or the full history
    /// when `nil`). Objective-C exceptions raised by Contacts.framework are
    /// converted to thrown errors in `C2MContactsShimErrorDomain`.
    ///
    /// With `unify == false` contact events carry underlying card ids, which
    /// is what the sync engine keys records on. `excludingAuthors` hides
    /// saves tagged with those `transactionAuthor`s (our own writes, spike S3).
    public static func changeHistory(
        in store: CNContactStore,
        keysToFetch: [any CNKeyDescriptor],
        since token: Data?,
        unify: Bool = true,
        excludingAuthors: [String] = []
    ) throws -> ChangeHistoryBatch {
        let result = try store.c2m_changeHistoryEvents(
            for: keysToFetch, token: token, unify: unify, excludingAuthors: excludingAuthors)
        return ChangeHistoryBatch(events: result.events, currentToken: result.currentHistoryToken)
    }

    /// What one history event means for the sync engine.
    public enum HistoryEvent: Hashable, Sendable {
        /// The token is unusable; everything must be re-read.
        case dropEverything
        /// A card was added or updated.
        case contactChanged(String)
        /// A card was deleted.
        case contactDeleted(String)
        /// A card joined or left a group.
        case memberChanged(String)
        /// A group was added, renamed or deleted, or a subgroup changed.
        case groupChanged
    }

    /// Classifies a Contacts.framework event (group events arrive even with
    /// `includeGroupChanges == false`, spike S3, so they are filtered by class).
    public static func classify(_ event: CNChangeHistoryEvent) -> HistoryEvent? {
        switch event {
        case is CNChangeHistoryDropEverythingEvent: return .dropEverything
        case let added as CNChangeHistoryAddContactEvent: return .contactChanged(added.contact.identifier)
        case let updated as CNChangeHistoryUpdateContactEvent: return .contactChanged(updated.contact.identifier)
        case let deleted as CNChangeHistoryDeleteContactEvent: return .contactDeleted(deleted.contactIdentifier)
        case let joined as CNChangeHistoryAddMemberToGroupEvent: return .memberChanged(joined.member.identifier)
        case let left as CNChangeHistoryRemoveMemberFromGroupEvent: return .memberChanged(left.member.identifier)
        case is CNChangeHistoryAddGroupEvent, is CNChangeHistoryUpdateGroupEvent, is CNChangeHistoryDeleteGroupEvent,
            is CNChangeHistoryAddSubgroupToGroupEvent, is CNChangeHistoryRemoveSubgroupFromGroupEvent:
            return .groupChanged
        default: return nil
        }
    }

    /// Folds classified events into a `HistoryResult` (pure; unit-tested).
    /// `DropEverything` or a `nil` starting token means "reset": the caller
    /// takes a full snapshot.
    public static func summarize(_ events: [HistoryEvent], since token: Data?, newToken: Data?) -> HistoryResult {
        guard token != nil, !events.contains(.dropEverything) else { return .reset(token: newToken) }
        var changed: [String] = []
        var deleted: [String] = []
        var seen = Set<String>()
        var groupsChanged = false
        for event in events {
            switch event {
            case .dropEverything: continue
            case .contactChanged(let id), .memberChanged(let id):
                if seen.insert("c:" + id).inserted { changed.append(id) }
            case .contactDeleted(let id):
                if seen.insert("d:" + id).inserted { deleted.append(id) }
            case .groupChanged: groupsChanged = true
            }
        }
        return .changes(
            HistoryChanges(
                changedCardIDs: changed, deletedCardIDs: deleted, groupsChanged: groupsChanged,
                eventCount: events.count, token: newToken))
    }

    /// `true` for Contacts' "history expired" (603) and "invalid token" (604) errors.
    public static func isTokenError(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == CNErrorDomain
            && [CNError.Code.changeHistoryExpired.rawValue, CNError.Code.changeHistoryInvalidAnchor.rawValue]
                .contains(error.code)
    }
}
