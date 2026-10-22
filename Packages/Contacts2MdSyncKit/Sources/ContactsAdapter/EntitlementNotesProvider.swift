public import ContactModel
internal import Contacts
internal import Foundation

/// Contacts notes through `CNContactNoteKey` (the notes entitlement).
///
/// Sync does not need this provider: with the entitlement,
/// `CNContactStoreAdapter` reads notes in its snapshot and `CardWriter`
/// writes `.note` edits in the same save request as every other field. It
/// exists so the app and `status` can report the notes source through one
/// `NotesProvider` seam, and for one-off reads and writes outside a sync.
public struct EntitlementNotesProvider: NotesProvider {
    public let source = NotesSource.entitlement

    /// Creates a provider.
    public init() {}

    public func availability() -> NotesAvailability {
        guard CNContactStoreAdapter.isAuthorized else { return .unavailable("Contacts access not granted") }
        return CNContactStoreAdapter.notesAvailable(in: CNContactStore())
            ? .entitlement : .unavailable("the notes entitlement is not present in this build")
    }

    public func readAll(cardIDs: [String]?) throws -> [String: String?] {
        try CNContactStoreAdapter.ensureAccess()
        let store = CNContactStore()
        guard CNContactStoreAdapter.notesAvailable(in: store) else {
            throw NotesUnavailableError("the notes entitlement is not present in this build")
        }
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey, CNContactNoteKey] as [NSString])
        request.unifyResults = false
        if let cardIDs { request.predicate = CNContact.predicateForContacts(withIdentifiers: cardIDs) }
        var notes: [String: String?] = [:]
        try store.enumerateContacts(with: request) { contact, _ in
            // Guarded: reading an unfetched key raises.
            notes[contact.identifier] = .some(contact.isKeyAvailable(CNContactNoteKey) ? contact.note : nil)
        }
        return notes
    }

    public func write(_ notes: [String: String?]) throws -> NotesWriteResult {
        try CNContactStoreAdapter.ensureAccess()
        let store = CNContactStore()
        guard CNContactStoreAdapter.notesAvailable(in: store) else {
            throw NotesUnavailableError("the notes entitlement is not present in this build")
        }
        var result = NotesWriteResult()
        for (id, text) in notes.sorted(by: { $0.key < $1.key }) {
            do {
                let request = CNContactFetchRequest(
                    keysToFetch: [CNContactIdentifierKey, CNContactNoteKey] as [NSString])
                request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
                request.unifyResults = false
                var card: CNContact?
                try store.enumerateContacts(with: request) { contact, stop in
                    card = contact
                    stop.pointee = true
                }
                guard let mutable = card?.mutableCopy() as? CNMutableContact else {
                    result.failed[id] = ContactStoreError.cardNotFound(id).description
                    continue
                }
                mutable.note = text ?? ""
                let save = CNSaveRequest()
                save.update(mutable)
                try store.execute(save)
                result.written.append(id)
            } catch {
                result.failed[id] = String(describing: error)
            }
        }
        return result
    }
}
