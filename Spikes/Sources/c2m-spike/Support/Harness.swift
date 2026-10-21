import Contacts
import Foundation

/// Identification rules for scratch contacts. A contact is a harness contact
/// only if BOTH hold:
///   1. "givenName familyName" starts with `namePrefix`, and
///   2. some URL value starts with `markerScheme`.
/// Every write path re-checks this on a fresh fetch right before saving.
enum Harness {
    static let namePrefix = "ZZ Spike "
    static let givenName = "ZZ Spike"
    static let markerLabel = "mdsync-spike"
    static let markerScheme = "x-mdsync-spike:"

    /// Keys needed to evaluate `isHarness`.
    nonisolated(unsafe) static let identityKeys: [any CNKeyDescriptor] = [
        CNContactIdentifierKey as any CNKeyDescriptor,
        CNContactGivenNameKey as any CNKeyDescriptor,
        CNContactFamilyNameKey as any CNKeyDescriptor,
        CNContactUrlAddressesKey as any CNKeyDescriptor,
    ]

    static func makeMarker(spike: String, kind: String) -> String {
        "\(markerScheme)\(spike):\(kind):\(UUID().uuidString.lowercased())"
    }

    static func displayName(_ contact: CNContact) -> String {
        guard
            contact.areKeysAvailable([
                CNContactGivenNameKey as any CNKeyDescriptor, CNContactFamilyNameKey as any CNKeyDescriptor,
            ])
        else { return "" }
        return [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func hasNamePrefix(_ contact: CNContact) -> Bool {
        displayName(contact).hasPrefix(namePrefix)
    }

    /// The first marker URL value, if any.
    static func marker(_ contact: CNContact) -> String? {
        guard contact.areKeysAvailable([CNContactUrlAddressesKey as any CNKeyDescriptor]) else { return nil }
        return contact.urlAddresses.map { $0.value as String }.first { $0.hasPrefix(markerScheme) }
    }

    static func isHarness(_ contact: CNContact) -> Bool {
        hasNamePrefix(contact) && marker(contact) != nil
    }

    /// Spike tag embedded in a marker, e.g. "s4" from "x-mdsync-spike:s4:icloud:<uuid>".
    static func spikeTag(_ marker: String) -> String? {
        marker.dropFirst(markerScheme.count).split(separator: ":").first.map(String.init)
    }

    static func kindTag(_ marker: String) -> String? {
        let parts = marker.dropFirst(markerScheme.count).split(separator: ":")
        return parts.count > 1 ? String(parts[1]) : nil
    }

    /// Finds the underlying card carrying exactly `marker` (full scan; the
    /// pre-save identifier of a new CNMutableContact is not trusted).
    static func locate(_ store: CNContactStore, marker: String, keys: [any CNKeyDescriptor] = []) throws -> CNContact? {
        var found: CNContact?
        let request = CNContactFetchRequest(keysToFetch: identityKeys + keys)
        request.unifyResults = false
        try store.enumerateContacts(with: request) { contact, stop in
            if isHarness(contact), contact.urlAddresses.contains(where: { ($0.value as String) == marker }) {
                found = contact
                stop.pointee = true
            }
        }
        return found
    }

    /// A fresh scratch card. The caller adds spike-specific fields.
    static func newCard(spike: String, kind: String, suffix: String) -> (CNMutableContact, String) {
        let card = CNMutableContact()
        card.contactType = .person
        card.givenName = givenName
        card.familyName = "\(spike.uppercased()) \(suffix)"
        let marker = makeMarker(spike: spike, kind: kind)
        card.urlAddresses = [CNLabeledValue(label: markerLabel, value: marker as NSString)]
        return (card, marker)
    }
}

/// Result of scanning the whole store for scratch cards.
struct HarnessScan {
    /// Underlying (non-unified) cards passing both checks.
    var harness: [CNContact] = []
    /// Name prefix matches but marker missing (e.g. server stripped the URL).
    /// Reported, never written to.
    var nameOnly: [CNContact] = []
    /// Marker present but name prefix missing. Reported, never written to.
    var markerOnly: [CNContact] = []
    var totalUnderlying = 0

    func harness(spike: String) -> [CNContact] {
        harness.filter { Harness.marker($0).flatMap(Harness.spikeTag) == spike }
    }

    /// Harness cards of one spike, re-fetched individually with `keys`
    /// (so the full-store scan itself stays cheap).
    func harness(spike: String, refetchingIn store: CNContactStore, keys: [any CNKeyDescriptor]) throws -> [CNContact] {
        let writer = SafeWriter(store: store)
        return try harness(spike: spike).map { try writer.verifiedCard($0.identifier, keys: keys) }
    }

    /// Scans every underlying card with `keys` (identity keys are always added).
    static func run(_ store: CNContactStore, extraKeys: [any CNKeyDescriptor] = []) throws -> HarnessScan {
        var scan = HarnessScan()
        let request = CNContactFetchRequest(keysToFetch: Harness.identityKeys + extraKeys)
        request.unifyResults = false
        try store.enumerateContacts(with: request) { contact, _ in
            scan.totalUnderlying += 1
            let named = Harness.hasNamePrefix(contact)
            let marked = Harness.marker(contact) != nil
            switch (named, marked) {
            case (true, true): scan.harness.append(contact)
            case (true, false): scan.nameOnly.append(contact)
            case (false, true): scan.markerOnly.append(contact)
            default: break
            }
        }
        return scan
    }
}

/// The ONLY path through which the harness writes to Contacts.
/// Every mutation re-fetches the target card(s) by identifier (unified
/// results off) and refuses unless they pass `Harness.isHarness`.
struct SafeWriter {
    let store: CNContactStore
    var author: String? = nil

    /// Fetches one underlying card fresh and asserts it is a harness card.
    func verifiedCard(_ id: String, keys: [any CNKeyDescriptor]) throws -> CNContact {
        guard let card = try fetchUnderlying(store, id: id, keys: keys) else {
            throw SpikeError("Card \(id) not found; refusing to write.")
        }
        guard Harness.isHarness(card) else {
            throw SpikeError("SAFETY: card \(id) is not a harness card (name prefix + marker). Refusing to write.")
        }
        return card
    }

    private func execute(_ request: CNSaveRequest) throws {
        if let author { request.transactionAuthor = author }
        try catchingObjC { try store.execute(request) }
    }

    func add(_ card: CNMutableContact, to containerID: String) throws {
        guard Harness.isHarness(card) else {
            throw SpikeError("SAFETY: refusing to create a card without the harness name prefix and marker.")
        }
        let request = CNSaveRequest()
        request.add(card, toContainerWithIdentifier: containerID)
        try execute(request)
    }

    /// Re-fetches card `id` with `keys`, lets `mutate` change it, re-checks the
    /// marker survived the mutation, and saves. Returns the saved mutable copy.
    @discardableResult
    func update(
        _ id: String, keys: [any CNKeyDescriptor], _ mutate: (CNMutableContact) throws -> Void
    ) throws
        -> CNMutableContact
    {
        let fresh = try verifiedCard(id, keys: keys)
        guard let mutable = fresh.mutableCopy() as? CNMutableContact else { throw SpikeError("mutableCopy failed") }
        try catchingObjC { try mutate(mutable) }
        guard Harness.isHarness(mutable) else {
            throw SpikeError("SAFETY: mutation removed the harness name prefix or marker; not saving.")
        }
        let request = CNSaveRequest()
        request.update(mutable)
        try execute(request)
        return mutable
    }

    /// Saves a mutable copy of a UNIFIED contact. Every underlying member must
    /// be a harness card (checked by the caller via `members` and re-checked here).
    func updateUnified(_ unified: CNMutableContact, memberIDs: [String]) throws {
        guard !memberIDs.isEmpty else { throw SpikeError("SAFETY: no member ids supplied for unified write.") }
        for id in memberIDs { _ = try verifiedCard(id, keys: []) }
        let request = CNSaveRequest()
        request.update(unified)
        try execute(request)
    }

    func delete(_ id: String) throws {
        let fresh = try verifiedCard(id, keys: [])
        guard let mutable = fresh.mutableCopy() as? CNMutableContact else { throw SpikeError("mutableCopy failed") }
        let request = CNSaveRequest()
        request.delete(mutable)
        try execute(request)
    }
}

/// Read-only fetch of one underlying (non-unified) card; identity keys always included.
func fetchUnderlying(_ store: CNContactStore, id: String, keys: [any CNKeyDescriptor]) throws -> CNContact? {
    let request = CNContactFetchRequest(keysToFetch: Harness.identityKeys + keys)
    request.unifyResults = false
    request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
    var found: CNContact?
    try catchingObjC {
        try store.enumerateContacts(with: request) { contact, stop in
            if contact.identifier == id {
                found = contact
                stop.pointee = true
            }
        }
    }
    return found
}

/// All underlying card identifiers that make up `unified`.
func memberIDs(of unified: CNContact, in store: CNContactStore) throws -> [String] {
    var ids: [String] = []
    let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor])
    request.unifyResults = false
    try store.enumerateContacts(with: request) { contact, _ in
        if unified.identifier == contact.identifier || unified.isUnifiedWithContact(withIdentifier: contact.identifier)
        {
            ids.append(contact.identifier)
        }
    }
    return ids
}

/// Prints a plan and returns whether to proceed. Without `--yes` nothing is written.
func confirmPlan(_ title: String, _ steps: [String], yes: Bool) -> Bool {
    print("PLAN: \(title)")
    for step in steps { print("  - \(step)") }
    print("  (only cards named \"\(Harness.namePrefix)…\" carrying a \(Harness.markerScheme) URL are ever modified)")
    if !yes {
        print("DRY RUN: nothing written. Re-run with --yes to perform the steps above.")
        return false
    }
    return true
}
