internal import ContactModel
internal import Foundation

/// Frontmatter → `CanonicalContact`, accepting every shape mbr accepts
/// (`contact.rs` `labeled_values`): a map (`label: value`), a list of
/// single-key maps and/or bare values, a single scalar, and the tolerated
/// `{label: …, value: …}` (or `{label, name}`) object.
enum ContactDecoding {
    static let addressFields: Set<String> = ["street", "city", "region", "postcode", "country", "country_code"]

    /// The contact, or `nil` when `type` is not exactly `person`/`organization`.
    static func contact(from fields: [YAMLField], body: String) -> CanonicalContact? {
        var lookup: [String: YAMLValue] = [:]
        for field in fields where lookup[field.key] == nil { lookup[field.key] = field.value }
        guard let typeText = text(lookup["type"]), let kind = ContactKind(rawValue: typeText) else { return nil }
        let string = { (key: String) in text(lookup[key]) }

        var contact = CanonicalContact(kind: kind, title: string("title") ?? "")
        contact.name = PersonName(
            prefix: string("prefix"),
            given: string("first_name"),
            middle: string("middle_name"),
            family: string("last_name"),
            suffix: string("suffix")
        )
        contact.aliases = labeledValues("aliases", lookup["aliases"]).compactMap { label, value in
            text(value).map { Alias(label: label, name: $0) }
        }
        contact.company = string("company").map(CompanyRef.init(raw:))
        contact.department = string("department")
        contact.jobTitle = string("job_title")
        contact.image = string("image").map(ImageRef.init(path:))
        contact.emails = labeledStrings("emails", lookup)
        contact.phones = labeledStrings("phones", lookup)
        contact.urls = labeledStrings("urls", lookup)
        contact.social = labeledStrings("social", lookup).map { Labeled($0.label, SocialHandle($0.value)) }
        contact.im = labeledStrings("im", lookup).map { Labeled($0.label, IMHandle($0.value)) }
        contact.addresses = labeledValues("addresses", lookup["addresses"]).compactMap(address)
        contact.dates = labeledValues("dates", lookup["dates"]).compactMap { label, value in
            guard let label, let raw = text(value) else { return nil }
            return Labeled(label, PartialDate(parsing: raw))
        }
        contact.relationships = relationships(lookup["relationships"])
        contact.tags = tags(lookup["tags"])
        contact.apple = appleExtras(lookup["apple"])
        contact.sync = syncMetadata(lookup["c2mdsync"])
        contact.body = body.isEmpty ? nil : body
        contact.passthrough = fields.filter { !ManagedKeys.names.contains($0.key) }
        return contact
    }

    /// Trimmed, non-empty text of a scalar (mbr `scalar_text`).
    static func text(_ value: YAMLValue?) -> String? {
        guard case .scalar(let raw, _) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonEmptyLabel(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// mbr `labeled_values`: `(label, value)` pairs in authored order.
    static func labeledValues(_ field: String, _ value: YAMLValue?) -> [(String?, YAMLValue)] {
        switch value {
        case nil, .null?:
            return []
        case .sequence(let items)?:
            return items.compactMap { labeledItem(field, $0) }
        case .mapping(let map)?:
            if let pair = labelValueObject(map) { return [pair] }
            if field == "addresses", isAddressObject(map) { return [(nil, .mapping(map))] }
            return map.map { (nonEmptyLabel($0.key), $0.value) }
        case .some(let scalar):
            return [(nil, scalar)]
        }
    }

    private static func labeledItem(_ field: String, _ item: YAMLValue) -> (String?, YAMLValue)? {
        switch item {
        case .mapping(let map):
            if let pair = labelValueObject(map) { return pair }
            if field == "addresses", isAddressObject(map) {
                let label = text(map.first { $0.key == "label" }?.value)
                return (label, .mapping(map.filter { $0.key != "label" }))
            }
            guard map.count == 1 else { return nil }
            return (nonEmptyLabel(map[0].key), map[0].value)
        case .sequence, .null:
            return nil
        case .scalar:
            return (nil, item)
        }
    }

    private static func labelValueObject(_ map: [YAMLField]) -> (String?, YAMLValue)? {
        guard map.count == 2, let label = map.first(where: { $0.key == "label" }),
            let value = map.first(where: { $0.key == "value" }) ?? map.first(where: { $0.key == "name" })
        else { return nil }
        return (text(label.value), value.value)
    }

    private static func isAddressObject(_ map: [YAMLField]) -> Bool {
        map.contains { addressFields.contains($0.key) }
    }

    private static func labeledStrings(_ key: String, _ lookup: [String: YAMLValue]) -> [Labeled<String>] {
        labeledValues(key, lookup[key]).compactMap { label, value in text(value).map { Labeled(label, $0) } }
    }

    private static func address(_ label: String?, _ value: YAMLValue) -> Labeled<PostalAddress>? {
        switch value {
        case .mapping(let map):
            let field = { (key: String) in text(map.first { $0.key == key }?.value) }
            let address = PostalAddress(
                street: field("street"),
                city: field("city"),
                region: field("region"),
                postcode: field("postcode"),
                country: field("country"),
                countryCode: field("country_code")
            )
            return address.isEmpty ? nil : Labeled(label, address)
        default:
            return text(value).map { Labeled(label, PostalAddress(formatted: $0)) }
        }
    }

    private static func relationships(_ value: YAMLValue?) -> [RelationshipRef] {
        guard case .sequence(let items)? = value else { return [] }
        return items.compactMap { item in
            guard case .mapping(let map) = item else { return nil }
            let field = { (key: String) in text(map.first { $0.key == key }?.value) }
            guard let type = field("type") else { return nil }
            let target: RelationshipTarget? = field("to").map { text in
                Wikilink.inner(of: text).map(RelationshipTarget.wikilink) ?? .name(text)
            }
            let attributes = map.filter { !["type", "to", "label"].contains($0.key) }
            return RelationshipRef(type: type, label: field("label"), target: target, attributes: attributes)
        }
    }

    private static func tags(_ value: YAMLValue?) -> [String] {
        let raw: [String]
        switch value {
        case .sequence(let items)?: raw = items.compactMap { text($0) }
        case .scalar(let text, _)?: raw = text.split(separator: ",").map(String.init)
        default: raw = []
        }
        var seen = Set<String>()
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func appleExtras(_ value: YAMLValue?) -> AppleExtras {
        guard case .mapping(let map)? = value else { return AppleExtras() }
        let known = ["phonetic_first_name", "phonetic_middle_name", "phonetic_last_name", "phonetic_organization_name"]
        let field = { (key: String) in text(map.first { $0.key == key }?.value) }
        return AppleExtras(
            phoneticGiven: field(known[0]),
            phoneticMiddle: field(known[1]),
            phoneticFamily: field(known[2]),
            phoneticOrganization: field(known[3]),
            other: map.filter { !known.contains($0.key) }
        )
    }

    private static func syncMetadata(_ value: YAMLValue?) -> SyncMetadata {
        guard case .mapping(let map)? = value else { return SyncMetadata() }
        let idText = text(map.first { $0.key == "id" }?.value)
        let id = idText.flatMap(UUID.init(uuidString:))
        let status = text(map.first { $0.key == "status" }?.value)
        // An unparseable id is kept verbatim in `other` rather than dropped.
        let other = map.filter { $0.key != "status" && ($0.key != "id" || id == nil) }
        return SyncMetadata(id: id, status: status, other: other)
    }
}
