public import ContactModel

/// A group of unified Apple contacts that look like the same person
/// (typically an unlinked iCloud + Google pair).
public struct DuplicateCluster: Hashable, Sendable {
    /// Unified ids, sorted.
    public var memberIDs: [String]
    /// Why they were grouped (`same email`, `same phone`, `same name and company`).
    public var reasons: [String]
}

/// Strong-key matching keys for one contact (architecture §6).
public enum MatchKeys {
    /// Minimum digits for a phone number to count as a strong key (filters
    /// short codes and extensions-only junk).
    static let minimumPhoneDigits = 7

    /// `email:<key>`, `phone:<E.164>`, and (when both are set) `nameorg:<name>|<org>`.
    public static func keys(for contact: CanonicalContact, keyer: any PhoneKeyer) -> [(key: String, reason: String)] {
        var keys: [(String, String)] = contact.emails.map { ("email:" + ComparisonKeys.email($0.value), "same email") }
        for phone in contact.phones {
            let key = ComparisonKeys.phone(phone.value, keyer: keyer)
            if key.filter(\.isNumber).count >= minimumPhoneDigits { keys.append(("phone:" + key, "same phone")) }
        }
        if let name = nameKey(contact), let org = contact.company.map({ ComparisonKeys.name($0.name) }), !org.isEmpty {
            keys.append(("nameorg:\(name)|\(org)", "same name and company"))
        }
        return keys
    }

    /// The person's name key, or `nil` without name parts.
    public static func nameKey(_ contact: CanonicalContact) -> String? {
        guard contact.kind == .person, let name = TitleGenerator.personalName(contact.name) else { return nil }
        let key = ComparisonKeys.name(name)
        return key.isEmpty ? nil : key
    }
}

/// Union-find clustering of unified contacts on shared strong keys plus
/// exact name+organization (architecture §6, "Unlinked duplicate clusters").
///
/// Name-only matches never cluster: two different "John Smith"s without a
/// company would otherwise block each other's export.
public enum Clustering {
    /// Clusters with more than one member, ordered by first member id.
    /// Pairs for which `areDistinct` is true are never joined directly (a
    /// "distinct people" decision); they can still meet through a third member.
    public static func clusters(
        of contacts: [AppleContact], keyer: any PhoneKeyer,
        areDistinct: (AppleContact, AppleContact) -> Bool = { _, _ in false }
    ) -> [DuplicateCluster] {
        var parent = Array(contacts.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != root { (node, parent[node]) = (parent[node], root) }
            return root
        }

        var owners: [String: [Int]] = [:]
        var reasons: [Int: Set<String>] = [:]
        var pairReasons: [(member: Int, reason: String)] = []
        for (index, contact) in contacts.enumerated() {
            for (key, reason) in MatchKeys.keys(for: contact.contact, keyer: keyer) {
                let others = owners[key] ?? []
                if let other = others.first(where: { $0 != index && !areDistinct(contact, contacts[$0]) }) {
                    pairReasons.append((index, reason))
                    let (left, right) = (find(index), find(other))
                    if left != right { parent[max(left, right)] = min(left, right) }
                }
                owners[key, default: []].append(index)
            }
        }
        for (member, reason) in pairReasons { reasons[find(member), default: []].insert(reason) }

        let groups = Dictionary(grouping: contacts.indices, by: find).filter { $0.value.count > 1 }
        return groups.map { root, members in
            DuplicateCluster(
                memberIDs: members.map { contacts[$0].unifiedID }.sorted(),
                reasons: (reasons[root] ?? []).sorted()
            )
        }
        .sorted { $0.memberIDs[0] < $1.memberIDs[0] }
    }
}
