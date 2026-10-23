public import ContactModel
public import Foundation

/// An Apple contact as referenced by a decision or review item: its
/// underlying card ids (the unified id is volatile, spike S4) and a title for
/// display. A contact matches when it still has any of these cards.
public struct ContactRef: Codable, Hashable, Sendable {
    /// Underlying card ids, sorted.
    public var cardIDs: [String]
    /// Display title when the reference was made.
    public var title: String

    /// Creates a reference.
    public init(cardIDs: [String], title: String) {
        self.cardIDs = cardIDs.sorted()
        self.title = title
    }

    /// `true` when `contact` still has one of these cards.
    public func matches(_ contact: AppleContact) -> Bool {
        contact.cards.contains { cardIDs.contains($0.id) }
    }

    enum CodingKeys: String, CodingKey {
        case cardIDs = "card_ids"
        case title
    }
}

/// One user intent from the decision log (architecture §4): append-only,
/// one writer per device, read as the union of every device's log.
///
/// Each line of `.c2mdsync/devices/<device-id>/decisions.jsonl` is one
/// `Decision` as JSON. Unknown kinds (from a newer version) are ignored.
public struct Decision: Codable, Hashable, Sendable {
    /// What was decided.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// `contacts` are different people (pairwise); with `path`: the one
        /// contact is not the person in that note.
        case distinctPeople = "distinct-people"
        /// Sync only `contacts[0]`; `contacts[1...]` are excluded.
        case syncOnly = "sync-only"
        /// The markdown-only note at `path` (or with `sync_id`) is never matched.
        case ignoreCandidate = "ignore-candidate"
        /// Bind the note at `path` to `contacts[0]`.
        case adopt
        /// Of the notes sharing `sync_id`, the one at `path` keeps it.
        case duplicateIDKeep = "dup-id-keep"
        /// Resolve the field conflict `item` of record `sync_id` with `choice`
        /// (`apple`, `markdown`, `both`), only while both side hashes match.
        case resolveConflict = "resolve-conflict"
        /// Record `sync_id` was deleted in Contacts: `choice` `trash` (move
        /// the note at `path` to the Trash) or `keep` (detach the note).
        case appleDelete = "apple-delete"
        /// The note of record `sync_id` was deleted: `choice` `restore`,
        /// `unlink` (keep `contacts[0]`, stop syncing it) or `delete-contact`.
        case markdownDelete = "markdown-delete"
        /// Create an Apple contact from the markdown-only note at `path`.
        case createContact = "create-contact"
        /// `contacts[0]` carries several stamps (cards stamped separately,
        /// then linked): the note at `path` keeps its record; the other
        /// notes are detached and the other stamps removed.
        case mergeKeep = "merge-keep"
        /// The note (or vault file) at `path` has iCloud conflict versions:
        /// keep the current contents (`choice` `keep-current`) or the version
        /// whose sha256 is `version` (`keep-other:N`), only while the current
        /// contents still hash to `markdown_hash` (M6, architecture §11).
        case fileVersionKeep = "file-version-keep"
        /// A duplicate cluster partitioned by the user: each list of
        /// `groups` is one person (one note), different groups are different
        /// people, `excluded` members are not synced. `contacts` lists every
        /// member. Supersedes `distinct-people` / `sync-only` for its members.
        case clusterResolve = "cluster-resolve"
        /// The Contacts account whose container id is `path` is not visible:
        /// `choice` `wait` (keep its cards as last seen) or `forget` (remove
        /// it deliberately: its contacts are queued as deleted and values
        /// only its cards held leave the notes). Applies only to the absence
        /// that began before the decision (architecture §9).
        case accountMissing = "account-missing"
    }

    public var id: UUID
    /// Raw kind (see `Kind`); kept as text so unknown kinds round-trip.
    public var kindName: String
    public var createdAt: Date
    public var deviceID: String
    public var deviceName: String
    public var contacts: [ContactRef]
    public var path: String?
    public var syncID: UUID?
    /// The review item this answers, for display.
    public var itemID: String?
    /// The option chosen (conflicts, deletes).
    public var choice: String?
    /// Conflict side hashes the choice was made against.
    public var appleHash: String?
    public var markdownHash: String?
    /// The chosen iCloud conflict version (its sha256), for `file-version-keep`.
    public var version: String?
    /// `cluster-resolve`: each list is one person.
    public var groups: [[ContactRef]]?
    /// `cluster-resolve`: members left out of sync.
    public var excluded: [ContactRef]?

    /// Creates a decision.
    public init(
        id: UUID = UUID(), kind: Kind, createdAt: Date, device: DeviceIdentity, contacts: [ContactRef] = [],
        path: String? = nil, syncID: UUID? = nil, itemID: String? = nil, choice: String? = nil,
        appleHash: String? = nil, markdownHash: String? = nil, version: String? = nil,
        groups: [[ContactRef]]? = nil, excluded: [ContactRef]? = nil
    ) {
        self.groups = groups
        self.excluded = excluded
        self.version = version
        self.choice = choice
        self.appleHash = appleHash
        self.markdownHash = markdownHash
        self.id = id
        self.kindName = kind.rawValue
        self.createdAt = createdAt
        self.deviceID = device.id
        self.deviceName = device.name
        self.contacts = contacts
        self.path = path
        self.syncID = syncID
        self.itemID = itemID
    }

    /// The kind, or `nil` when written by a newer version.
    public var kind: Kind? { Kind(rawValue: kindName) }

    enum CodingKeys: String, CodingKey {
        case id
        case kindName = "kind"
        case createdAt = "at"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case contacts
        case path
        case syncID = "sync_id"
        case itemID = "item"
        case choice
        case appleHash = "apple_hash"
        case markdownHash = "markdown_hash"
        case version
        case groups
        case excluded
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kindName = try container.decode(String.self, forKey: .kindName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        contacts = try container.decodeIfPresent([ContactRef].self, forKey: .contacts) ?? []
        path = try container.decodeIfPresent(String.self, forKey: .path)
        syncID = try container.decodeIfPresent(UUID.self, forKey: .syncID)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        choice = try container.decodeIfPresent(String.self, forKey: .choice)
        appleHash = try container.decodeIfPresent(String.self, forKey: .appleHash)
        markdownHash = try container.decodeIfPresent(String.self, forKey: .markdownHash)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        groups = try container.decodeIfPresent([[ContactRef]].self, forKey: .groups)
        excluded = try container.decodeIfPresent([ContactRef].self, forKey: .excluded)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kindName, forKey: .kindName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceName, forKey: .deviceName)
        if !contacts.isEmpty { try container.encode(contacts, forKey: .contacts) }
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(syncID, forKey: .syncID)
        try container.encodeIfPresent(itemID, forKey: .itemID)
        try container.encodeIfPresent(choice, forKey: .choice)
        try container.encodeIfPresent(appleHash, forKey: .appleHash)
        try container.encodeIfPresent(markdownHash, forKey: .markdownHash)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(groups, forKey: .groups)
        try container.encodeIfPresent(excluded, forKey: .excluded)
    }
}

/// Decisions indexed for the planner.
public struct DecisionSet: Sendable {
    /// All decisions in effect, oldest first.
    public let all: [Decision]

    /// Indexes `decisions` (oldest first). Of several decisions answering
    /// the same review item (`itemID`), only the latest is in effect: a
    /// re-decided item, or one decided differently on two devices (latest
    /// wins, `DecisionLog.read` warns), never mixes both answers.
    public init(_ decisions: [Decision] = []) {
        let known = decisions.filter { $0.kind != nil }
        var latestForItem: [String: UUID] = [:]
        for decision in known { if let item = decision.itemID { latestForItem[item] = decision.id } }
        self.all = known.filter { decision in decision.itemID.map { latestForItem[$0] == decision.id } ?? true }
    }

    /// The latest file-version decision for `path`.
    public func fileVersionChoice(forPath path: String) -> Decision? {
        all.last { $0.kind == .fileVersionKeep && $0.path == path }
    }

    /// `first` and `second` were declared different people: by a
    /// `distinct-people` decision, or by the latest cluster resolution
    /// naming both, which put them in different groups. A later resolution
    /// putting them in one group lifts an older separation.
    public func areDistinct(_ first: AppleContact, _ second: AppleContact) -> Bool {
        var distinct = false
        for decision in all {
            switch decision.kind {
            case .distinctPeople where decision.path == nil:
                let matchesA = decision.contacts.firstIndex { $0.matches(first) }
                let matchesB = decision.contacts.firstIndex { $0.matches(second) }
                if let matchesA, let matchesB, matchesA != matchesB { distinct = true }
            case .clusterResolve:
                guard let groupA = decision.groupIndex(of: first), let groupB = decision.groupIndex(of: second) else {
                    continue
                }
                distinct = groupA != groupB
            default:
                continue
            }
        }
        return distinct
    }

    /// The contact's place in the latest cluster decision naming it
    /// (`cluster-resolve`, `distinct-people` without a path, `sync-only`).
    ///
    /// A contact holding a card the user kept is that person even when an
    /// excluded card was linked into it later: groups win over `excluded`.
    public func clusterRole(of contact: AppleContact) -> ClusterRole? {
        for decision in all.reversed() where decision.isClusterAnswer {
            guard let reference = decision.referenceIndex(of: contact) else { continue }
            switch decision.kind {
            case .clusterResolve:
                let group = decision.groupIndex(of: contact)
                return ClusterRole(decision: decision.id, group: group, kind: .resolve, reference: reference)
            case .syncOnly:
                return ClusterRole(
                    decision: decision.id, group: reference == 0 ? 0 : nil, kind: .syncOnly, reference: reference)
            default:
                return ClusterRole(decision: decision.id, group: reference, kind: .distinct, reference: reference)
            }
        }
        return nil
    }

    /// The note at `path` (markdown-only) or with `syncID` is ignored as a candidate.
    public func isIgnored(path: String, syncID: UUID?) -> Bool {
        all.contains { decision in
            guard decision.kind == .ignoreCandidate else { return false }
            if let id = decision.syncID, id == syncID { return true }
            return decision.path == path
        }
    }

    /// The contact the note at `path` should be adopted by (latest wins).
    public func adoption(ofNoteAt path: String) -> ContactRef? {
        all.last { $0.kind == .adopt && $0.path == path }?.contacts.first
    }

    /// The path that keeps `syncID` among copies (latest wins).
    public func keptPath(forDuplicate syncID: UUID) -> String? {
        all.last { $0.kind == .duplicateIDKeep && $0.syncID == syncID }?.path
    }

    /// The latest resolution of conflict `id`: its choice and side hashes.
    public func resolution(ofConflict id: String) -> ConflictDecision? {
        guard let decision = all.last(where: { $0.kind == .resolveConflict && $0.itemID == id }),
            let choice = decision.choice
        else { return nil }
        return ConflictDecision(choice: choice, appleHash: decision.appleHash, markdownHash: decision.markdownHash)
    }

    /// The latest choice for record `id` deleted in Contacts.
    public func appleDeleteChoice(for id: UUID) -> String? {
        all.last { $0.kind == .appleDelete && $0.syncID == id }?.choice
    }

    /// The latest choice for record `id` whose note was deleted.
    public func markdownDeleteChoice(for id: UUID) -> String? {
        all.last { $0.kind == .markdownDelete && $0.syncID == id }?.choice
    }

    /// `contact` was unlinked after its note was deleted: never synced again.
    public func isUnlinked(_ contact: AppleContact) -> Bool {
        all.contains { decision in
            decision.kind == .markdownDelete && decision.choice == "unlink"
                && decision.contacts.contains { $0.matches(contact) }
        }
    }

    /// The note that survives for `contact` when it carries several stamps (latest wins).
    public func mergeKeptPath(for contact: AppleContact) -> String? {
        all.last { $0.kind == .mergeKeep && $0.contacts.contains { $0.matches(contact) } }?.path
    }

    /// The user asked to create an Apple contact from the note at `path`.
    public func wantsContact(forNoteAt path: String) -> Bool {
        all.contains { $0.kind == .createContact && $0.path == path }
    }

    /// `contact` was declared not to be the person in the note at `path`.
    public func isDistinct(_ contact: AppleContact, fromNoteAt path: String) -> Bool {
        all.contains { decision in
            decision.kind == .distinctPeople && decision.path == path
                && decision.contacts.contains { $0.matches(contact) }
        }
    }
}

/// Where a contact stands after a cluster decision.
public struct ClusterRole: Hashable, Sendable {
    /// The decision this comes from.
    public var decision: UUID
    /// Group number within that decision (`nil`: not synced).
    public var group: Int?
    /// Which kind of decision.
    public var kind: Source
    /// Which of the decision's references the contact matched (its
    /// `contacts`; for `cluster-resolve`, its groups then `excluded`).
    /// Several contacts matching one reference are the halves of a contact
    /// unlinked since the decision, which nobody answered for separately.
    public var reference: Int

    /// Decision kinds that settle cluster members.
    public enum Source: Hashable, Sendable {
        case resolve
        case distinct
        case syncOnly
    }

    /// Left out of sync.
    public var isExcluded: Bool { group == nil }

    /// Members with equal keys are one person.
    public var groupKey: String? { group.map { "\(decision.uuidString)#\($0)" } }
}

extension Decision {
    /// The group (0-based) of a `cluster-resolve` decision holding `contact`.
    func groupIndex(of contact: AppleContact) -> Int? {
        groups?.firstIndex { group in group.contains { $0.matches(contact) } }
    }

    /// An answer about duplicate cluster members (`cluster-resolve`,
    /// `distinct-people` without a path, `sync-only`).
    var isClusterAnswer: Bool {
        switch kind {
        case .clusterResolve, .syncOnly: true
        case .distinctPeople: path == nil
        default: false
        }
    }

    /// The first reference matching `contact` (`ClusterRole.reference`).
    func referenceIndex(of contact: AppleContact) -> Int? {
        let references = kind == .clusterResolve ? (groups ?? []).flatMap { $0 } + (excluded ?? []) : contacts
        return references.firstIndex { $0.matches(contact) }
    }
}

/// A recorded conflict resolution and the side hashes it was made against.
public struct ConflictDecision: Hashable, Sendable {
    public var choice: String
    public var appleHash: String?
    public var markdownHash: String?

    /// Creates a resolution.
    public init(choice: String, appleHash: String?, markdownHash: String?) {
        self.choice = choice
        self.appleHash = appleHash
        self.markdownHash = markdownHash
    }
}
