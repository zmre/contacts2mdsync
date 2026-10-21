internal import ContactModel

/// The frontmatter keys the codec owns, in emission order (markdown-schema
/// §1), each with how to emit it and how to tell whether its value changed.
struct ManagedKey: Sendable {
    let name: String
    /// The value to write, or `nil` to omit the key.
    let emit: @Sendable (CanonicalContact) -> YAMLValue?
    /// Whether two contacts agree on this key (used to keep original bytes).
    let equal: @Sendable (CanonicalContact, CanonicalContact) -> Bool
}

enum ManagedKeys {
    static let all: [ManagedKey] = [
        ManagedKey(name: "type", emit: { .scalar($0.kind.rawValue, plain: true) }, equal: { $0.kind == $1.kind }),
        text("title") { $0.title.isEmpty ? nil : $0.title },
        text("prefix") { $0.name.prefix },
        text("first_name") { $0.name.given },
        text("middle_name") { $0.name.middle },
        text("last_name") { $0.name.family },
        text("suffix") { $0.name.suffix },
        ManagedKey(name: "aliases", emit: { aliases($0.aliases) }, equal: { $0.aliases == $1.aliases }),
        text("company") { $0.company?.raw },
        text("department") { $0.department },
        text("job_title") { $0.jobTitle },
        text("image") { $0.image?.path },
        ManagedKey(name: "emails", emit: { labeled($0.emails) }, equal: { $0.emails == $1.emails }),
        ManagedKey(name: "phones", emit: { labeled($0.phones, forceQuotes: true) }, equal: { $0.phones == $1.phones }),
        ManagedKey(name: "urls", emit: { labeled($0.urls) }, equal: { $0.urls == $1.urls }),
        ManagedKey(
            name: "social", emit: { labeled($0.social.map { Labeled($0.label, $0.value.value) }) },
            equal: { $0.social == $1.social }),
        ManagedKey(
            name: "im", emit: { labeled($0.im.map { Labeled($0.label, $0.value.value) }) },
            equal: { $0.im == $1.im }),
        ManagedKey(name: "addresses", emit: { addresses($0.addresses) }, equal: { $0.addresses == $1.addresses }),
        ManagedKey(name: "dates", emit: { dates($0.dates) }, equal: { $0.dates == $1.dates }),
        ManagedKey(
            name: "relationships", emit: { relationships($0.relationships) },
            equal: { $0.relationships == $1.relationships }),
        ManagedKey(
            name: "tags", emit: { $0.tags.isEmpty ? nil : .sequence($0.tags.map { YAMLWriter.scalar($0) }) },
            equal: { $0.tags == $1.tags }),
        ManagedKey(name: "apple", emit: { apple($0.apple) }, equal: { $0.apple == $1.apple }),
        ManagedKey(name: "mdsync", emit: { sync($0.sync) }, equal: { $0.sync == $1.sync }),
    ]

    static let names: Set<String> = Set(all.map(\.name))

    static let order: [String: Int] = Dictionary(
        uniqueKeysWithValues: all.enumerated().map { ($0.element.name, $0.offset) })

    // MARK: - Builders

    private static func text(_ name: String, _ get: @escaping @Sendable (CanonicalContact) -> String?) -> ManagedKey {
        ManagedKey(name: name, emit: { get($0).map { YAMLWriter.scalar($0) } }, equal: { get($0) == get($1) })
    }

    private static func item(_ label: String?, _ value: YAMLValue) -> YAMLValue {
        guard let label else { return value }
        return .mapping([YAMLField(key: label, value: value)])
    }

    private static func labeled(_ values: [Labeled<String>], forceQuotes: Bool = false) -> YAMLValue? {
        guard !values.isEmpty else { return nil }
        return .sequence(values.map { item($0.label, YAMLWriter.scalar($0.value, forceQuotes: forceQuotes)) })
    }

    private static func aliases(_ values: [Alias]) -> YAMLValue? {
        guard !values.isEmpty else { return nil }
        return .sequence(values.map { item($0.label, YAMLWriter.scalar($0.name)) })
    }

    private static func addresses(_ values: [Labeled<PostalAddress>]) -> YAMLValue? {
        let items: [YAMLValue] = values.compactMap { entry in
            let address = entry.value
            // A label spelled like an address field (or `label`/`value`) would be
            // misread by mbr as part of the address; use the `label:` form.
            let ambiguousLabel =
                entry.label.map {
                    ContactDecoding.addressFields.contains($0) || ["label", "value", "name"].contains($0)
                } ?? false
            if let formatted = address.formatted {
                let value = YAMLWriter.scalar(formatted)
                guard ambiguousLabel, let label = entry.label else { return item(entry.label, value) }
                return .mapping([
                    YAMLField(key: "label", value: YAMLWriter.scalar(label)), YAMLField(key: "value", value: value),
                ])
            }
            let fields = addressFields(address)
            guard !fields.isEmpty else { return nil }
            guard let label = entry.label else { return .mapping(fields) }
            if ambiguousLabel {
                return .mapping([YAMLField(key: "label", value: YAMLWriter.scalar(label))] + fields)
            }
            return item(label, .mapping(fields))
        }
        return items.isEmpty ? nil : .sequence(items)
    }

    private static func addressFields(_ address: PostalAddress) -> [YAMLField] {
        let parts: [(key: String, value: String?)] = [
            ("street", address.street),
            ("city", address.city),
            ("region", address.region),
            ("postcode", address.postcode),
            ("country", address.country),
            ("country_code", address.countryCode),
        ]
        // Postcodes are always quoted (`02134`, `1000`, …).
        return parts.compactMap { key, value in
            value.map { YAMLField(key: key, value: YAMLWriter.scalar($0, forceQuotes: key == "postcode")) }
        }
    }

    private static func dates(_ values: [Labeled<PartialDate>]) -> YAMLValue? {
        guard !values.isEmpty else { return nil }
        func value(_ date: PartialDate) -> YAMLValue {
            if case .text(let text) = date { return YAMLWriter.scalar(text) }
            return YAMLWriter.scalar(date.iso, forceQuotes: true)
        }
        let labels = values.compactMap(\.label)
        // `dates` is a map (mbr's documented form) unless labels repeat or are
        // missing, which a map cannot hold; then the equally valid list form.
        if labels.count == values.count, Set(labels).count == labels.count {
            return .mapping(values.map { YAMLField(key: $0.label ?? "", value: value($0.value)) })
        }
        return .sequence(values.map { item($0.label, value($0.value)) })
    }

    private static func relationships(_ values: [RelationshipRef]) -> YAMLValue? {
        guard !values.isEmpty else { return nil }
        return .sequence(
            values.map { ref in
                var fields = [YAMLField(key: "type", value: YAMLWriter.scalar(ref.type))]
                switch ref.target {
                case .wikilink(let inner)?:
                    fields.append(YAMLField(key: "to", value: YAMLWriter.scalar("[[\(inner)]]")))
                case .name(let name)?:
                    fields.append(YAMLField(key: "to", value: YAMLWriter.scalar(name)))
                case .record, nil:
                    break  // `.record` is rejected before emission.
                }
                if let label = ref.label { fields.append(YAMLField(key: "label", value: YAMLWriter.scalar(label))) }
                return .mapping(fields + ref.attributes)
            })
    }

    private static func apple(_ extras: AppleExtras) -> YAMLValue? {
        let known: [(String, String?)] = [
            ("phonetic_first_name", extras.phoneticGiven),
            ("phonetic_middle_name", extras.phoneticMiddle),
            ("phonetic_last_name", extras.phoneticFamily),
            ("phonetic_organization_name", extras.phoneticOrganization),
        ]
        let fields = known.compactMap { key, value in value.map { YAMLField(key: key, value: YAMLWriter.scalar($0)) } }
        let all = fields + extras.other
        return all.isEmpty ? nil : .mapping(all)
    }

    private static func sync(_ metadata: SyncMetadata) -> YAMLValue? {
        var fields: [YAMLField] = []
        if let id = metadata.id {
            // UUIDs are always safe plain scalars (dashes rule out numbers).
            fields.append(YAMLField(key: "id", value: .scalar(id.uuidString.lowercased(), plain: true)))
        }
        if let status = metadata.status { fields.append(YAMLField(key: "status", value: YAMLWriter.scalar(status))) }
        fields += metadata.other
        return fields.isEmpty ? nil : .mapping(fields)
    }
}
