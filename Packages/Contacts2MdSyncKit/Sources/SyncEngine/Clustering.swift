public import ContactModel

/// A group of unified Apple contacts that look like the same person
/// (typically an unlinked iCloud + Google pair).
public struct DuplicateCluster: Hashable, Sendable {
    /// Unified ids, sorted.
    public var memberIDs: [String]
    /// Why they were grouped, summarized (`same email`, `same name`, …).
    public var reasons: [String]
    /// Every direct edge between two members and its reasons.
    public var links: [DuplicateLink]
}

/// One edge of a duplicate cluster: why two unified contacts were joined.
public struct DuplicateLink: Hashable, Sendable {
    public var first: String
    public var second: String
    /// `same email jane@example.com`, `names match (Jane / Jane)`, …
    public var reasons: [String]
}

/// Strong-key matching keys for one contact (architecture §6).
public enum MatchKeys {
    /// Minimum digits for a phone number to count as a strong key (filters
    /// short codes and extensions-only junk).
    static let minimumPhoneDigits = 7

    /// `email:<key>`, `phone:<E.164>`, and (when both are set) `nameorg:<name>|<org>`.
    /// Used by note ↔ contact matching, where names are checked separately.
    public static func keys(for contact: CanonicalContact, keyer: any PhoneKeyer) -> [(key: String, reason: String)] {
        var keys: [(String, String)] = contact.emails.map { ("email:" + ComparisonKeys.email($0.value), "same email") }
        for phone in contact.phones {
            if let key = phoneKey(phone.value, keyer: keyer) { keys.append(("phone:" + key, "same phone")) }
        }
        if let name = nameKey(contact), let org = organizationKey(contact) {
            keys.append(("nameorg:\(name)|\(org)", "same name and company"))
        }
        return keys
    }

    /// The phone's comparison key when it has enough digits to mean anything.
    static func phoneKey(_ raw: String, keyer: any PhoneKeyer) -> String? {
        let key = ComparisonKeys.phone(raw, keyer: keyer)
        return key.filter(\.isNumber).count >= minimumPhoneDigits ? key : nil
    }

    /// Personal phones (mobile, iPhone, unlabeled) → display value. Household
    /// and office numbers (`home`, `main`, `work`, …) are left out: spouses
    /// and colleagues share them (`PhoneLabels.isHousehold`).
    public static func personalPhones(_ contact: CanonicalContact, keyer: any PhoneKeyer) -> [String: String] {
        var phones: [String: String] = [:]
        for phone in contact.phones where !PhoneLabels.isHousehold(phone.label) {
            if let key = phoneKey(phone.value, keyer: keyer), phones[key] == nil { phones[key] = phone.value }
        }
        return phones
    }

    /// Email key → display value.
    public static func emails(_ contact: CanonicalContact) -> [String: String] {
        var emails: [String: String] = [:]
        for email in contact.emails {
            let key = ComparisonKeys.email(email.value)
            if !key.isEmpty, emails[key] == nil { emails[key] = email.value }
        }
        return emails
    }

    /// The person's name key, or `nil` without name parts.
    public static func nameKey(_ contact: CanonicalContact) -> String? {
        guard contact.kind == .person, let name = TitleGenerator.personalName(contact.name) else { return nil }
        let key = ComparisonKeys.name(name)
        return key.isEmpty ? nil : key
    }

    /// The organization name key, or `nil` without one.
    public static func organizationKey(_ contact: CanonicalContact) -> String? {
        guard let name = contact.company?.name else { return nil }
        let key = ComparisonKeys.name(name)
        return key.isEmpty ? nil : key
    }
}

/// Union-find clustering of unified contacts (architecture §6, "Unlinked
/// duplicate clusters"). Two contacts are joined by an edge when
///
/// - their full names are equal (and so are their organizations, when both
///   have one), or two organization-only contacts have the same organization;
/// - or they share an email **and** their names are compatible
///   (`NameCompatibility`). A shared personal phone (mobile, iPhone,
///   unlabeled) is reported alongside, but never creates an edge.
///
/// A shared phone alone never joins anyone: spouses share a home number.
/// Household and office numbers never count at all. An edge that would put
/// two incompatible names in one cluster is dropped, so a card that fits
/// both spouses (an organization or an initial on the family email) joins
/// only one of them; only the user's own decisions join such names.
public enum Clustering {
    /// Clusters with more than one member, ordered by first member id.
    /// Pairs for which `areDistinct` is true are never joined directly (a
    /// "distinct people" decision or different groups of a cluster
    /// resolution); they can still meet through a third member. Each list in
    /// `decidedSame` (unified ids) was declared one person and is joined
    /// even without an edge.
    public static func clusters(
        of contacts: [AppleContact], keyer: any PhoneKeyer,
        areDistinct: (AppleContact, AppleContact) -> Bool = { _, _ in false },
        decidedSame: [[String]] = []
    ) -> [DuplicateCluster] {
        let facts = contacts.map { Facts($0.contact, keyer: keyer) }
        var components = Components(count: contacts.count)
        var links: [Edge] = []
        // Edges are judged pair by pair; a member compatible with two people
        // (no person name, an initial) must not bridge them into one cluster.
        let namesFit = { (one: Int, other: Int) in
            NameCompatibility.verdict(facts[one].names, facts[other].names).isCompatible
        }
        for (left, right) in candidatePairs(facts) where !areDistinct(contacts[left], contacts[right]) {
            guard let edge = edge(facts[left], facts[right]), components.everyPair(left, right, fit: namesFit) else {
                continue
            }
            components.union(left, right)
            links.append(Edge(left: left, right: right, reasons: edge.reasons, kinds: edge.kinds))
        }
        let position = Dictionary(
            contacts.enumerated().map { ($1.unifiedID, $0) }, uniquingKeysWith: { first, _ in first })
        for group in decidedSame {
            join(group.compactMap { position[$0] }.sorted(), components: &components, links: &links)
        }

        let roots = contacts.indices.map { components.find($0) }
        let groups = Dictionary(grouping: contacts.indices) { roots[$0] }.filter { $0.value.count > 1 }
        let linksByRoot = Dictionary(grouping: links) { roots[$0.left] }
        return groups.map { root, members in
            let clusterLinks = linksByRoot[root] ?? []
            return DuplicateCluster(
                memberIDs: members.map { contacts[$0].unifiedID }.sorted(),
                reasons: clusterLinks.reduce(into: Set<String>()) { $0.formUnion($1.kinds) }.sorted(),
                links: clusterLinks.map {
                    DuplicateLink(
                        first: contacts[$0.left].unifiedID, second: contacts[$0.right].unifiedID, reasons: $0.reasons)
                })
        }
        .sorted { $0.memberIDs[0] < $1.memberIDs[0] }
    }

    /// Joins the members (sorted indices) of one group the user declared one
    /// person, even without an edge; a pair already linked keeps its reasons
    /// and gains the decision, so each pair has one link.
    static func join(_ members: [Int], components: inout Components, links: inout [Edge]) {
        let decision = "same person (your decision)"
        for (left, right) in zip(members, members.dropFirst()) {
            components.union(left, right)
            if let existing = links.firstIndex(where: { $0.left == left && $0.right == right }) {
                links[existing].reasons.append(decision)
                links[existing].kinds.insert("your decision")
            } else {
                links.append(Edge(left: left, right: right, reasons: [decision], kinds: ["your decision"]))
            }
        }
    }

    /// A direct edge between two contact indices.
    struct Edge {
        var left: Int
        var right: Int
        var reasons: [String]
        /// Summary kinds (`same email`, `same name`, …) for the cluster's reasons.
        var kinds: Set<String>
    }

    /// Union-find over contact indices that keeps each component's members.
    struct Components {
        private var parent: [Int]
        private var members: [Int: [Int]]

        init(count: Int) {
            parent = Array(0..<count)
            members = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, [$0]) })
        }

        mutating func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != root { (node, parent[node]) = (parent[node], root) }
            return root
        }

        mutating func union(_ left: Int, _ right: Int) {
            let (first, second) = (find(left), find(right))
            guard first != second else { return }
            let (root, child) = (min(first, second), max(first, second))
            parent[child] = root
            members[root, default: []] += members.removeValue(forKey: child) ?? []
        }

        /// `fit` holds for every member of `left`'s component against every
        /// member of `right`'s (trivially when they are already one).
        mutating func everyPair(_ left: Int, _ right: Int, fit: (Int, Int) -> Bool) -> Bool {
            let (first, second) = (find(left), find(right))
            guard first != second else { return true }
            let others = members[second] ?? []
            return (members[first] ?? []).allSatisfy { one in others.allSatisfy { fit(one, $0) } }
        }
    }

    /// What clustering looks at for one contact.
    struct Facts {
        var title: String
        var nameKey: String?
        var organization: String?
        var organizationName: String?
        var emails: [String: String]
        var phones: [String: String]
        var names: NameCompatibility.Profile

        init(_ contact: CanonicalContact, keyer: any PhoneKeyer) {
            title = TitleGenerator.title(for: contact)
            nameKey = MatchKeys.nameKey(contact)
            organization = MatchKeys.organizationKey(contact)
            organizationName = contact.company?.name
            emails = MatchKeys.emails(contact)
            phones = MatchKeys.personalPhones(contact, keyer: keyer)
            names = NameCompatibility.Profile(contact)
        }

        /// Keys two contacts must share to be worth comparing.
        var indexKeys: [String] {
            var keys = emails.keys.map { "email:" + $0 }
            if let nameKey { keys.append("name:" + nameKey) }
            if nameKey == nil, let organization { keys.append("org:" + organization) }
            return keys
        }
    }

    /// Pairs (lower index first) sharing an email, a name or an organization.
    static func candidatePairs(_ facts: [Facts]) -> [(Int, Int)] {
        var owners: [String: [Int]] = [:]
        for (index, fact) in facts.enumerated() {
            for key in fact.indexKeys { owners[key, default: []].append(index) }
        }
        var seen = Set<[Int]>()
        var pairs: [(Int, Int)] = []
        for key in owners.keys.sorted() {
            let members = owners[key] ?? []
            for (offset, left) in members.enumerated() {
                for right in members[(offset + 1)...] where left != right && seen.insert([left, right]).inserted {
                    pairs.append((left, right))
                }
            }
        }
        return pairs.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    /// The edge between two contacts, or `nil` when they are not joined.
    static func edge(_ lhs: Facts, _ rhs: Facts) -> (reasons: [String], kinds: Set<String>)? {
        var reasons: [String] = []
        var kinds = Set<String>()
        let bothOrganized = lhs.organization != nil && rhs.organization != nil
        if let name = lhs.nameKey, name == rhs.nameKey, !bothOrganized || lhs.organization == rhs.organization {
            if bothOrganized {
                reasons.append("same name and company \"\(lhs.title)\", \(lhs.organizationName ?? "")")
                kinds.insert("same name and company")
            } else {
                reasons.append("same name \"\(lhs.title)\"")
                kinds.insert("same name")
            }
        } else if lhs.nameKey == nil, rhs.nameKey == nil, let organization = lhs.organization,
            organization == rhs.organization
        {
            reasons.append("same organization \"\(lhs.organizationName ?? lhs.title)\"")
            kinds.insert("same organization")
        }
        let verdict = NameCompatibility.verdict(lhs.names, rhs.names)
        let sharedEmails = Set(lhs.emails.keys).intersection(rhs.emails.keys).sorted()
        if !sharedEmails.isEmpty, verdict.isCompatible {
            reasons += sharedEmails.map { "same email \(lhs.emails[$0] ?? $0)" }
            kinds.insert("same email")
            let sharedPhones = Set(lhs.phones.keys).intersection(rhs.phones.keys).sorted()
            reasons += sharedPhones.map { "same mobile \(lhs.phones[$0] ?? $0)" }
            if !sharedPhones.isEmpty { kinds.insert("same phone") }
            switch verdict {
            case .compatible(let detail): reasons.append("names match (\(detail))")
            case .noPersonName: reasons.append("one has no person name")
            case .incompatible: break
            }
        }
        return kinds.isEmpty ? nil : (reasons, kinds)
    }
}
