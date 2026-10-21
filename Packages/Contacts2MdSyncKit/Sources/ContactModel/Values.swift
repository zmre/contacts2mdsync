public import Foundation

/// Whether a contact is a person or an organization (`type:` in markdown,
/// `CNContact.contactType` in Apple Contacts).
public enum ContactKind: String, Hashable, Sendable, Codable, CaseIterable {
    case person
    case organization
}

/// The structured parts of a person's name.
public struct PersonName: Hashable, Sendable {
    public var prefix: String?
    public var given: String?
    public var middle: String?
    public var family: String?
    public var suffix: String?

    /// Creates a name; empty strings are stored as `nil`.
    public init(
        prefix: String? = nil,
        given: String? = nil,
        middle: String? = nil,
        family: String? = nil,
        suffix: String? = nil
    ) {
        self.prefix = prefix.nonEmpty
        self.given = given.nonEmpty
        self.middle = middle.nonEmpty
        self.family = family.nonEmpty
        self.suffix = suffix.nonEmpty
    }

    /// `true` when no part is set.
    public var isEmpty: Bool {
        prefix == nil && given == nil && middle == nil && family == nil && suffix == nil
    }
}

/// An alternate name from `aliases:`.
///
/// `label` is `nil` for a plain alias (markdown-only), `nickname` for
/// `CNContact.nickname` and `maiden_name` for `CNContact.previousFamilyName`.
/// Any other label (`formerly`, …) round-trips as authored.
public struct Alias: Hashable, Sendable {
    /// Label for `CNContact.nickname`.
    public static let nicknameLabel = "nickname"
    /// Label for `CNContact.previousFamilyName`.
    public static let maidenNameLabel = "maiden_name"

    public var label: String?
    public var name: String

    /// Creates an alias.
    public init(label: String?, name: String) {
        self.label = label
        self.name = name
    }

    /// A plain (unlabeled) alias.
    public static func plain(_ name: String) -> Alias { Alias(label: nil, name: name) }
    /// A nickname alias.
    public static func nickname(_ name: String) -> Alias { Alias(label: nicknameLabel, name: name) }
    /// A maiden-name (previous family name) alias.
    public static func maidenName(_ name: String) -> Alias { Alias(label: maidenNameLabel, name: name) }
}

/// The `company:` value. Either plain text or an mbr wikilink to an
/// organization note (`[[Acme Corp]]`, optionally `[[Target|Shown]]`).
public struct CompanyRef: Hashable, Sendable {
    /// The value exactly as written (`[[Acme Corp]]` or `Acme Corp`).
    public var raw: String

    /// Wraps an already-authored value.
    public init(raw: String) { self.raw = raw }

    /// Plain-text company.
    public static func plain(_ name: String) -> CompanyRef { CompanyRef(raw: name) }

    /// Wikilink to an organization note titled `title`.
    public static func wikilink(_ title: String) -> CompanyRef { CompanyRef(raw: "[[\(title)]]") }

    /// `true` when `raw` is a `[[…]]` wikilink.
    public var isWikilink: Bool { Wikilink.inner(of: raw) != nil }

    /// The organization name: the wikilink's shown text (or target), or the plain text.
    public var name: String {
        guard let inner = Wikilink.inner(of: raw) else { return raw }
        let parts = inner.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[1].isEmpty { return parts[1] }
        return parts[0]
    }
}

/// Helpers for mbr `[[wikilink]]` values.
public enum Wikilink {
    /// The text between `[[` and `]]`, trimmed, or `nil` when `value` is not a wikilink.
    public static func inner(of value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[["), trimmed.hasSuffix("]]"), trimmed.count > 4 else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    /// The link target (text before `|`), or `nil` when `value` is not a wikilink.
    public static func target(of value: String) -> String? {
        guard let inner = inner(of: value) else { return nil }
        return inner.split(separator: "|", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// A value of a multi-value field with an optional markdown label
/// (`mobile`, `work`, `summer_house`, …). `nil` label = bare list item.
public struct Labeled<Value: Hashable & Sendable>: Hashable, Sendable {
    public var label: String?
    public var value: Value

    /// Creates a labeled value.
    public init(_ label: String?, _ value: Value) {
        self.label = label
        self.value = value
    }
}

/// One postal address. Either structured components or, when the markdown
/// author wrote a plain string, `formatted` preformatted lines.
public struct PostalAddress: Hashable, Sendable {
    public var street: String?
    public var city: String?
    public var region: String?
    public var postcode: String?
    public var country: String?
    public var countryCode: String?
    /// A preformatted address (markdown string form); exclusive with components.
    public var formatted: String?

    /// Creates a structured address; empty strings become `nil`.
    public init(
        street: String? = nil,
        city: String? = nil,
        region: String? = nil,
        postcode: String? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        formatted: String? = nil
    ) {
        self.street = street.nonEmpty
        self.city = city.nonEmpty
        self.region = region.nonEmpty
        self.postcode = postcode.nonEmpty
        self.country = country.nonEmpty
        self.countryCode = countryCode.nonEmpty
        self.formatted = formatted.nonEmpty
    }

    /// `true` when nothing is set.
    public var isEmpty: Bool {
        street == nil && city == nil && region == nil && postcode == nil && country == nil
            && countryCode == nil && formatted == nil
    }
}

/// A date that may lack a year (the normal case for phone-book birthdays),
/// or free text that is not a date at all (mbr shows it verbatim).
public enum PartialDate: Hashable, Sendable {
    case full(year: Int, month: Int, day: Int)
    case monthDay(month: Int, day: Int)
    case yearMonth(year: Int, month: Int)
    case year(Int)
    /// Unparseable text such as "circa 1855"; markdown-only.
    case text(String)

    /// Parses `YYYY-MM-DD`, `--MM-DD`, `MM-DD`, `YYYY-MM` and `YYYY` (mbr's
    /// accepted forms); anything else becomes `.text`.
    public init(parsing input: String) {
        let text = input.trimmingCharacters(in: .whitespaces)
        self = Self.parse(text) ?? .text(text)
    }

    private static func parse(_ text: String) -> PartialDate? {
        if text.hasPrefix("--") { return monthDay(String(text.dropFirst(2))) }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 3:
            guard let year = number(parts[0], digits: 4), let month = month(parts[1]),
                let day = day(parts[2], month: month)
            else { return nil }
            return .full(year: year, month: month, day: day)
        case 2 where parts[0].count == 4:
            guard let year = number(parts[0], digits: 4), let month = month(parts[1]) else { return nil }
            return .yearMonth(year: year, month: month)
        case 2:
            return monthDay(text)
        case 1:
            return number(parts[0], digits: 4).map { .year($0) }
        default:
            return nil
        }
    }

    private static func monthDay(_ text: String) -> PartialDate? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let month = month(parts[0]), let day = day(parts[1], month: month) else {
            return nil
        }
        return .monthDay(month: month, day: day)
    }

    private static func number(_ text: String, digits: Int) -> Int? {
        guard text.count == digits, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(text)
    }

    private static func month(_ text: String) -> Int? {
        guard let month = number(text, digits: 2), (1...12).contains(month) else { return nil }
        return month
    }

    private static func day(_ text: String, month: Int) -> Int? {
        let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard let day = number(text, digits: 2), (1...lengths[month - 1]).contains(day) else { return nil }
        return day
    }

    /// Canonical text: `YYYY-MM-DD`, `--MM-DD`, `YYYY-MM`, `YYYY`, or the text.
    /// Also the comparison key.
    public var iso: String {
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        switch self {
        case .full(let year, let month, let day): return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
        case .monthDay(let month, let day): return "--\(pad(month, 2))-\(pad(day, 2))"
        case .yearMonth(let year, let month): return "\(pad(year, 4))-\(pad(month, 2))"
        case .year(let year): return pad(year, 4)
        case .text(let text): return text
        }
    }
}

/// A social profile: a profile URL or, when Apple has none, the username.
/// The service is the `Labeled` label (`linkedin`, `twitter`, …).
public struct SocialHandle: Hashable, Sendable {
    public var value: String

    /// Creates a handle.
    public init(_ value: String) { self.value = value }
}

/// An instant-messaging address. The service is the `Labeled` label.
public struct IMHandle: Hashable, Sendable {
    public var value: String

    /// Creates a handle.
    public init(_ value: String) { self.value = value }
}

/// The other end of a relationship.
public enum RelationshipTarget: Hashable, Sendable {
    /// A synced record, by `c2mdsync.id`. Engine-internal: resolved to a
    /// `.wikilink` (the record's title) before encoding.
    case record(UUID)
    /// `to: "[[Title]]"` in markdown.
    case wikilink(String)
    /// A plain name (unresolved, ambiguous, or authored that way).
    case name(String)

    /// The human-readable name: title, or plain name.
    public var displayName: String? {
        switch self {
        case .record: nil
        case .wikilink(let title): title
        case .name(let name): name
        }
    }
}

/// One `relationships:` entry. mbr derives reverse edges itself; we only
/// ever write the edges Apple (or the author) declared.
public struct RelationshipRef: Hashable, Sendable {
    /// mbr relationship type (`spouse`, `parent`, `reports_to`, custom snake_case).
    public var type: String
    /// Optional refinement (`father`, `wife`, …).
    public var label: String?
    /// `to:`; `nil` for an authored edge with only `from:` (kept in `attributes`).
    public var target: RelationshipTarget?
    /// Extra edge attributes (`married: 1948-06-01`), markdown-only, preserved.
    public var attributes: [YAMLField]

    /// Creates a relationship.
    public init(type: String, label: String? = nil, target: RelationshipTarget?, attributes: [YAMLField] = []) {
        self.type = type
        self.label = label
        self.target = target
        self.attributes = attributes
    }
}

/// The `image:` reference as written in markdown: a path relative to the
/// note's folder, or a URL. Image bytes live outside the canonical model
/// (`AppleContact.imageData`, sidecar files) and are compared by hash.
public struct ImageRef: Hashable, Sendable {
    public var path: String

    /// Creates a reference.
    public init(path: String) { self.path = path }
}

/// Apple fields mbr has no slot for, stored under `apple:`.
public struct AppleExtras: Hashable, Sendable {
    public var phoneticGiven: String?
    public var phoneticMiddle: String?
    public var phoneticFamily: String?
    public var phoneticOrganization: String?
    /// Unknown `apple:` sub-keys, preserved in order.
    public var other: [YAMLField]

    /// Creates extras; empty strings become `nil`.
    public init(
        phoneticGiven: String? = nil,
        phoneticMiddle: String? = nil,
        phoneticFamily: String? = nil,
        phoneticOrganization: String? = nil,
        other: [YAMLField] = []
    ) {
        self.phoneticGiven = phoneticGiven.nonEmpty
        self.phoneticMiddle = phoneticMiddle.nonEmpty
        self.phoneticFamily = phoneticFamily.nonEmpty
        self.phoneticOrganization = phoneticOrganization.nonEmpty
        self.other = other
    }

    /// `true` when nothing would be written.
    public var isEmpty: Bool {
        phoneticGiven == nil && phoneticMiddle == nil && phoneticFamily == nil && phoneticOrganization == nil
            && other.isEmpty
    }
}

/// The engine-owned `c2mdsync:` block.
public struct SyncMetadata: Hashable, Sendable {
    /// The record identity (`c2mdsync.id`), lowercase UUID v4 in markdown.
    public var id: UUID?
    /// `detached` when out of scope / unlinked (M3).
    public var status: String?
    /// Unknown `c2mdsync:` sub-keys, preserved in order.
    public var other: [YAMLField]

    /// Creates metadata.
    public init(id: UUID? = nil, status: String? = nil, other: [YAMLField] = []) {
        self.id = id
        self.status = status
        self.other = other
    }

    /// `true` when nothing would be written.
    public var isEmpty: Bool { id == nil && status == nil && other.isEmpty }

    /// `status` of a note that is no longer synced (out of scope, delete kept).
    public static let detached = "detached"
}

extension Optional where Wrapped == String {
    /// `nil` for `nil` or an empty / whitespace-only string.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
