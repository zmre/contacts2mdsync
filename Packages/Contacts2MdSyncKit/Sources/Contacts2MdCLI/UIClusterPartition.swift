public import SyncEngine

// MARK: - Cluster partition (card multi-select)

/// The Duplicates screen's working answer for one cluster: which members
/// are the same person, which are different people, which are not synced.
/// Edited through the card selection (Same Person / Different People /
/// Don't Sync), with Undo and Reset; Apply records one `cluster-resolve`.
public struct UIClusterPartition: Hashable, Sendable {
    /// Where one member stands.
    public enum Assignment: Hashable, Sendable {
        /// One person (0-based; shown as Person A, B, …).
        case person(Int)
        /// Not synced.
        case excluded
    }

    public let memberCount: Int
    private var assignments: [Int: Assignment]
    private var initial: [Int: Assignment]
    private var history: [[Int: Assignment]] = []

    /// Nothing decided yet.
    public init(memberCount: Int) {
        self.memberCount = memberCount
        self.assignments = [:]
        self.initial = [:]
    }

    /// Prefilled from an earlier answer (new members stay undecided), or
    /// `nil` when no member has one.
    public init?(prior members: [ClusterMember]) {
        var assignments: [Int: Assignment] = [:]
        for (offset, member) in members.enumerated() {
            switch member.prior {
            case .person(let group): assignments[offset] = .person(group)
            case .excluded: assignments[offset] = .excluded
            case nil: continue
            }
        }
        guard !assignments.isEmpty else { return nil }
        self.memberCount = members.count
        self.assignments = Self.normalized(assignments)
        self.initial = self.assignments
    }

    /// The member's assignment, or `nil` while undecided.
    public func assignment(of member: Int) -> Assignment? { assignments[member] }

    /// People in display order (Person A first).
    public var people: [Int] {
        Set(assignments.values.compactMap { if case .person(let id) = $0 { id } else { nil } }).sorted()
    }

    /// Members of `person`, in member order.
    public func members(of person: Int) -> [Int] {
        assignments.filter { $0.value == .person(person) }.keys.sorted()
    }

    /// Members not synced.
    public var excludedMembers: [Int] { assignments.filter { $0.value == .excluded }.keys.sorted() }

    /// Members not decided yet.
    public var undecided: [Int] { (0..<memberCount).filter { assignments[$0] == nil } }

    /// Every member is decided: Apply is possible.
    public var isComplete: Bool { undecided.isEmpty && memberCount > 0 }

    /// Something changed since the starting partition.
    public var isEdited: Bool { assignments != initial }

    public var canUndo: Bool { !history.isEmpty }

    /// The selected members are one person (a new group; they leave any
    /// group they were in).
    public mutating func samePerson(_ selection: Set<Int>) {
        let members = valid(selection)
        guard !members.isEmpty else { return }
        record()
        let person = (people.max() ?? -1) + 1
        for member in members { assignments[member] = .person(person) }
        assignments = Self.normalized(assignments)
    }

    /// Each selected member is a person of their own.
    public mutating func differentPeople(_ selection: Set<Int>) {
        let members = valid(selection)
        guard !members.isEmpty else { return }
        record()
        var next = (people.max() ?? -1) + 1
        for member in members {
            assignments[member] = .person(next)
            next += 1
        }
        assignments = Self.normalized(assignments)
    }

    /// The selected members are not synced.
    public mutating func dontSync(_ selection: Set<Int>) {
        let members = valid(selection)
        guard !members.isEmpty else { return }
        record()
        for member in members { assignments[member] = .excluded }
        assignments = Self.normalized(assignments)
    }

    /// The selected members go back to undecided.
    public mutating func clear(_ selection: Set<Int>) {
        let members = valid(selection).filter { assignments[$0] != nil }
        guard !members.isEmpty else { return }
        record()
        for member in members { assignments[member] = nil }
        assignments = Self.normalized(assignments)
    }

    /// Reverts the last change.
    public mutating func undo() {
        guard let last = history.popLast() else { return }
        assignments = last
    }

    /// Back to the starting partition.
    public mutating func reset() {
        guard isEdited else { return }
        record()
        assignments = initial
    }

    /// The engine partition, once complete.
    public var partition: ClusterPartition? {
        guard isComplete else { return nil }
        return ClusterPartition(groups: people.map { members(of: $0) }, excluded: excludedMembers)
    }

    /// The decision-log answer (Apply), once complete.
    public func decision(itemID: String) -> UIReviewDecision? {
        partition.flatMap { UIDuplicateAction.resolve($0).decision(itemID: itemID) }
    }

    /// One chip per person, then Not synced and Undecided
    /// (`Person A: 2 cards · Person B: 1 card · Not synced: 1`).
    public var chips: [UIPartitionChip] {
        var chips = people.map { person in
            UIPartitionChip(kind: .person(person), title: Self.personName(person), count: members(of: person).count)
        }
        if !excludedMembers.isEmpty {
            chips.append(UIPartitionChip(kind: .excluded, title: "Not synced", count: excludedMembers.count))
        }
        if !undecided.isEmpty {
            chips.append(UIPartitionChip(kind: .undecided, title: "Undecided", count: undecided.count))
        }
        return chips
    }

    /// `Person A: 2 cards · Not synced: 1`.
    public var summary: String { chips.map(\.text).joined(separator: " · ") }

    /// The badge on a member's card (`Person A`, `Not synced`), or `nil` while undecided.
    public func badge(for member: Int) -> String? {
        switch assignments[member] {
        case .person(let person): Self.personName(person)
        case .excluded: "Not synced"
        case nil: nil
        }
    }

    /// `Person A`, `Person B`, … `Person Z`, `Person 27`.
    public static func personName(_ person: Int) -> String {
        guard person < 26, let scalar = UnicodeScalar(65 + person) else { return "Person \(person + 1)" }
        return "Person \(Character(scalar))"
    }

    private mutating func record() { history.append(assignments) }

    private func valid(_ selection: Set<Int>) -> [Int] { selection.filter { (0..<memberCount).contains($0) }.sorted() }

    /// People renumbered 0, 1, … in order of their first member, so the
    /// names (Person A, B, …) follow the cards.
    private static func normalized(_ assignments: [Int: Assignment]) -> [Int: Assignment] {
        var mapping: [Int: Int] = [:]
        for member in assignments.keys.sorted() {
            if case .person(let id) = assignments[member], mapping[id] == nil { mapping[id] = mapping.count }
        }
        return assignments.mapValues { assignment in
            if case .person(let id) = assignment { return .person(mapping[id] ?? id) }
            return assignment
        }
    }
}

/// One summary chip.
public struct UIPartitionChip: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case person(Int)
        case excluded
        case undecided
    }

    public var kind: Kind
    public var title: String
    public var count: Int

    public var id: String { title }

    /// `Person A: 2 cards`, `Not synced: 1`.
    public var text: String {
        if case .person = kind { return "\(title): \(count) \(count == 1 ? "card" : "cards")" }
        return "\(title): \(count)"
    }
}

// MARK: - Cluster groups (card multi-select)

extension UIDuplicateGroup {
    /// Contact cards of a cluster, in member order.
    public var memberCards: [UIDuplicateCard] { cards.filter { $0.member != nil } }

    /// The item id plus each member's cards, in member order. Linking cards
    /// in Contacts keeps the item id but changes this, so a partition being
    /// edited (by member number) never outlives the members it numbers.
    public var memberIdentity: [String] {
        [id] + memberCards.map { $0.cardIDs.sorted().joined(separator: "+") }
    }

    /// The partition to start editing from.
    public var startingPartition: UIClusterPartition {
        priorPartition ?? UIClusterPartition(memberCount: memberCards.count)
    }

    /// Card ids of the members of `person` (Open in Contacts to link them).
    public func cardIDs(of person: Int, in partition: UIClusterPartition) -> [String] {
        memberCards.filter { $0.member.map { partition.assignment(of: $0) == .person(person) } ?? false }
            .flatMap(\.cardIDs)
    }

    /// The confirmation for Apply: who gets a note and who is left out.
    public func applyMessage(_ partition: UIClusterPartition) -> String {
        func names(_ members: [Int]) -> String {
            members.compactMap { index in
                memberCards.first { $0.member == index }.map { "\($0.title) (\($0.heading))" }
            }
            .joined(separator: ", ")
        }
        func notes(_ members: [Int]) -> Int {
            members.filter { index in memberCards.first { $0.member == index }?.path != nil }.count
        }
        var parts: [String] = []
        for person in partition.people {
            let members = partition.members(of: person)
            let label = UIClusterPartition.personName(person)
            if members.count == 1 {
                parts.append("\(label): \(names(members)) syncs to its own note.")
            } else if notes(members) > 1 {
                // The engine never drops a note: each keeps syncing until the
                // cards are linked and one note is kept (merge records).
                parts.append(
                    "\(label): \(names(members)) are one person, but \(notes(members)) of them already have a "
                        + "note; each note keeps syncing until you link them in Contacts and keep one.")
            } else {
                parts.append("\(label): \(names(members)) are one person and sync to one note; link them in Contacts.")
            }
        }
        let excluded = partition.excludedMembers
        if !excluded.isEmpty {
            let stops = notes(excluded) > 0 ? "; a note they already have stops syncing" : ""
            parts.append("Not synced: \(names(excluded)). Nothing is deleted\(stops).")
        }
        return parts.joined(separator: "\n")
    }
}
