internal import ContactModel
internal import Foundation
internal import VaultIndex

/// A note an Apple contact will be exported to (for name resolution).
struct NamedNote {
    var contact: AppleContact
    var title: String
    var path: String
}

/// Resolves Apple relation names and organization names to note titles.
///
/// A name resolves only when exactly one note answers to it, counted by
/// note path (two different "John Smith" notes make "John Smith" ambiguous,
/// even though their titles are equal).
struct NameResolver {
    /// Name key → title per note path.
    private var notesByKey: [String: [String: String]] = [:]
    private var organizationTitles: [String: String] = [:]

    init(candidates: [NamedNote], index: VaultIndex) {
        for entry in index.contacts {
            add(entry.title, title: entry.title, path: entry.path)
            for alias in entry.note?.aliasNames ?? [] { add(alias, title: entry.title, path: entry.path) }
            if entry.contact?.kind == .organization {
                organizationTitles[ComparisonKeys.name(entry.title)] = entry.title
            }
        }
        for candidate in candidates {
            add(candidate.title, title: candidate.title, path: candidate.path)
            for variant in TitleGenerator.nameVariants(for: candidate.contact.contact) {
                add(variant, title: candidate.title, path: candidate.path)
            }
            if candidate.contact.contact.kind == .organization {
                organizationTitles[ComparisonKeys.name(candidate.title)] = candidate.title
            }
        }
    }

    private mutating func add(_ name: String, title: String, path: String) {
        notesByKey[ComparisonKeys.name(name), default: [:]][path] = title
    }

    /// `.name(X)` → `.wikilink(title)` when exactly one note answers to X.
    func resolve(_ ref: RelationshipRef) -> RelationshipRef {
        guard case .name(let name)? = ref.target, let notes = notesByKey[ComparisonKeys.name(name)],
            notes.count == 1, let title = notes.first?.value
        else { return ref }
        var resolved = ref
        resolved.target = .wikilink(title)
        return resolved
    }

    /// The `company:` value: an existing wikilink naming the same
    /// organization is kept; otherwise a wikilink when an organization note
    /// with that title exists, else plain text.
    func company(for contact: CanonicalContact, existing: CompanyRef?) -> CompanyRef? {
        guard let company = contact.company else { return nil }
        let key = ComparisonKeys.name(company.name)
        if let existing, ComparisonKeys.name(existing.name) == key { return existing }
        if contact.kind == .person, let title = organizationTitles[key] { return .wikilink(title) }
        return company
    }
}

/// The create gate (architecture §6): a new Apple contact that matches an
/// existing note nobody is bound to is not created automatically.
///
/// Strong keys (email, phone, name+company) match any unbound contact note.
/// Orphaned notes — they carry an `c2mdsync.id` but no Apple contact is bound
/// to it (e.g. the per-device state was lost) — were written by us, so a
/// plain name match blocks creation too.
struct CreateGate {
    private var byKey: [String: (path: String, reason: String)] = [:]
    private let keyer: any PhoneKeyer

    init(index: VaultIndex, records: RecordMap, snapshot: AppleSnapshot, keyer: any PhoneKeyer) {
        self.keyer = keyer
        let bound = records.ids.union(snapshot.contacts.flatMap(\.stampIDs))
        for entry in index.contacts {
            guard let contact = entry.contact else { continue }
            if let id = contact.sync.id, bound.contains(id) { continue }
            for (key, reason) in MatchKeys.keys(for: contact, keyer: keyer) where byKey[key] == nil {
                byKey[key] = (entry.path, reason)
            }
            if contact.sync.id != nil {
                let key = "name:" + ComparisonKeys.name(entry.title)
                if byKey[key] == nil { byKey[key] = (entry.path, "same name as a previously synced note") }
            }
        }
    }

    func match(_ contact: AppleContact) -> (path: String, reason: String)? {
        for (key, _) in MatchKeys.keys(for: contact.contact, keyer: keyer) {
            if let hit = byKey[key] { return hit }
        }
        return byKey["name:" + ComparisonKeys.name(TitleGenerator.title(for: contact.contact))]
    }
}
