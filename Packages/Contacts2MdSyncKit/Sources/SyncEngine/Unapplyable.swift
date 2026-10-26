public import Foundation

/// A write a card did not keep (architecture §9 "Unapplyable fields"): the
/// server rejected it or rewrote it outside its comparison key. It is not
/// retried while the markdown side still asks for the same thing, which is
/// the main Apple-side anti-ping-pong guard.
public struct UnapplyableEntry: Codable, Hashable, Sendable {
    public var recordID: UUID
    /// The card (`*` for the contact as a whole, e.g. a group it cannot join).
    public var cardID: String
    /// Scalar field (`job_title`) or list element (`phones|+14155550100`, `tags|family`).
    public var field: String
    /// What we tried: a scalar's key (`∅` = clear), or `+` add, `-` remove,
    /// `~<key>` replace, `@<label>` relabel.
    public var attempted: String
    /// What the card showed afterwards (scalar key, `present`, `absent`, …).
    public var observed: String

    /// Creates an entry.
    public init(recordID: UUID, cardID: String, field: String, attempted: String, observed: String) {
        self.recordID = recordID
        self.cardID = cardID
        self.field = field
        self.attempted = attempted
        self.observed = observed
    }

    /// Identity within a record (one entry per card and field).
    var slot: String { "\(cardID)\u{1F}\(field)" }
}

/// Unapplyable entries indexed for planning; remembers which ones were
/// still relevant this run (the rest expire: their value changed).
struct UnapplyableIndex: Sendable {
    private var byRecord: [UUID: [UnapplyableEntry]] = [:]
    private(set) var used = Set<UnapplyableEntry>()

    init(_ entries: [UnapplyableEntry] = []) {
        for entry in entries { byRecord[entry.recordID, default: []].append(entry) }
    }

    /// `true` (and marks it used) when writing `attempted` to `field` of `card` already failed.
    mutating func blocks(record: UUID, card: String, field: String, attempted: String) -> Bool {
        guard
            let entry = byRecord[record]?.first(where: {
                ($0.cardID == card || $0.cardID == "*") && $0.field == field && $0.attempted == attempted
            })
        else { return false }
        used.insert(entry)
        return true
    }

    /// Scalar aliases for the merge: Apple's observed value stands for what we wrote.
    mutating func aliases(record: UUID) -> [String: ScalarAlias] {
        var aliases: [String: ScalarAlias] = [:]
        for entry in byRecord[record] ?? [] where ScalarField(rawValue: entry.field) != nil {
            let decode = { (text: String) in text == "∅" ? nil : text }
            aliases[entry.field] = ScalarAlias(attempted: decode(entry.attempted), observed: decode(entry.observed))
        }
        return aliases
    }

    /// List writes the record's cards refused: `field|key` → attempted values.
    func listRefusals(record: UUID) -> [String: Set<String>] {
        var refusals: [String: Set<String>] = [:]
        let elements = (byRecord[record] ?? []).filter {
            ScalarField(rawValue: $0.field) == nil && $0.field.contains("|")
        }
        for entry in elements {
            refusals[entry.field, default: []].insert(entry.attempted)
        }
        return refusals
    }

    /// Marks the list refusals of `fields` (`field|key`) used (they decided a merge slot).
    mutating func markListRefusalsUsed(record: UUID, fields: Set<String>) {
        for entry in byRecord[record] ?? [] where fields.contains(entry.field) { used.insert(entry) }
    }

    /// Marks the alias of `field` used (it applied in the merge).
    mutating func markAliasUsed(record: UUID, field: String) {
        for entry in byRecord[record] ?? [] where entry.field == field { used.insert(entry) }
    }
}
