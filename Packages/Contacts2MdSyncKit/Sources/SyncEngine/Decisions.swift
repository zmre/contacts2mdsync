public import ContactModel
public import Foundation
public import VaultIndex

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

    /// Creates a decision.
    public init(
        id: UUID = UUID(), kind: Kind, createdAt: Date, device: DeviceIdentity, contacts: [ContactRef] = [],
        path: String? = nil, syncID: UUID? = nil, itemID: String? = nil, choice: String? = nil,
        appleHash: String? = nil, markdownHash: String? = nil
    ) {
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
    }
}

/// Reading and appending `decisions.jsonl` files in the vault.
public enum DecisionLog {
    /// Folder holding one subfolder per device.
    public static let devicesFolder = ".c2mdsync/devices"

    /// The log of `deviceID`.
    public static func path(deviceID: String) -> String { "\(devicesFolder)/\(deviceID)/decisions.jsonl" }

    /// Errors writing the log.
    public enum LogError: Error, Hashable, Sendable, CustomStringConvertible {
        case invalidDeviceID(String)

        public var description: String {
            switch self {
            case .invalidDeviceID(let id): "invalid device id for the decision log: \(id)"
            }
        }
    }

    /// The union of every device's decisions, oldest first, plus lines that
    /// could not be read (`path:line: message`). Never throws for bad lines.
    public static func readAll(_ fs: any VaultFS) throws -> (decisions: [Decision], problems: [String]) {
        var decisions: [Decision] = []
        var problems: [String] = []
        var seen = Set<UUID>()
        for device in try fs.list(devicesFolder) where !device.hasPrefix(".") {
            let logPath = "\(devicesFolder)/\(device)/decisions.jsonl"
            guard fs.exists(logPath) else { continue }
            let (data, _) = try fs.read(logPath)
            let text = String(bytes: data, encoding: .utf8) ?? ""
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                do {
                    let decision = try decoder.decode(Decision.self, from: Data(trimmed.utf8))
                    if seen.insert(decision.id).inserted { decisions.append(decision) }
                } catch {
                    problems.append("\(logPath):\(number + 1): unreadable decision")
                }
            }
        }
        decisions.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return (decisions, problems)
    }

    /// Appends `decisions` to this device's log (compare-and-swap on the
    /// current bytes, so a concurrent writer on this device is not lost).
    public static func append(_ decisions: [Decision], deviceID: String, fs: any VaultFS) throws {
        guard !decisions.isEmpty else { return }
        guard !deviceID.isEmpty, !deviceID.contains("/"), !deviceID.hasPrefix(".") else {
            throw LogError.invalidDeviceID(deviceID)
        }
        let logPath = path(deviceID: deviceID)
        var expectation = WriteExpectation.absent
        var data = Data()
        if fs.exists(logPath) {
            let (current, stamp) = try fs.read(logPath)
            data = current
            expectation = .unchanged(stamp)
            if let last = data.last, last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
        }
        for decision in decisions {
            data.append(try encoder.encode(decision))
            data.append(UInt8(ascii: "\n"))
        }
        _ = try fs.write(data, to: logPath, expecting: expectation)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Decisions indexed for the planner.
public struct DecisionSet: Sendable {
    /// All decisions, oldest first.
    public let all: [Decision]

    /// Indexes `decisions` (oldest first; later decisions win where they conflict).
    public init(_ decisions: [Decision] = []) {
        self.all = decisions.filter { $0.kind != nil }
    }

    /// `first` and `second` were declared different people.
    public func areDistinct(_ first: AppleContact, _ second: AppleContact) -> Bool {
        all.contains { decision in
            guard decision.kind == .distinctPeople, decision.path == nil else { return false }
            let matchesA = decision.contacts.firstIndex { $0.matches(first) }
            let matchesB = decision.contacts.firstIndex { $0.matches(second) }
            guard let matchesA, let matchesB else { return false }
            return matchesA != matchesB
        }
    }

    /// `contact` was declared not to be the person in the note at `path`.
    public func isDistinct(_ contact: AppleContact, fromNoteAt path: String) -> Bool {
        all.contains { decision in
            decision.kind == .distinctPeople && decision.path == path
                && decision.contacts.contains { $0.matches(contact) }
        }
    }

    /// `.keep` / `.exclude` from the latest sync-only decision naming `contact`.
    public func syncOnlyRole(of contact: AppleContact) -> SyncOnlyRole? {
        for decision in all.reversed() where decision.kind == .syncOnly {
            guard let index = decision.contacts.firstIndex(where: { $0.matches(contact) }) else { continue }
            return index == 0 ? .keep : .exclude
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

    /// Role of a contact in a sync-only decision.
    public enum SyncOnlyRole: Hashable, Sendable {
        case keep
        case exclude
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
