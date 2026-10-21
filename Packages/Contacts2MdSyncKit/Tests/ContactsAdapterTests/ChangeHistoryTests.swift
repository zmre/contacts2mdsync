import ContactModel
import Contacts
import ContactsAdapter
import Foundation
import Testing

@Suite("Change history mapping")
struct ChangeHistoryTests {
    typealias Event = ContactsAdapter.HistoryEvent

    let token = Data("old".utf8)
    let newToken = Data("new".utf8)

    @Test("contact, member and group events fold into changed / deleted cards and a groups flag")
    func folds() {
        let events: [Event] = [
            .contactChanged("a"), .memberChanged("b"), .contactChanged("a"), .contactDeleted("c"), .groupChanged,
        ]
        let result = ContactsAdapter.summarize(events, since: token, newToken: newToken)
        #expect(
            result
                == .changes(
                    HistoryChanges(
                        changedCardIDs: ["a", "b"], deletedCardIDs: ["c"], groupsChanged: true, eventCount: 5,
                        token: newToken)))
    }

    @Test("DropEverything or no starting token → reset (full snapshot)")
    func reset() {
        #expect(
            ContactsAdapter.summarize([.contactChanged("a"), .dropEverything], since: token, newToken: newToken)
                == .reset(token: newToken))
        let noToken = ContactsAdapter.summarize([.contactChanged("a")], since: nil, newToken: newToken)
        #expect(noToken == .reset(token: newToken))
    }

    @Test("no events: an empty change set with the new token")
    func empty() {
        guard case .changes(let changes) = ContactsAdapter.summarize([], since: token, newToken: newToken) else {
            Issue.record("expected changes")
            return
        }
        #expect(changes.isEmpty && changes.token == newToken)
    }

    @Test("errors 603 and 604 are token errors; others are not")
    func tokenErrors() {
        #expect(ContactsAdapter.isTokenError(NSError(domain: CNErrorDomain, code: 603)))
        #expect(ContactsAdapter.isTokenError(NSError(domain: CNErrorDomain, code: 604)))
        #expect(!ContactsAdapter.isTokenError(NSError(domain: CNErrorDomain, code: 100)))
        #expect(!ContactsAdapter.isTokenError(NSError(domain: NSCocoaErrorDomain, code: 603)))
    }
}
