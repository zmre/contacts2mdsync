public import ContactModel
public import Foundation
internal import VaultIndex

/// `limits:` in `.c2mdsync/config.yaml` (architecture §9).
public struct SyncLimits: Hashable, Sendable {
    /// More Apple changes than this in one run need approval (blast radius).
    public var maxAppleChanges: Int
    /// More records than this vanishing from one side trips the breaker.
    public var massVanishCount: Int
    /// …or more than this percentage of the records (with at least
    /// `massVanishMinimum` records), so small vaults are not tripped by one delete.
    public var massVanishPercent: Double
    /// Fewest vanished records for the percentage rule.
    public static let massVanishMinimum = 3

    /// Creates limits (architecture defaults: 25, 10, 5 %).
    public init(maxAppleChanges: Int = 25, massVanishCount: Int = 10, massVanishPercent: Double = 5) {
        self.maxAppleChanges = maxAppleChanges
        self.massVanishCount = massVanishCount
        self.massVanishPercent = massVanishPercent
    }

    init(_ fields: [YAMLField]) {
        self.init()
        let value = { (key: String) in fields.first { $0.key == key }?.value.scalarText }
        if let text = value("max_apple_changes_without_approval"), let number = Int(text) { maxAppleChanges = number }
        if let text = value("mass_vanish_count"), let number = Int(text) { massVanishCount = number }
        if let text = value("mass_vanish_percent"), let number = Double(text) { massVanishPercent = number }
    }

    /// Whether `vanished` of `total` records trips the mass-vanish breaker.
    public func tripsMassVanish(vanished: Int, total: Int) -> Bool {
        guard vanished > 0 else { return false }
        if vanished > massVanishCount { return true }
        guard vanished >= Self.massVanishMinimum, total > 0 else { return false }
        return Double(vanished) * 100 > massVanishPercent * Double(total)
    }
}

/// `scope:` and `on_leave_scope` (architecture §12, markdown-schema §8).
///
/// Precedence: a contact rule beats a group rule; exclude beats include.
/// Leaving scope never deletes anything: with `on_leave_scope: detach` the
/// note gets `c2mdsync.status: detached` and is no longer synced.
public struct SyncScope: Hashable, Sendable {
    /// Account kinds a contact must have a card in (empty: any).
    public var containers: [AccountKind] = []
    /// Group names; when non-empty, only members of one of them are in scope.
    public var includeGroups: [String] = []
    public var excludeGroups: [String] = []
    /// Record ids always in scope (beats group and container rules).
    public var includeContacts: Set<UUID> = []
    /// Record ids never in scope.
    public var excludeContacts: Set<UUID> = []
    /// Note path globs; when non-empty (and not just `**`), notes elsewhere are out of scope.
    public var includePaths: [String] = []
    /// A tag every synced note must carry.
    public var requireTag: String?
    /// What happens to a synced note that leaves scope (only `detach` exists).
    public var onLeaveScope = "detach"

    /// Everything in scope.
    public init() {}

    init(_ fields: [YAMLField]) {
        func list(_ key: String, in fields: [YAMLField]) -> [String] {
            guard case .sequence(let items)? = fields.first(where: { $0.key == key })?.value else { return [] }
            return items.compactMap(\.scalarText).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                !$0.isEmpty
            }
        }
        containers = list("containers", in: fields).compactMap { AccountKind(rawValue: $0.lowercased()) }
        includeGroups = list("include_groups", in: fields)
        excludeGroups = list("exclude_groups", in: fields)
        includeContacts = Set(list("include_contacts", in: fields).compactMap(UUID.init(uuidString:)))
        excludeContacts = Set(list("exclude_contacts", in: fields).compactMap(UUID.init(uuidString:)))
        if case .mapping(let markdown)? = fields.first(where: { $0.key == "markdown" })?.value {
            includePaths = list("include_paths", in: markdown).filter { $0 != "**" }
        }
        let tag = fields.first { $0.key == "require_tag" }?.value.scalarText
        requireTag = tag.flatMap { ["", "null", "~"].contains($0) ? nil : ComparisonKeys.tag($0) }
    }

    /// `true` when nothing is restricted.
    public var isUnrestricted: Bool {
        containers.isEmpty && includeGroups.isEmpty && excludeGroups.isEmpty && includeContacts.isEmpty
            && excludeContacts.isEmpty && includePaths.isEmpty && requireTag == nil
    }

    /// Whether a record is in scope.
    ///
    /// - Parameters:
    ///   - id: the record id, when it has one.
    ///   - contact: the Apple contact, when bound.
    ///   - groupNames: names of the Apple groups the contact belongs to.
    ///   - path: the note path, when there is a note.
    ///   - tags: the note's tags (or, for a contact without a note, its managed tags).
    public func contains(
        id: UUID?, contact: AppleContact?, groupNames: [String], path: String?, tags: [String]
    ) -> Bool {
        if let id, excludeContacts.contains(id) { return false }
        if let path, !includePaths.isEmpty, !includePaths.contains(where: { PathGlob.matches($0, path) }) {
            return false
        }
        if let id, includeContacts.contains(id) { return true }
        if groupNames.contains(where: excludeGroups.contains) { return false }
        if !includeGroups.isEmpty, !groupNames.contains(where: includeGroups.contains) { return false }
        if !containers.isEmpty, let contact, !contact.cards.contains(where: { containers.contains($0.accountKind) }) {
            return false
        }
        if let requireTag, !tags.map(ComparisonKeys.tag).contains(requireTag) { return false }
        return true
    }
}
