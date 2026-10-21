import Contacts
import Observation

/// Tracks Contacts authorization and, once granted, the number of contacts.
@MainActor
@Observable
final class ContactsAccessModel {
    private(set) var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    private(set) var contactCount: Int?
    private(set) var errorMessage: String?

    var isAuthorized: Bool { status == .authorized }
    var canRequestAccess: Bool { status == .notDetermined }

    var statusDescription: String {
        switch status {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized: "Granted"
        @unknown default: "Unknown"
        }
    }

    func refresh() async {
        status = CNContactStore.authorizationStatus(for: .contacts)
        guard isAuthorized else {
            contactCount = nil
            return
        }
        do {
            contactCount = try await Self.countContacts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestAccess() async {
        do {
            _ = try await CNContactStore().requestAccess(for: .contacts)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    /// Counts contacts fetching identifiers only. `enumerateContacts` blocks,
    /// so it runs on the concurrent executor, never the main actor.
    @concurrent
    nonisolated private static func countContacts() async throws -> Int {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        request.unifyResults = true
        var count = 0
        try store.enumerateContacts(with: request) { _, _ in count += 1 }
        return count
    }
}
