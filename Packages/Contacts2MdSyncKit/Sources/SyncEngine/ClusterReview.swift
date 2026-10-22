public import ContactModel

/// One member of a duplicate cluster, for display.
public struct ClusterMember: Codable, Hashable, Sendable {
    public var unifiedID: String
    public var title: String
    public var accounts: [AccountKind]
    /// Path of the note this member is (or will be) exported to, if any.
    public var path: String?
    /// Underlying card ids (stable identity for decisions).
    public var cardIDs: [String]
    /// Why this member is in the cluster: its direct links to other members.
    public var links: [ClusterLink]?
    /// The member's place in an earlier decision about these contacts,
    /// when the cluster is reported again (a new member appeared).
    public var prior: ClusterPriorAnswer?

    /// Creates a member.
    public init(
        unifiedID: String, title: String, accounts: [AccountKind], path: String?, cardIDs: [String],
        links: [ClusterLink]? = nil, prior: ClusterPriorAnswer? = nil
    ) {
        self.unifiedID = unifiedID
        self.title = title
        self.accounts = accounts
        self.path = path
        self.cardIDs = cardIDs
        self.links = links
        self.prior = prior
    }

    /// The member as a decision reference.
    public var ref: ContactRef { ContactRef(cardIDs: cardIDs, title: title) }
}

/// An earlier answer for one cluster member.
public enum ClusterPriorAnswer: Codable, Hashable, Sendable {
    /// One person (0-based group number, in member order).
    case person(Int)
    /// Not synced.
    case excluded
}

/// A direct link between two members of a duplicate cluster.
public struct ClusterLink: Codable, Hashable, Sendable {
    /// The other member (0-based index into the cluster's members).
    public var other: Int
    /// `same email jane@example.com`, `names match (Jane / Jane)`, …
    public var reasons: [String]

    /// Creates a link.
    public init(other: Int, reasons: [String]) {
        self.other = other
        self.reasons = reasons
    }
}

/// How the user split a duplicate cluster (`cluster-resolve`): each group
/// is one person, `excluded` members are not synced. Members are 0-based
/// indices into the cluster's members.
///
/// As a review choice it reads `resolve:1,2/3;exclude:4` (1-based member
/// numbers as `review list` shows them; groups separated by `/`).
public struct ClusterPartition: Hashable, Sendable {
    public var groups: [[Int]]
    public var excluded: [Int]

    /// Creates a partition (empty groups are dropped, members sorted).
    public init(groups: [[Int]], excluded: [Int] = []) {
        self.groups = groups.map { $0.sorted() }.filter { !$0.isEmpty }
        self.excluded = excluded.sorted()
    }

    /// Choice prefix.
    public static let prefix = "resolve:"

    /// Parses `resolve:1,2/3;exclude:4`; `nil` when malformed.
    public init?(choice: String) {
        guard choice.hasPrefix(Self.prefix) else { return nil }
        let body = choice.dropFirst(Self.prefix.count)
        let parts = body.split(separator: ";", omittingEmptySubsequences: false)
        guard let groupPart = parts.first, parts.count <= 2 else { return nil }
        func numbers(_ text: Substring) -> [Int]? {
            let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let values = items.map { Int($0) }
            // Range-checked before subtracting: `Int.min - 1` would trap.
            guard values.allSatisfy({ ($0 ?? 0) >= 1 }) else { return nil }
            return values.compactMap { $0.map { $0 - 1 } }
        }
        var groups: [[Int]] = []
        for group in groupPart.split(separator: "/") {
            guard let members = numbers(group), !members.isEmpty else { return nil }
            groups.append(members)
        }
        var excluded: [Int] = []
        if parts.count == 2 {
            let part = parts[1]
            guard part.hasPrefix("exclude:"), let members = numbers(part.dropFirst("exclude:".count)) else {
                return nil
            }
            excluded = members
        }
        self.init(groups: groups, excluded: excluded)
    }

    /// The choice string (`resolve:1,2/3;exclude:4`).
    public var choice: String {
        let groupText = groups.map { $0.map { String($0 + 1) }.joined(separator: ",") }.joined(separator: "/")
        let excludedText = excluded.isEmpty ? "" : ";exclude:" + excluded.map { String($0 + 1) }.joined(separator: ",")
        return Self.prefix + groupText + excludedText
    }

    /// Why the partition does not fit a cluster of `count` members, or `nil`
    /// when every member is in exactly one group or excluded.
    public func problem(memberCount count: Int) -> String? {
        let all = groups.flatMap { $0 } + excluded
        if let outside = all.first(where: { $0 >= count }) {
            return "there is no member \(outside + 1) (the cluster has \(count))"
        }
        let repeated = Dictionary(grouping: all, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        if let first = repeated.first { return "member \(first + 1) is listed more than once" }
        let missing = (0..<count).filter { !all.contains($0) }
        if !missing.isEmpty {
            return "every member needs a group or --exclude; missing: "
                + missing.map { String($0 + 1) }.joined(separator: ", ")
        }
        return nil
    }
}
