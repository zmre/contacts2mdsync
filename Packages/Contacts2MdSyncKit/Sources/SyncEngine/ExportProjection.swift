internal import ContactModel
internal import Foundation

/// Builds the markdown contact for one Apple contact (one-way export).
///
/// Rules (documented in markdown-schema §4a "One-way export"):
/// - Apple-backed fields come from Apple. Where a markdown element has the
///   same comparison key as the Apple one, the markdown **display form** is
///   kept (no reformatting churn).
/// - Markdown-only additions survive (M2): a markdown value Apple lacks is
///   kept unless the record's base shows Apple had it at the last export
///   (then Apple deleted it). Without a base (adoption, pre-M2 records)
///   every markdown-only value is kept: adoption never drops user data.
/// - Markdown-owned and markdown-only data is preserved: `title`, plain and
///   other non-Apple aliases, unmanaged tags, `death` dates, mbr-only
///   relationship types and `from:` edges, edge attributes, unknown keys,
///   `apple:`/`c2mdsync:` extras, and the body unless Apple has a note.
struct ExportProjection {
    let keyer: any PhoneKeyer
    let notesAvailable: Bool

    /// Relationship types Apple cannot express (mbr inverses); kept from markdown.
    static let markdownOnlyRelationTypes: Set<String> = ["employer", "employee", "manages", "assists"]
    /// Date labels Apple has no field for; kept from markdown.
    static let markdownOnlyDateLabels: Set<String> = ["death"]

    struct Inputs {
        var apple: AppleContact
        /// Apple-side values (card precedence, architecture §6).
        var values: CanonicalContact
        var existing: CanonicalContact?
        /// Apple-side keys at the last export (`nil`: keep every markdown-only value).
        var base: RecordBase?
        var recordID: UUID
        var title: String
        var company: CompanyRef?
        var relationships: [RelationshipRef]
        var appleTags: [String]
        var managedTagKeys: Set<String>
        var image: ImageRef?
        var managedImagePrefix: String
    }

    func project(_ inputs: Inputs) -> CanonicalContact {
        let source = inputs.values
        let existing = inputs.existing
        var result = existing ?? CanonicalContact(kind: source.kind, title: inputs.title)
        result.kind = source.kind
        result.title = existing.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? inputs.title
        projectScalars(into: &result, inputs)
        projectLists(into: &result, inputs)
        result.image = image(inputs, existing: existing)
        result.relationships = relationships(inputs.relationships, existing: existing?.relationships ?? [])
        result.tags = tags(apple: inputs.appleTags, existing: existing?.tags ?? [], managed: inputs.managedTagKeys)
        result.sync = SyncMetadata(
            id: inputs.recordID, status: existing?.sync.status, other: existing?.sync.other ?? [])
        if notesAvailable, let note = source.body, !ComparisonKeys.body(note).isEmpty,
            ComparisonKeys.body(note) != ComparisonKeys.body(existing?.body)
        {
            result.body = note
        }
        return result
    }

    /// Apple's value, else a markdown value Apple never had (per the base).
    private struct ScalarRule {
        let base: RecordBase?

        func pick<T>(_ field: String, _ apple: T?, _ markdown: T?) -> T? {
            if let apple { return apple }
            guard let markdown, base?.keys(field).isEmpty ?? true else { return nil }
            return markdown
        }
    }

    private func projectScalars(into result: inout CanonicalContact, _ inputs: Inputs) {
        let source = inputs.values
        let existing = inputs.existing
        let rule = ScalarRule(base: inputs.base)
        let mdName = existing?.name ?? PersonName()
        result.name = PersonName(
            prefix: rule.pick("prefix", source.name.prefix, mdName.prefix),
            given: rule.pick("first_name", source.name.given, mdName.given),
            middle: rule.pick("middle_name", source.name.middle, mdName.middle),
            family: rule.pick("last_name", source.name.family, mdName.family),
            suffix: rule.pick("suffix", source.name.suffix, mdName.suffix))
        let appleAliases = [Alias.nicknameLabel, Alias.maidenNameLabel].compactMap { label -> Alias? in
            rule.pick(
                label, source.aliases.first { $0.label == label }, existing?.aliases.first { $0.label == label })
        }
        let appleAliasLabels: Set<String?> = [Alias.nicknameLabel, Alias.maidenNameLabel]
        result.aliases = appleAliases + (existing?.aliases.filter { !appleAliasLabels.contains($0.label) } ?? [])
        result.company = inputs.company ?? rule.pick("company", nil, existing?.company)
        result.department = rule.pick("department", source.department, existing?.department)
        result.jobTitle = rule.pick("job_title", source.jobTitle, existing?.jobTitle)
        let mdApple = existing?.apple ?? AppleExtras()
        result.apple = AppleExtras(
            phoneticGiven: rule.pick("apple.phonetic_first_name", source.apple.phoneticGiven, mdApple.phoneticGiven),
            phoneticMiddle: rule.pick(
                "apple.phonetic_middle_name", source.apple.phoneticMiddle, mdApple.phoneticMiddle),
            phoneticFamily: rule.pick(
                "apple.phonetic_last_name", source.apple.phoneticFamily, mdApple.phoneticFamily),
            phoneticOrganization: rule.pick(
                "apple.phonetic_organization", source.apple.phoneticOrganization, mdApple.phoneticOrganization),
            other: mdApple.other
        )
    }

    private func projectLists(into result: inout CanonicalContact, _ inputs: Inputs) {
        let source = inputs.values
        let existing = inputs.existing
        let base = inputs.base
        let keys = BaseKeys(keyer: keyer)
        result.emails = Self.merge(source.emails, existing?.emails, base: base?.keys("emails"), key: keys.email)
        result.phones = Self.merge(source.phones, existing?.phones, base: base?.keys("phones"), key: keys.phone)
        result.urls = Self.merge(source.urls, existing?.urls, base: base?.keys("urls"), key: keys.url)
        result.social = Self.merge(source.social, existing?.social, base: base?.keys("social"), key: keys.social)
        result.im = Self.merge(source.im, existing?.im, base: base?.keys("im"), key: keys.im)
        result.addresses = Self.merge(
            source.addresses, existing?.addresses, base: base?.keys("addresses"), key: keys.address)
        let markdownOnlyDates = existing?.dates.filter { Self.markdownOnlyDateLabels.contains($0.label ?? "") } ?? []
        let mdDates = existing?.dates.filter { !Self.markdownOnlyDateLabels.contains($0.label ?? "") }
        result.dates = Self.merge(source.dates, mdDates, base: base?.keys("dates"), key: keys.date) + markdownOnlyDates
    }

    /// Apple elements (with markdown display forms), then markdown elements
    /// Apple lacks unless `base` shows Apple deleted them.
    static func merge<Value>(
        _ apple: [Labeled<Value>], _ markdown: [Labeled<Value>]?, base: [String]?,
        key: (Labeled<Value>) -> String
    ) -> [Labeled<Value>] {
        let markdown = markdown ?? []
        let fromApple = keepDisplay(apple, markdown, key: key)
        let appleKeys = Set(apple.map(key))
        let deleted = Set(base ?? [])
        let kept = markdown.filter { element in
            let elementKey = key(element)
            return !appleKeys.contains(elementKey) && !deleted.contains(elementKey)
        }
        return fromApple + kept
    }

    /// Apple elements in Apple order; each takes the display value of an
    /// unused markdown element with the same comparison key.
    static func keepDisplay<Value>(
        _ apple: [Labeled<Value>], _ markdown: [Labeled<Value>], key: (Labeled<Value>) -> String
    ) -> [Labeled<Value>] {
        var available = markdown
        return apple.map { element in
            let wanted = key(element)
            guard let index = available.firstIndex(where: { key($0) == wanted }) else { return element }
            let match = available.remove(at: index)
            return Labeled(element.label, match.value)
        }
    }

    private func image(_ inputs: Inputs, existing: CanonicalContact?) -> ImageRef? {
        if let image = inputs.image { return image }
        // Thumbnail only (spike S5): the image is unknown, never "removed".
        if inputs.apple.imageUnavailable { return existing?.image }
        // No Apple photo: drop our own sidecar reference, keep a user-set image.
        guard let current = existing?.image, !current.path.contains(inputs.managedImagePrefix) else { return nil }
        return current
    }

    private func relationships(_ apple: [RelationshipRef], existing: [RelationshipRef]) -> [RelationshipRef] {
        func targetKey(_ target: RelationshipTarget?) -> String {
            switch target {
            case .wikilink(let inner)?:
                ComparisonKeys.name(Wikilink.target(of: "[[\(inner)]]") ?? inner)
            case .name(let name)?: ComparisonKeys.name(name)
            case .record(let id)?: id.uuidString
            case nil: ""
            }
        }
        var available = existing
        let fromApple = apple.map { ref -> RelationshipRef in
            guard
                let index = available.firstIndex(where: {
                    $0.type == ref.type && targetKey($0.target) == targetKey(ref.target)
                })
            else { return ref }
            let match = available.remove(at: index)
            return RelationshipRef(type: ref.type, label: ref.label, target: match.target, attributes: match.attributes)
        }
        let markdownOnly = available.filter { ref in
            Self.markdownOnlyRelationTypes.contains(ref.type) || ref.attributes.contains { $0.key == "from" }
        }
        return fromApple + markdownOnly
    }

    private func tags(apple: [String], existing: [String], managed: Set<String>) -> [String] {
        let appleKeys = Set(apple.map(ComparisonKeys.tag))
        let kept = existing.filter { tag in
            let key = ComparisonKeys.tag(tag)
            return !managed.contains(key) || appleKeys.contains(key)
        }
        let keptKeys = Set(kept.map(ComparisonKeys.tag))
        return kept + apple.filter { !keptKeys.contains(ComparisonKeys.tag($0)) }
    }
}

/// Comparison keys per markdown field, shared by the projection and the
/// record base so "Apple had it at the last export" means the same thing.
struct BaseKeys {
    let keyer: any PhoneKeyer

    func email(_ element: Labeled<String>) -> String { ComparisonKeys.email(element.value) }
    func phone(_ element: Labeled<String>) -> String { ComparisonKeys.phone(element.value, keyer: keyer) }
    func url(_ element: Labeled<String>) -> String { ComparisonKeys.url(element.value) }
    func social(_ element: Labeled<SocialHandle>) -> String { ComparisonKeys.url(element.value.value) }
    func im(_ element: Labeled<IMHandle>) -> String { element.value.value.lowercased() }
    func address(_ element: Labeled<PostalAddress>) -> String { ComparisonKeys.address(element.value) }
    func date(_ element: Labeled<PartialDate>) -> String { ComparisonKeys.date(element.value) }

    /// The base for Apple-side `values`.
    func base(of values: CanonicalContact) -> RecordBase {
        func one(_ value: String?) -> [String] { value.map { [$0] } ?? [] }
        func many<Value>(_ list: [Labeled<Value>], _ key: (Labeled<Value>) -> String) -> [String] {
            Array(Set(list.map(key))).sorted()
        }
        var fields: [String: [String]] = [
            "prefix": one(values.name.prefix), "first_name": one(values.name.given),
            "middle_name": one(values.name.middle), "last_name": one(values.name.family),
            "suffix": one(values.name.suffix),
            Alias.nicknameLabel: one(values.aliases.first { $0.label == Alias.nicknameLabel }?.name),
            Alias.maidenNameLabel: one(values.aliases.first { $0.label == Alias.maidenNameLabel }?.name),
            "company": one(values.company.map { ComparisonKeys.name($0.name) }),
            "department": one(values.department), "job_title": one(values.jobTitle),
            "apple.phonetic_first_name": one(values.apple.phoneticGiven),
            "apple.phonetic_middle_name": one(values.apple.phoneticMiddle),
            "apple.phonetic_last_name": one(values.apple.phoneticFamily),
            "apple.phonetic_organization": one(values.apple.phoneticOrganization),
            "emails": many(values.emails, email), "phones": many(values.phones, phone),
            "urls": many(values.urls, url), "social": many(values.social, social), "im": many(values.im, im),
            "addresses": many(values.addresses, address), "dates": many(values.dates, date),
            "name": Array(
                Set(
                    [MatchKeys.nameKey(values), ComparisonKeys.name(TitleGenerator.title(for: values))].compactMap {
                        $0
                    })
            ).sorted(),
        ]
        fields = fields.filter { !$0.value.isEmpty }
        return RecordBase(fields: fields)
    }
}
