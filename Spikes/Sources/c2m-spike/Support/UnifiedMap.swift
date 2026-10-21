import Contacts
import Foundation

/// Underlying card -> container and -> unified contact identifier.
/// There is no public bulk API for links, so each card is resolved with
/// `unifiedContact(withIdentifier:)` (one fetch per card; a few seconds for
/// thousands of cards). Progress goes to stderr.
struct UnifiedMap {
    struct Card {
        var id: String
        var containerID: String
        var unifiedID: String?
    }

    var cards: [Card] = []
    var resolveFailures = 0
    /// Count from a direct unified fetch, to cross-check the mapping.
    var unifiedFetchCount = 0

    var unifiedIDs: Set<String> { Set(cards.compactMap(\.unifiedID)) }

    /// unified id -> member cards
    var members: [String: [Card]] {
        Dictionary(grouping: cards.filter { $0.unifiedID != nil }, by: { $0.unifiedID! })
    }

    static func build(_ store: CNContactStore, containers: [CNContainer]) throws -> UnifiedMap {
        var map = UnifiedMap()
        let idKey = [CNContactIdentifierKey as any CNKeyDescriptor]
        for container in containers {
            let request = CNContactFetchRequest(keysToFetch: idKey)
            request.unifyResults = false
            request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
            try store.enumerateContacts(with: request) { contact, _ in
                map.cards.append(Card(id: contact.identifier, containerID: container.identifier))
            }
        }
        for index in map.cards.indices {
            if index > 0, index % 500 == 0 { stderrLine("  resolved \(index)/\(map.cards.count) cards...") }
            do {
                let unified = try catchingObjC {
                    try store.unifiedContact(withIdentifier: map.cards[index].id, keysToFetch: idKey)
                }
                map.cards[index].unifiedID = unified.identifier
            } catch {
                map.resolveFailures += 1
            }
        }
        let unifiedRequest = CNContactFetchRequest(keysToFetch: idKey)
        unifiedRequest.unifyResults = true
        try store.enumerateContacts(with: unifiedRequest) { _, _ in map.unifiedFetchCount += 1 }
        return map
    }
}
