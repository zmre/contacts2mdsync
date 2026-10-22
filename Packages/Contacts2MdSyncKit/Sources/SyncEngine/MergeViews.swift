internal import ContactModel
internal import Foundation
internal import VaultIndex

/// Single-valued merge units (architecture §7 `FieldPath`), named like their
/// markdown keys.
enum ScalarField: String, CaseIterable, Hashable, Sendable {
    case prefix
    case firstName = "first_name"
    case middleName = "middle_name"
    case lastName = "last_name"
    case suffix
    case nickname
    case maidenName = "maiden_name"
    case company
    case department
    case jobTitle = "job_title"
    case phoneticFirst = "apple.phonetic_first_name"
    case phoneticMiddle = "apple.phonetic_middle_name"
    case phoneticLast = "apple.phonetic_last_name"
    case phoneticOrganization = "apple.phonetic_organization"
    case birthday

    /// The Apple field (`nil` for the birthday, written with `CardEdit.birthday`).
    var apple: AppleScalarField? {
        switch self {
        case .prefix: .namePrefix
        case .firstName: .givenName
        case .middleName: .middleName
        case .lastName: .familyName
        case .suffix: .nameSuffix
        case .nickname: .nickname
        case .maidenName: .previousFamilyName
        case .company: .organizationName
        case .department: .departmentName
        case .jobTitle: .jobTitle
        case .phoneticFirst: .phoneticGivenName
        case .phoneticMiddle: .phoneticMiddleName
        case .phoneticLast: .phoneticFamilyName
        case .phoneticOrganization: .phoneticOrganizationName
        case .birthday: nil
        }
    }

    /// The display value in a contact (`company`: the organization name;
    /// `birthday`: ISO text, only for dates Apple can store).
    func value(in contact: CanonicalContact) -> String? {
        switch self {
        case .birthday:
            guard let date = contact.birthday, Self.appleCanStore(date) else { return nil }
            return date.iso
        default:
            return apple.flatMap { $0.value(in: contact) }.flatMap(Self.clean)
        }
    }

    /// Comparison key: trimmed NFC text (case matters: fixing a name's
    /// capitalization is a change), ISO for the birthday.
    static func key(_ value: String?) -> String? {
        value.flatMap(clean)?.precomposedStringWithCanonicalMapping
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Apple dates need a month and a day (`CNContact.birthday`/`dates`).
    static func appleCanStore(_ date: PartialDate) -> Bool {
        switch date {
        case .full, .monthDay: true
        case .yearMonth, .year, .text: false
        }
    }
}

/// Multi-valued merge units, merged element-wise by comparison key.
enum ListField: String, CaseIterable, Hashable, Sendable {
    case emails
    case phones
    case urls
    case social
    case im
    case addresses
    case dates
    case relationships

    var apple: AppleListField {
        switch self {
        case .emails: .emails
        case .phones: .phones
        case .urls: .urls
        case .social: .social
        case .im: .im
        case .addresses: .addresses
        case .dates: .dates
        case .relationships: .relations
        }
    }
}

/// One element of a list field as the merge sees it.
struct MergeElement: Hashable, Sendable {
    /// Comparison key (architecture §3).
    var key: String
    /// Markdown-form label (service for social/IM, relationship label).
    var label: String?
    /// Human display text (conflicts, output).
    var display: String
    /// The canonical value to write to Apple (and to rebuild markdown from).
    var value: AppleValue
    /// Index in the markdown list it came from (markdown side only).
    var markdownIndex: Int?
}

/// What a side says about the contact image.
enum ImageState: Hashable, Sendable {
    case none
    case hash(String)
    /// Thumbnail only (spike S5), a URL, or a missing file: never compared.
    case unknown

    var hash: String? {
        if case .hash(let hash) = self { return hash }
        return nil
    }
}

/// One side of a record as merge units (Apple values by card precedence, or
/// the markdown note).
struct FieldView: Sendable {
    var scalars: [ScalarField: String] = [:]
    var lists: [ListField: [MergeElement]] = [:]
    /// Managed tags (comparison keys), in order.
    var tags: [String] = []
    /// Body in comparison form (`nil` when notes are not synced).
    var body: String?
    var image: ImageState = .none

    func list(_ field: ListField) -> [MergeElement] { lists[field] ?? [] }
}

/// Resolves relationship targets to records so Apple's free-text relation
/// names and markdown `[[Title]]` links compare by record id (architecture
/// §7: element key = type + target uuid or name key).
struct RelationResolver: Sendable {
    /// Name key → record ids answering to it now (titles, aliases, Apple name variants).
    private var recordsByName: [String: Set<UUID>] = [:]
    /// Name key → record ids that answered to it before a rename (merge
    /// bases); consulted only when no record answers to the name now.
    private var formerByName: [String: Set<UUID>] = [:]
    /// Record → note title (markdown display).
    private var titles: [UUID: String] = [:]
    /// Record → Apple display name (written to other cards' relations).
    private var appleNames: [UUID: String] = [:]

    init() {}

    /// Adds a name a record answers to.
    mutating func add(_ name: String, record: UUID) {
        let key = ComparisonKeys.name(name)
        guard !key.isEmpty else { return }
        recordsByName[key, default: []].insert(record)
    }

    /// Adds a name key the record answered to before a rename.
    mutating func addFormer(key: String, record: UUID) {
        guard !key.isEmpty else { return }
        formerByName[key, default: []].insert(record)
    }

    mutating func setTitle(_ title: String, for record: UUID) { titles[record] = title }
    mutating func setAppleName(_ name: String, for record: UUID) { appleNames[record] = name }

    /// The record a name (or `[[link]]` target) means, when exactly one:
    /// by current names, else (no current match at all) by former names.
    func record(named name: String) -> UUID? {
        let target = Wikilink.target(of: name) ?? name
        let key = ComparisonKeys.name(target)
        let records = recordsByName[key] ?? formerByName[key] ?? []
        return records.count == 1 ? records.first : nil
    }

    func title(of record: UUID) -> String? { titles[record] }
    func appleName(of record: UUID) -> String? { appleNames[record] ?? titles[record] }

    /// The Apple name set for the record this run (no fallback to the title).
    func currentAppleName(of record: UUID) -> String? { appleNames[record] }
}

/// Relation names on Apple cards that still use a record's old name
/// (`CNContactRelation` is name-only, architecture §8): such a name is
/// rewritten to the record's current Apple display name. Only names that
/// resolve to a record through a former name are touched, so names the user
/// chose (a nickname, an alias, "Mom") are never rewritten, and a rewritten
/// name resolves to the same record (same element key: nothing churns).
struct RelationRenamer: Sendable {
    let resolver: RelationResolver
    /// Record → name keys it answered to before (merge base) that it no longer answers to.
    let stale: [UUID: Set<String>]

    /// No renames.
    static let none = RelationRenamer(resolver: RelationResolver(), stale: [:])

    /// The name to write instead of `name`, or `nil` to keep it.
    func newName(for name: String) -> String? {
        let key = ComparisonKeys.name(name)
        guard let record = resolver.record(named: name), stale[record]?.contains(key) == true,
            let current = resolver.currentAppleName(of: record), ComparisonKeys.name(current) != key,
            resolver.record(named: current) == record
        else { return nil }
        return current
    }
}

/// Builds field views with the record-independent context of a run.
struct ViewBuilder: Sendable {
    let keyer: any PhoneKeyer
    let notesAvailable: Bool
    let managedTagKeys: Set<String>
    let resolver: RelationResolver

    /// Relationship types Apple cannot express (mbr inverses); markdown-only.
    static let markdownOnlyRelationTypes = ExportProjection.markdownOnlyRelationTypes

    /// The Apple side: card-precedence values, managed tags from groups, image state.
    func apple(_ values: CanonicalContact, tags: [String], image: ImageState) -> FieldView {
        var view = common(values)
        view.lists[.relationships] = values.relationships.compactMap { relation($0, index: nil) }
        view.tags = managed(tags)
        view.image = image
        return view
    }

    /// The markdown side.
    func markdown(_ contact: CanonicalContact, image: ImageState) -> FieldView {
        var view = common(contact)
        for field in ListField.allCases where field != .relationships {
            view.lists[field] = view.list(field).enumerated().map { offset, element in
                var element = element
                element.markdownIndex = markdownIndex(field, contact, offset)
                return element
            }
        }
        view.lists[.relationships] = contact.relationships.enumerated().compactMap { offset, ref in
            Self.isMarkdownOnly(ref) ? nil : relation(ref, index: offset)
        }
        view.tags = managed(contact.tags)
        view.image = image
        return view
    }

    /// Markdown-only relationship entries (kept verbatim, never merged).
    static func isMarkdownOnly(_ ref: RelationshipRef) -> Bool {
        ref.target == nil || markdownOnlyRelationTypes.contains(ref.type)
            || ref.attributes.contains { $0.key == "from" }
    }

    private func managed(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map(ComparisonKeys.tag).filter { managedTagKeys.contains($0) && seen.insert($0).inserted }
    }

    /// The index of the `offset`-th mergeable element in the contact's markdown list.
    private func markdownIndex(_ field: ListField, _ contact: CanonicalContact, _ offset: Int) -> Int {
        guard field == .dates else { return offset }
        let indices = contact.dates.indices.filter { Self.isMergeableDate(contact.dates[$0]) }
        return indices[offset]
    }

    static func isMergeableDate(_ date: Labeled<PartialDate>) -> Bool {
        date.label != "birthday" && !ExportProjection.markdownOnlyDateLabels.contains(date.label ?? "")
            && ScalarField.appleCanStore(date.value)
    }

    private func common(_ contact: CanonicalContact) -> FieldView {
        var view = FieldView()
        for field in ScalarField.allCases {
            if let value = field.value(in: contact) { view.scalars[field] = value }
        }
        view.lists[.emails] = contact.emails.map { text($0, key: Keys.email($0.value)) }
        view.lists[.phones] = contact.phones.map { text($0, key: ComparisonKeys.phone($0.value, keyer: keyer)) }
        view.lists[.urls] = contact.urls.map { text($0, key: ComparisonKeys.url($0.value)) }
        view.lists[.social] = contact.social.map { element in
            MergeElement(
                key: Keys.social(element), label: element.label, display: element.value.value,
                value: .social(element.value))
        }
        view.lists[.im] = contact.im.map { element in
            MergeElement(
                key: Keys.im(element), label: element.label, display: element.value.value, value: .im(element.value))
        }
        view.lists[.addresses] = contact.addresses.map { element in
            MergeElement(
                key: ComparisonKeys.address(element.value), label: element.label,
                display: Keys.addressDisplay(element.value), value: .address(element.value))
        }
        view.lists[.dates] = contact.dates.filter(Self.isMergeableDate).map { element in
            MergeElement(
                key: element.value.iso, label: element.label, display: element.value.iso, value: .date(element.value))
        }
        if notesAvailable { view.body = ComparisonKeys.body(contact.body) }
        return view
    }

    private func text(_ element: Labeled<String>, key: String) -> MergeElement {
        MergeElement(key: key, label: element.label, display: element.value, value: .text(element.value))
    }

    /// A relationship element: key `type|r:<record>` when the target resolves
    /// to exactly one record, else `type|n:<name key>`.
    func relation(_ ref: RelationshipRef, index: Int?) -> MergeElement? {
        let name: String
        switch ref.target {
        case .wikilink(let inner)?: name = Wikilink.target(of: "[[\(inner)]]") ?? inner
        case .name(let text)?: name = text
        case .record(let id)?: name = resolver.title(of: id) ?? id.uuidString
        case nil: return nil
        }
        let record: UUID? =
            if case .record(let id)? = ref.target { id } else { resolver.record(named: name) }
        let target = record.map { "r:\($0.uuidString.lowercased())" } ?? "n:\(ComparisonKeys.name(name))"
        let display =
            if case .wikilink(let inner)? = ref.target { "[[\(inner)]]" } else { name }
        // Written to Apple as the target's Apple display name (markdown-schema §6).
        let appleName = index == nil ? name : record.flatMap(resolver.appleName(of:)) ?? name
        return MergeElement(
            key: "\(ref.type)|\(target)", label: ref.label, display: display,
            value: .relation(name: appleName, type: ref.type, label: ref.label), markdownIndex: index)
    }
}

/// Comparison keys of list elements (architecture §3).
enum Keys {
    static func email(_ value: String) -> String { ComparisonKeys.email(value) }

    /// (service, username): the label is the service; a URL value is keyed
    /// as a URL, a handle lowercased.
    static func social(_ element: Labeled<SocialHandle>) -> String {
        let value = element.value.value
        let handle = value.contains("://") ? ComparisonKeys.url(value).lowercased() : value.lowercased()
        return "\(element.label ?? "")|\(handle)"
    }

    static func im(_ element: Labeled<IMHandle>) -> String {
        "\(element.label ?? "")|\(element.value.value.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    static func addressDisplay(_ address: PostalAddress) -> String {
        if let formatted = address.formatted { return formatted }
        return [address.street, address.city, address.region, address.postcode, address.country]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
