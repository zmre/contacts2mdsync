internal import ContactModel
internal import Foundation

/// Puts a contact into exactly the form `ContactDecoding` produces, so that
/// `parse(encode(x)) == normalize(x)` holds for every `x`.
enum Normalizer {
    static func normalize(_ input: CanonicalContact) -> CanonicalContact {
        var contact = input
        contact.title = clean(input.title) ?? ""
        contact.name = PersonName(
            prefix: clean(input.name.prefix),
            given: clean(input.name.given),
            middle: clean(input.name.middle),
            family: clean(input.name.family),
            suffix: clean(input.name.suffix)
        )
        contact.aliases = input.aliases.compactMap { alias in
            clean(alias.name).map { Alias(label: cleanLabel(alias.label), name: $0) }
        }
        contact.company = clean(input.company?.raw).map(CompanyRef.init(raw:))
        contact.department = clean(input.department)
        contact.jobTitle = clean(input.jobTitle)
        contact.image = clean(input.image?.path).map(ImageRef.init(path:))
        normalizeMultiValues(input, into: &contact)
        contact.relationships = input.relationships.compactMap(relationship)
        var seenTags = Set<String>()
        contact.tags = input.tags.compactMap { clean($0) }.filter { seenTags.insert($0).inserted }
        contact.apple = apple(input.apple)
        contact.sync = SyncMetadata(
            id: input.sync.id,
            status: clean(input.sync.status),
            other: input.sync.other.filter { $0.key != "status" && ($0.key != "id" || input.sync.id == nil) }
        )
        contact.body = input.body?.isEmpty == false ? input.body : nil
        contact.passthrough = input.passthrough.filter { !ManagedKeys.names.contains($0.key) }
        return contact
    }

    private static func normalizeMultiValues(_ input: CanonicalContact, into contact: inout CanonicalContact) {
        contact.emails = labeled(input.emails)
        contact.phones = labeled(input.phones)
        contact.urls = labeled(input.urls)
        contact.social = labeled(input.social.map { Labeled($0.label, $0.value.value) })
            .map { Labeled($0.label, SocialHandle($0.value)) }
        contact.im = labeled(input.im.map { Labeled($0.label, $0.value.value) })
            .map { Labeled($0.label, IMHandle($0.value)) }
        contact.addresses = input.addresses.compactMap(address)
        contact.dates = input.dates.compactMap { entry in
            guard let label = cleanLabel(entry.label) else { return nil }
            if case .text(let text) = entry.value {
                return clean(text).map { Labeled(label, PartialDate(parsing: $0)) }
            }
            return Labeled(label, entry.value)
        }
    }

    private static func apple(_ extras: AppleExtras) -> AppleExtras {
        let known = ["phonetic_first_name", "phonetic_middle_name", "phonetic_last_name", "phonetic_organization_name"]
        return AppleExtras(
            phoneticGiven: clean(extras.phoneticGiven),
            phoneticMiddle: clean(extras.phoneticMiddle),
            phoneticFamily: clean(extras.phoneticFamily),
            phoneticOrganization: clean(extras.phoneticOrganization),
            other: extras.other.filter { !known.contains($0.key) }
        )
    }

    /// Trimmed text; `nil` when empty. U+FEFF is removed everywhere: libyaml
    /// drops it from scalars, so it could never read back.
    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let withoutBOM = text.contains("\u{FEFF}") ? text.replacingOccurrences(of: "\u{FEFF}", with: "") : text
        let trimmed = withoutBOM.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func labeled(_ values: [Labeled<String>]) -> [Labeled<String>] {
        values.compactMap { entry in clean(entry.value).map { Labeled(cleanLabel(entry.label), $0) } }
    }

    private static func address(_ entry: Labeled<PostalAddress>) -> Labeled<PostalAddress>? {
        let value = entry.value
        let address: PostalAddress
        if let formatted = clean(value.formatted) {
            address = PostalAddress(formatted: formatted)
        } else {
            address = PostalAddress(
                street: clean(value.street),
                city: clean(value.city),
                region: clean(value.region),
                postcode: clean(value.postcode),
                country: clean(value.country),
                countryCode: clean(value.countryCode)
            )
        }
        return address.isEmpty ? nil : Labeled(cleanLabel(entry.label), address)
    }

    private static func relationship(_ ref: RelationshipRef) -> RelationshipRef? {
        guard let type = clean(ref.type) else { return nil }
        let target: RelationshipTarget?
        switch ref.target {
        case .name(let name)?:
            target = clean(name).map { text in Wikilink.inner(of: text).map(RelationshipTarget.wikilink) ?? .name(text)
            }
        case .wikilink(let inner)?:
            target = clean(inner).flatMap { Wikilink.inner(of: "[[\($0)]]") }.map(RelationshipTarget.wikilink)
        case .record(let id)?:
            target = .record(id)
        case nil:
            target = nil
        }
        return RelationshipRef(
            type: type,
            label: clean(ref.label),
            target: target,
            attributes: ref.attributes.filter { !["type", "to", "label"].contains($0.key) }
        )
    }
}
