internal import ContactModel
internal import Foundation

/// Builds the markdown contact for one Apple contact (one-way export, M1).
///
/// Rules (documented in markdown-schema §4 "One-way export (M1)"):
/// - Apple-backed fields come from Apple. Where a markdown element has the
///   same comparison key as the Apple one, the markdown **display form** is
///   kept (no reformatting churn).
/// - Markdown-owned and markdown-only data is preserved: `title`, plain and
///   other non-Apple aliases, unmanaged tags, `death` dates, mbr-only
///   relationship types and `from:` edges, edge attributes, unknown keys,
///   `apple:`/`mdsync:` extras, and the body unless Apple has a note.
struct ExportProjection {
    let keyer: any PhoneKeyer
    let notesAvailable: Bool

    /// Relationship types Apple cannot express (mbr inverses); kept from markdown.
    static let markdownOnlyRelationTypes: Set<String> = ["employer", "employee", "manages", "assists"]
    /// Date labels Apple has no field for; kept from markdown.
    static let markdownOnlyDateLabels: Set<String> = ["death"]

    struct Inputs {
        var apple: AppleContact
        var existing: CanonicalContact?
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
        let source = inputs.apple.contact
        let existing = inputs.existing
        var result = existing ?? CanonicalContact(kind: source.kind, title: inputs.title)
        result.kind = source.kind
        result.title = existing.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? inputs.title
        result.name = source.name
        let appleAliasLabels: Set<String?> = [Alias.nicknameLabel, Alias.maidenNameLabel]
        result.aliases = source.aliases + (existing?.aliases.filter { !appleAliasLabels.contains($0.label) } ?? [])
        result.company = inputs.company
        result.department = source.department
        result.jobTitle = source.jobTitle
        result.image = image(inputs, existing: existing)
        result.emails = Self.keepDisplay(source.emails, existing?.emails ?? [], key: ComparisonKeys.email)
        result.phones = Self.keepDisplay(source.phones, existing?.phones ?? []) {
            ComparisonKeys.phone($0, keyer: keyer)
        }
        result.urls = Self.keepDisplay(source.urls, existing?.urls ?? [], key: ComparisonKeys.url)
        result.social = Self.keepDisplay(source.social, existing?.social ?? []) { ComparisonKeys.url($0.value) }
        result.im = Self.keepDisplay(source.im, existing?.im ?? []) { $0.value.lowercased() }
        result.addresses = Self.keepDisplay(source.addresses, existing?.addresses ?? [], key: ComparisonKeys.address)
        result.dates =
            Self.keepDisplay(source.dates, existing?.dates ?? [], key: ComparisonKeys.date)
            + (existing?.dates.filter { Self.markdownOnlyDateLabels.contains($0.label ?? "") } ?? [])
        result.relationships = relationships(inputs.relationships, existing: existing?.relationships ?? [])
        result.tags = tags(apple: inputs.appleTags, existing: existing?.tags ?? [], managed: inputs.managedTagKeys)
        result.apple = AppleExtras(
            phoneticGiven: source.apple.phoneticGiven,
            phoneticMiddle: source.apple.phoneticMiddle,
            phoneticFamily: source.apple.phoneticFamily,
            phoneticOrganization: source.apple.phoneticOrganization,
            other: existing?.apple.other ?? []
        )
        result.sync = SyncMetadata(
            id: inputs.recordID, status: existing?.sync.status, other: existing?.sync.other ?? [])
        if notesAvailable, let note = source.body, !ComparisonKeys.body(note).isEmpty,
            ComparisonKeys.body(note) != ComparisonKeys.body(existing?.body)
        {
            result.body = note
        }
        return result
    }

    /// Apple elements in Apple order; each takes the display value of an
    /// unused markdown element with the same comparison key.
    static func keepDisplay<Value>(
        _ apple: [Labeled<Value>], _ markdown: [Labeled<Value>], key: (Value) -> String
    ) -> [Labeled<Value>] {
        var available = markdown
        return apple.map { element in
            let wanted = key(element.value)
            guard let index = available.firstIndex(where: { key($0.value) == wanted }) else { return element }
            let match = available.remove(at: index)
            return Labeled(element.label, match.value)
        }
    }

    private func image(_ inputs: Inputs, existing: CanonicalContact?) -> ImageRef? {
        if let image = inputs.image { return image }
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
