public import Foundation

/// Single-valued Apple fields the engine writes (architecture §6, "Stamping
/// and write targets").
public enum AppleScalarField: String, Hashable, Sendable, Codable, CaseIterable {
    case namePrefix
    case givenName
    case middleName
    case familyName
    case nameSuffix
    case nickname
    case previousFamilyName
    case organizationName
    case departmentName
    case jobTitle
    case phoneticGivenName
    case phoneticMiddleName
    case phoneticFamilyName
    case phoneticOrganizationName

    // swiftlint:disable cyclomatic_complexity
    /// The value of this field in a canonical contact.
    public func value(in contact: CanonicalContact) -> String? {
        switch self {
        case .namePrefix: contact.name.prefix
        case .givenName: contact.name.given
        case .middleName: contact.name.middle
        case .familyName: contact.name.family
        case .nameSuffix: contact.name.suffix
        case .nickname: contact.aliases.first { $0.label == Alias.nicknameLabel }?.name
        case .previousFamilyName: contact.aliases.first { $0.label == Alias.maidenNameLabel }?.name
        case .organizationName: contact.company?.name
        case .departmentName: contact.department
        case .jobTitle: contact.jobTitle
        case .phoneticGivenName: contact.apple.phoneticGiven
        case .phoneticMiddleName: contact.apple.phoneticMiddle
        case .phoneticFamilyName: contact.apple.phoneticFamily
        case .phoneticOrganizationName: contact.apple.phoneticOrganization
        }
    }

    /// Sets this field in a canonical contact (`nil` clears it).
    public func set(_ value: String?, in contact: inout CanonicalContact) {
        switch self {
        case .namePrefix: contact.name.prefix = value
        case .givenName: contact.name.given = value
        case .middleName: contact.name.middle = value
        case .familyName: contact.name.family = value
        case .nameSuffix: contact.name.suffix = value
        case .nickname: Self.setAlias(Alias.nicknameLabel, value, in: &contact)
        case .previousFamilyName: Self.setAlias(Alias.maidenNameLabel, value, in: &contact)
        case .organizationName: contact.company = value.map(CompanyRef.plain)
        case .departmentName: contact.department = value
        case .jobTitle: contact.jobTitle = value
        case .phoneticGivenName: contact.apple.phoneticGiven = value
        case .phoneticMiddleName: contact.apple.phoneticMiddle = value
        case .phoneticFamilyName: contact.apple.phoneticFamily = value
        case .phoneticOrganizationName: contact.apple.phoneticOrganization = value
        }
    }

    // swiftlint:enable cyclomatic_complexity

    private static func setAlias(_ label: String, _ value: String?, in contact: inout CanonicalContact) {
        if let index = contact.aliases.firstIndex(where: { $0.label == label }) {
            if let value { contact.aliases[index].name = value } else { contact.aliases.remove(at: index) }
        } else if let value {
            contact.aliases.append(Alias(label: label, name: value))
        }
    }
}

/// Multi-valued Apple fields the engine writes.
public enum AppleListField: String, Hashable, Sendable, Codable, CaseIterable {
    case emails
    case phones
    case urls
    case social
    case im
    case addresses
    /// `CNContact.dates` (not the birthday, which is `CardEdit.birthday`).
    case dates
    case relations
}

/// One value of a multi-valued Apple field, in canonical form.
public enum AppleValue: Hashable, Sendable {
    /// Email, phone or URL text.
    case text(String)
    /// Social profile; the element label is the service.
    case social(SocialHandle)
    /// Instant-message address; the element label is the service.
    case im(IMHandle)
    case address(PostalAddress)
    case date(PartialDate)
    /// A related name with its mbr relationship type and label (the adapter
    /// maps them to an Apple relation label, keeping an equivalent existing one).
    case relation(name: String, type: String, label: String?)
}

/// One element of the desired list for a field on one card.
///
/// `existing` is the element's current canonical value *on that card* when
/// it replaces or keeps one, so the adapter edits that `CNLabeledValue` in
/// place (its identifier survives, spike S4) instead of adding a new one.
public struct AppleListElement: Hashable, Sendable {
    /// Current value on the card this element keeps or replaces; `nil` = new.
    public var existing: AppleValue?
    /// The label as it was on the card (`existing`'s label, markdown form),
    /// for "label unchanged" checks; ignored for new elements.
    public var existingLabel: String?
    /// The wanted label, in markdown form (`mobile`, `summer_house`, service
    /// names for social/IM). `nil` = no label.
    public var label: String?
    public var value: AppleValue

    /// Creates an element.
    public init(existing: AppleValue? = nil, existingLabel: String? = nil, label: String?, value: AppleValue) {
        self.existing = existing
        self.existingLabel = existingLabel
        self.label = label
        self.value = value
    }
}

/// One change to one underlying card.
public enum CardEdit: Hashable, Sendable {
    /// Sets (or clears, with `nil`) a single-valued field.
    case scalar(AppleScalarField, String?)
    /// Sets or clears the birthday.
    case birthday(PartialDate?)
    /// Replaces the field's list with exactly these elements. Values on the
    /// card that the canonical model cannot represent are kept; the
    /// `x-c2mdsync:` stamp URL is always kept.
    case list(AppleListField, [AppleListElement])
    /// Sets or clears the note (only when the notes entitlement is present).
    case note(String?)
    /// Sets or clears the original image.
    case image(Data?)
}

/// A contact to create (a markdown-only note the user opted in).
public struct NewAppleContact: Hashable, Sendable {
    /// The record the new contact belongs to (keys the created card id in the result).
    public var recordID: UUID
    public var containerID: String
    public var kind: ContactKind
    /// Field values, applied to a fresh card.
    public var edits: [CardEdit]
    /// Stamp to add (only when stamping is enabled).
    public var stamp: UUID?
    /// Groups (in `containerID`) the new card joins.
    public var groupIDs: [String]

    /// Creates a new-contact request.
    public init(
        recordID: UUID, containerID: String, kind: ContactKind, edits: [CardEdit], stamp: UUID? = nil,
        groupIDs: [String] = []
    ) {
        self.recordID = recordID
        self.containerID = containerID
        self.kind = kind
        self.edits = edits
        self.stamp = stamp
        self.groupIDs = groupIDs
    }
}
