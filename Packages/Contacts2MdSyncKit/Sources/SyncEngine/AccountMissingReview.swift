public import ContactModel
public import Foundation

/// The review item of an account that is not visible in Contacts
/// (`account-missing:<container id>`): what is kept, and exactly what
/// `forget` would change.
public struct AccountMissingReview: Codable, Hashable, Sendable {
    /// Item ids are `account-missing:<container id>`.
    public static let idPrefix = "account-missing:"

    public var containerID: String
    public var name: String
    public var kind: AccountKind
    /// Cards it held when last available.
    public var cardCount: Int
    public var lastSeen: Date
    /// When this Mac first found it unavailable.
    public var since: Date
    public var reason: UnavailableReason
    /// Notes of contacts that had cards only in this account: `forget`
    /// queues them as deleted in Contacts (the notes stay until you confirm).
    public var frozenTitles: [String]
    /// Contacts that also have cards in other accounts.
    public var linkedCount: Int
    /// Values only this account's cards held: `forget` removes them from these notes.
    public var removals: [AccountRemoval]

    /// Creates the item for `account`.
    public init(account: UnavailableAccount, frozenTitles: [String], linkedCount: Int, removals: [AccountRemoval]) {
        containerID = account.containerID
        name = account.name
        kind = account.kind
        cardCount = account.cardCount
        lastSeen = account.lastSeen
        since = account.since
        reason = account.reason
        self.frozenTitles = frozenTitles
        self.linkedCount = linkedCount
        self.removals = removals
    }

    /// `Google ("Gmail", 1,353 cards)`.
    public var label: String { "\(kind.displayName) (\"\(name)\", \(AccountGuard.count(cardCount)) cards)" }

    public var summary: String {
        "\(label) is not visible in Contacts; its cards are kept as last seen "
            + "(\(AccountGuard.count(frozenTitles.count, "contact")) only there, "
            + "\(AccountGuard.count(linkedCount)) linked with other accounts)"
    }

    /// What `forget` would do, one line each (CLI `review list`, the app's confirmation).
    public var forgetPreview: [String] {
        var lines: [String] = []
        if !frozenTitles.isEmpty {
            let examples = frozenTitles.prefix(5).joined(separator: ", ") + (frozenTitles.count > 5 ? ", …" : "")
            lines.append(
                "queue \(AccountGuard.count(frozenTitles.count, "contact")) only in this account as deleted "
                    + "(notes kept until you confirm each): \(examples)")
        }
        if removals.isEmpty {
            lines.append("no values would leave other notes")
        } else {
            let count = removals.reduce(0) { $0 + $1.values.count }
            lines.append(
                "remove \(AccountGuard.count(count, "value")) only this account held from "
                    + "\(AccountGuard.count(removals.count, "note")):")
            lines += removals.map { "  \($0.path): \($0.values.joined(separator: "; "))" }
        }
        return lines
    }

    enum CodingKeys: String, CodingKey {
        case containerID = "container_id"
        case name, kind
        case cardCount = "card_count"
        case lastSeen = "last_seen"
        case since, reason
        case frozenTitles = "frozen_titles"
        case linkedCount = "linked_count"
        case removals
    }
}
