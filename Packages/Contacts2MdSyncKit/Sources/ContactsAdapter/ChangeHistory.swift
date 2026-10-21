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
    public static func changeHistory(
        in store: CNContactStore,
        keysToFetch: [any CNKeyDescriptor],
        since token: Data?
    ) throws -> ChangeHistoryBatch {
        let result = try store.c2m_changeHistoryEvents(for: keysToFetch, token: token)
        return ChangeHistoryBatch(events: result.events, currentToken: result.currentHistoryToken)
    }
}
