internal import ContactModel
internal import Foundation

/// What saving a card does to its values in the fake store (the real
/// adapter does the same to a `CNMutableContact`), and the unified view
/// Contacts derives from linked cards.
enum FakeCardValues {
    /// Applies one edit to canonical values (what the real adapter does to a `CNMutableContact`).
    static func apply(_ edit: CardEdit, to values: inout CanonicalContact, image: inout Data?, normalizePhones: Bool) {
        switch edit {
        case .scalar(let field, let value):
            field.set(value, in: &values)
        case .birthday(let date):
            values.dates.removeAll { $0.label == "birthday" }
            if let date { values.dates.insert(Labeled("birthday", date), at: 0) }
        case .note(let text):
            values.body = text
        case .image(let data):
            image = data
        case .list(let field, let elements):
            setList(field, elements, in: &values, normalizePhones: normalizePhones)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func setList(
        _ field: AppleListField, _ elements: [AppleListElement], in values: inout CanonicalContact,
        normalizePhones: Bool
    ) {
        func texts() -> [Labeled<String>] {
            elements.compactMap { element in
                guard case .text(let text) = element.value else { return nil }
                return Labeled(element.label, text)
            }
        }
        switch field {
        case .emails: values.emails = texts()
        case .phones:
            values.phones = texts().map { normalizePhones ? Labeled($0.label, normalizedPhone($0.value)) : $0 }
        case .urls: values.urls = texts()
        case .social:
            values.social = elements.compactMap {
                if case .social(let handle) = $0.value { return Labeled($0.label, handle) }
                return nil
            }
        case .im:
            values.im = elements.compactMap {
                if case .im(let handle) = $0.value { return Labeled($0.label, handle) }
                return nil
            }
        case .addresses:
            values.addresses = elements.compactMap {
                if case .address(let address) = $0.value { return Labeled($0.label, address) }
                return nil
            }
        case .dates:
            let birthday = values.dates.filter { $0.label == "birthday" }
            values.dates =
                birthday
                + elements.compactMap {
                    if case .date(let date) = $0.value { return Labeled($0.label ?? "other", date) }
                    return nil
                }
        case .relations:
            values.relationships = elements.compactMap {
                guard case .relation(let name, let type, let label) = $0.value else { return nil }
                return RelationshipRef(type: type, label: label, target: .name(name))
            }
        }
    }

    /// US numbers come back as `(415) 555-0100`, as iCloud/Google may rewrite them.
    static func normalizedPhone(_ text: String) -> String {
        var digits = text.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
        guard digits.count == 10, !text.contains("x"), !text.contains(";") else { return text }
        let chars = Array(digits)
        return "(\(String(chars[0..<3]))) \(String(chars[3..<6]))-\(String(chars[6..<10]))"
    }

    /// Gives every card its own values (from the unified view where unknown).
    static func materialize(_ contact: inout AppleContact) {
        for index in contact.cards.indices where contact.cards[index].values == nil {
            contact.cards[index].values = contact.contact
        }
    }

    /// The unified view after a write: union of multi-valued fields, single
    /// values from the most recently saved card first.
    static func recomputeUnified(_ contact: inout AppleContact, lastSaved: [String: Int]) {
        let cards = contact.cards.compactMap(\.values)
        guard !cards.isEmpty else { return }
        guard cards.count > 1 else {
            contact.contact = cards[0]
            return
        }
        let bySave = contact.cards.sorted { (lastSaved[$0.id] ?? 0) > (lastSaved[$1.id] ?? 0) }.compactMap(\.values)
        var unified = bySave[0]
        for field in AppleScalarField.allCases {
            field.set(bySave.lazy.compactMap { field.value(in: $0) }.first, in: &unified)
        }
        func union<Value>(_ list: (CanonicalContact) -> [Labeled<Value>]) -> [Labeled<Value>] {
            var seen = Set<Labeled<Value>>()
            return cards.flatMap(list).filter { seen.insert($0).inserted }
        }
        unified.emails = union(\.emails)
        unified.phones = union(\.phones)
        unified.urls = union(\.urls)
        unified.social = union(\.social)
        unified.im = union(\.im)
        unified.addresses = union(\.addresses)
        unified.dates = union(\.dates)
        var seenRelations = Set<RelationshipRef>()
        unified.relationships = cards.flatMap(\.relationships).filter { seenRelations.insert($0).inserted }
        unified.body = bySave.lazy.compactMap(\.body).first
        contact.contact = unified
    }
}
