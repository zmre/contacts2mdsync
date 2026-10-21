/// Computes a unified contact's Apple-side values from its underlying cards
/// (architecture §6, "Stamping and write targets").
///
/// The unified view Contacts returns is a blend whose single-valued fields
/// follow the most recently saved card, so a Google re-save can flip them.
/// The engine instead uses a deterministic precedence:
///
/// - **Single-valued fields**: first non-empty value in card precedence order:
///   stamped card, iCloud card, other writable cards, read-only cards; ties
///   broken by card id.
/// - **Multi-valued fields**: union over cards in that order, de-duplicated by
///   comparison key (first occurrence wins, keeping its label and display).
///
/// Cards without `values` (the store did not read them) make the whole
/// contact fall back to the unified view.
extension AppleContact {
    /// Cards sorted by write precedence.
    public var cardsByPrecedence: [AppleCard] {
        func rank(_ card: AppleCard) -> Int {
            if card.stampID != nil { return 0 }
            switch card.accountKind {
            case .iCloud: return 1
            case .local, .cardDAV, .google, .exchange: return 2
            case .unknown: return 3
            }
        }
        return cards.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
    }

    /// The Apple-side contact: card values merged by precedence, or the
    /// unified view when any card's values are unknown or there is one card.
    public func cardMergedContact(keyer: any PhoneKeyer) -> CanonicalContact {
        let ordered = cardsByPrecedence
        let values = ordered.compactMap(\.values)
        guard values.count == cards.count, values.count > 1 else { return contact }
        return CardPrecedence.merge(values, keyer: keyer, unified: contact)
    }
}

/// The merge behind `AppleContact.cardMergedContact`.
enum CardPrecedence {
    static func merge(
        _ cards: [CanonicalContact], keyer: any PhoneKeyer, unified: CanonicalContact
    ) -> CanonicalContact {
        func first<T>(_ value: (CanonicalContact) -> T?) -> T? { cards.lazy.compactMap(value).first }
        var result = CanonicalContact(kind: unified.kind, title: "")
        result.name = PersonName(
            prefix: first { $0.name.prefix }, given: first { $0.name.given }, middle: first { $0.name.middle },
            family: first { $0.name.family }, suffix: first { $0.name.suffix })
        result.aliases = [
            first { $0.aliases.first { $0.label == Alias.nicknameLabel } },
            first { $0.aliases.first { $0.label == Alias.maidenNameLabel } },
        ].compactMap { $0 }
        result.company = first(\.company)
        result.department = first(\.department)
        result.jobTitle = first(\.jobTitle)
        result.apple = AppleExtras(
            phoneticGiven: first(\.apple.phoneticGiven), phoneticMiddle: first(\.apple.phoneticMiddle),
            phoneticFamily: first(\.apple.phoneticFamily), phoneticOrganization: first(\.apple.phoneticOrganization))
        result.emails = union(cards.map(\.emails)) { ComparisonKeys.email($0.value) }
        result.phones = union(cards.map(\.phones)) { ComparisonKeys.phone($0.value, keyer: keyer) }
        result.urls = union(cards.map(\.urls)) { ComparisonKeys.url($0.value) }
        result.social = union(cards.map(\.social)) { "\($0.label ?? "")|\($0.value.value.lowercased())" }
        result.im = union(cards.map(\.im)) { "\($0.label ?? "")|\($0.value.value.lowercased())" }
        result.addresses = union(cards.map(\.addresses)) { ComparisonKeys.address($0.value) }
        let birthday = first { $0.dates.first { $0.label == "birthday" } }
        let otherDates = union(cards.map { $0.dates.filter { $0.label != "birthday" } }) {
            "\($0.label ?? "")|\($0.value.iso)"
        }
        result.dates = (birthday.map { [$0] } ?? []) + otherDates
        result.relationships = unionRelations(cards.map(\.relationships))
        result.body = first(\.body)
        return result
    }

    private static func union<Value>(
        _ lists: [[Labeled<Value>]], key: (Labeled<Value>) -> String
    ) -> [Labeled<Value>] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert(key($0)).inserted }
    }

    private static func unionRelations(_ lists: [[RelationshipRef]]) -> [RelationshipRef] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { ref in
            seen.insert("\(ref.type)|\(ComparisonKeys.name(ref.target?.displayName ?? ""))").inserted
        }
    }
}
