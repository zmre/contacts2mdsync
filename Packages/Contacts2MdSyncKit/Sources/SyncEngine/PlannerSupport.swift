internal import ContactModel
internal import Foundation
internal import VaultIndex

/// A note an Apple contact will be exported to (for name resolution).
struct NamedNote {
    var contact: AppleContact
    /// Apple-side values (card precedence).
    var values: CanonicalContact
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
            for alias in entry.aliasNames { add(alias, title: entry.title, path: entry.path) }
            if entry.contact?.kind == .organization {
                organizationTitles[ComparisonKeys.name(entry.title)] = entry.title
            }
        }
        for candidate in candidates {
            add(candidate.title, title: candidate.title, path: candidate.path)
            for variant in TitleGenerator.nameVariants(for: candidate.values) {
                add(variant, title: candidate.title, path: candidate.path)
            }
            if candidate.values.kind == .organization {
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

extension ExportPlanner {
    /// The member that gets the cluster's one note: iCloud-backed first, then
    /// local, then lowest card id.
    static func primary(of members: [AppleContact]) -> AppleContact? {
        func rank(_ contact: AppleContact) -> Int {
            if contact.isICloudBacked { return 0 }
            if contact.cards.contains(where: { $0.accountKind == .local }) { return 1 }
            return 2
        }
        return members.min { (rank($0), $0.sortKey) < (rank($1), $1.sortKey) }
    }
}

extension AppleContact {
    /// Deterministic order that does not depend on the volatile unified id.
    var sortKey: String { cardsByPrecedence.first?.id ?? unifiedID }
}
