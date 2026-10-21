internal import ContactModel
internal import Foundation

/// The base of one scalar.
enum BaseScalar: Hashable, Sendable {
    case unknown
    /// Agreed comparison key (`nil` = empty).
    case known(String?)
}

/// The base of one list element's label.
enum BaseLabel: Hashable, Sendable {
    case unknown
    case known(String?)
}

/// The base of one list field.
struct BaseList: Hashable, Sendable {
    var known: Bool
    /// Key → label, display.
    var elements: [String: (label: BaseLabel, display: String?)]

    static let unknown = BaseList(known: false, elements: [:])

    static func == (lhs: BaseList, rhs: BaseList) -> Bool {
        lhs.known == rhs.known && lhs.elements.keys == rhs.elements.keys
            && lhs.elements.allSatisfy { key, value in rhs.elements[key]?.label == value.label }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(known)
        hasher.combine(elements.keys.sorted())
    }
}

/// The merge base of a record, decoded from `RecordBase` (M3 version 2, an M2
/// export base, or none).
struct BaseView: Sendable {
    var scalars: [ScalarField: BaseScalar] = [:]
    var lists: [ListField: BaseList] = [:]
    /// `nil` = unknown.
    var tags: Set<String>?
    /// `.unknown` when there is no base body.
    var body: BaseScalar = .unknown
    var image: BaseScalar = .unknown
    /// The title generated from Apple's name at the last sync.
    var generatedTitle: String?
    /// M2 bases: name keys (personal name and generated title, folded).
    var legacyNameKeys: Set<String> = []

    /// No base at all (first bind, adoption): every field unknown.
    static let none = BaseView()

    func scalar(_ field: ScalarField) -> BaseScalar { scalars[field] ?? .unknown }
    func list(_ field: ListField) -> BaseList { lists[field] ?? .unknown }

    init() {}

    /// The view of a stored base (`nil`: none).
    static func of(_ base: RecordBase?) -> BaseView {
        guard let base else { return .none }
        return base.isMergeBase ? BaseView(merge: base) : BaseView(legacy: base)
    }

    private init(merge base: RecordBase) {
        let unknown = Set(base.unknown ?? [])
        for field in ScalarField.allCases where !unknown.contains(field.rawValue) {
            scalars[field] = .known(base.fields[field.rawValue]?.first)
        }
        for field in ListField.allCases where !unknown.contains(field.rawValue) {
            let labels = base.labels?[field.rawValue] ?? [:]
            let displays = base.displays?[field.rawValue] ?? [:]
            var elements: [String: (label: BaseLabel, display: String?)] = [:]
            for key in base.keys(field.rawValue) {
                let label: BaseLabel = labels[key].map { .known($0.isEmpty ? nil : $0) } ?? .unknown
                elements[key] = (label, displays[key])
            }
            lists[field] = BaseList(known: true, elements: elements)
        }
        if !unknown.contains("tags") { tags = Set(base.tags ?? []) }
        if !unknown.contains("body") { body = .known(base.body) }
        if !unknown.contains("image") { image = .known(base.imageHash) }
        generatedTitle = base.generatedTitle
    }

    /// An M2 export base: the Apple side's keys at the last export. Fields
    /// whose key definition changed in M3 (company, social, IM, dates,
    /// birthday, relationships) and data M2 did not record (labels, tags,
    /// body, image) have no base.
    private init(legacy base: RecordBase) {
        let compatible: [ScalarField] = [
            .prefix, .firstName, .middleName, .lastName, .suffix, .nickname, .maidenName, .department, .jobTitle,
            .phoneticFirst, .phoneticMiddle, .phoneticLast, .phoneticOrganization,
        ]
        for field in compatible { scalars[field] = .known(base.fields[field.rawValue]?.first) }
        for field in [ListField.emails, .phones, .urls, .addresses] {
            var elements: [String: (label: BaseLabel, display: String?)] = [:]
            for key in base.keys(field.rawValue) { elements[key] = (.unknown, nil) }
            lists[field] = BaseList(known: true, elements: elements)
        }
        legacyNameKeys = Set(base.keys("name"))
    }
}
