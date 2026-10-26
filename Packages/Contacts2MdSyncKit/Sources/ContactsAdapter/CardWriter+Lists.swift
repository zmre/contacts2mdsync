internal import ContactModel
internal import Contacts
internal import Foundation

/// List fields: rebuilding a card's labeled values from the wanted elements
/// while keeping identifiers, labels that map the same, and values the
/// canonical model cannot represent.
extension CardWriter {
    static func setList(_ field: AppleListField, _ elements: [AppleListElement], on contact: CNMutableContact) {
        switch field {
        case .emails, .phones, .urls: setTextList(field, elements, on: contact)
        case .social, .im: setServiceList(field, elements, on: contact)
        case .addresses, .dates, .relations: setStructuredList(field, elements, on: contact)
        }
    }

    private static func setTextList(
        _ field: AppleListField, _ elements: [AppleListElement], on contact: CNMutableContact
    ) {
        switch field {
        case .emails:
            contact.emailAddresses = rebuild(
                contact.emailAddresses, elements, canonical: { clean($0.value as String).map(AppleValue.text) },
                label: textLabel, make: { value in if case .text(let text) = value { text as NSString } else { nil } })
        case .phones:
            contact.phoneNumbers = rebuild(
                contact.phoneNumbers, elements, canonical: { clean($0.value.stringValue).map(AppleValue.text) },
                label: textLabel,
                make: { value in if case .text(let text) = value { CNPhoneNumber(stringValue: text) } else { nil } })
        case .urls:
            contact.urlAddresses = rebuild(
                contact.urlAddresses, elements,
                canonical: { entry in
                    SyncStamp.isStamp(entry.value as String) ? nil : clean(entry.value as String).map(AppleValue.text)
                },
                label: textLabel, make: { value in if case .text(let text) = value { text as NSString } else { nil } })
        default: break
        }
    }

    private static func setServiceList(
        _ field: AppleListField, _ elements: [AppleListElement], on contact: CNMutableContact
    ) {
        switch field {
        case .social:
            contact.socialProfiles = rebuild(
                contact.socialProfiles, elements,
                canonical: { AppleContactMapper.social($0).map { AppleValue.social($0.value) } },
                label: { _, existing in existing },
                make: { _ in nil }, makeLabeled: socialProfile)
        case .im:
            contact.instantMessageAddresses = rebuild(
                contact.instantMessageAddresses, elements,
                canonical: { AppleContactMapper.im($0).map { AppleValue.im($0.value) } },
                label: { _, existing in existing }, make: { _ in nil }, makeLabeled: imAddress)
        default: break
        }
    }

    private static func setStructuredList(
        _ field: AppleListField, _ elements: [AppleListElement], on contact: CNMutableContact
    ) {
        switch field {
        case .addresses:
            contact.postalAddresses = rebuild(
                contact.postalAddresses, elements,
                canonical: { AppleContactMapper.address($0).map { AppleValue.address($0.value) } }, label: textLabel,
                make: postalAddress)
        case .dates:
            contact.dates = rebuild(
                contact.dates, elements,
                canonical: { AppleContactMapper.partialDate($0.value as DateComponents).map(AppleValue.date) },
                label: textLabel,
                make: { value in
                    if case .date(let date) = value { components(date).map { $0 as NSDateComponents } } else { nil }
                })
        case .relations:
            contact.contactRelations = rebuild(
                contact.contactRelations, elements,
                canonical: { entry in
                    AppleContactMapper.relation(entry).flatMap { ref in
                        ref.target?.displayName.map { AppleValue.relation(name: $0, type: ref.type, label: ref.label) }
                    }
                },
                label: relationLabel,
                sameLabel: sameRelationLabel,
                make: { value in
                    guard case .relation(let name, _, _) = value else { return nil }
                    return CNContactRelation(name: name)
                })
        default: break
        }
    }

    // MARK: - Labeled-value lists

    /// The Apple label for a markdown label, keeping `existing` when it maps the same.
    private static func textLabel(_ element: AppleListElement, _ existing: String?) -> String? {
        LabelMap.appleLabel(fromMarkdown: element.label, existing: existing)
    }

    /// A relation's Contacts label carries its type and label (`_$!<Child>!$_`
    /// is `child`; `_$!<Daughter>!$_` is `child`/`daughter`), so a type change
    /// is a label change even when the markdown `label` stayed the same.
    private static func sameRelationLabel(_ element: AppleListElement) -> Bool {
        guard element.label == element.existingLabel else { return false }
        guard case .relation(_, let type, let label)? = element.existing,
            case .relation(_, let newType, let newLabel) = element.value
        else { return true }
        return type == newType && label == newLabel
    }

    private static func relationLabel(_ element: AppleListElement, _ existing: String?) -> String? {
        guard case .relation(_, let type, let label) = element.value else { return existing }
        if let existing, RelationLabelMap.mbr(fromApple: existing) == (type, label) { return existing }
        return RelationLabelMap.apple(type: type, label: label)
    }

    /// The new list: each wanted element reuses the card's labeled value with
    /// its `existing` canonical value (identifier kept), else is new; card
    /// values the model cannot represent (canonical `nil`) are kept.
    private static func rebuild<Value: NSCopying & NSSecureCoding>(
        _ current: [CNLabeledValue<Value>], _ elements: [AppleListElement],
        canonical: (CNLabeledValue<Value>) -> AppleValue?,
        label: (AppleListElement, String?) -> String?,
        sameLabel: (AppleListElement) -> Bool = { $0.label == $0.existingLabel },
        make: (AppleValue) -> Value?,
        makeLabeled: ((AppleListElement, CNLabeledValue<Value>?) -> CNLabeledValue<Value>?)? = nil
    ) -> [CNLabeledValue<Value>] {
        let mapped = current.map { canonical($0) }
        var used = Set<Int>()
        var result: [CNLabeledValue<Value>] = []
        for element in elements {
            let index = element.existing.flatMap { existing in
                current.indices.first { !used.contains($0) && mapped[$0] == existing }
            }
            if let index { used.insert(index) }
            let original = index.map { current[$0] }
            if let makeLabeled {
                if let original, element.existing == element.value, element.label == element.existingLabel {
                    result.append(original)
                } else if let labeled = makeLabeled(element, original) {
                    result.append(labeled)
                }
                continue
            }
            guard let original else {
                if let value = make(element.value) {
                    result.append(CNLabeledValue(label: label(element, nil), value: value))
                }
                continue
            }
            let newLabel = sameLabel(element) ? original.label : label(element, original.label)
            if element.existing == element.value, newLabel == original.label {
                result.append(original)
            } else if let value = element.existing == element.value ? original.value : make(element.value) {
                result.append(original.settingLabel(newLabel, value: value))
            }
        }
        for (index, value) in current.enumerated() where !used.contains(index) && mapped[index] == nil {
            result.append(value)
        }
        return result
    }

    private static let socialServices: [String: String] = [
        "twitter": CNSocialProfileServiceTwitter, "facebook": CNSocialProfileServiceFacebook,
        "linkedin": CNSocialProfileServiceLinkedIn, "flickr": CNSocialProfileServiceFlickr,
        "myspace": CNSocialProfileServiceMySpace, "sinaweibo": CNSocialProfileServiceSinaWeibo,
        "tencentweibo": CNSocialProfileServiceTencentWeibo, "yelp": CNSocialProfileServiceYelp,
        "gamecenter": CNSocialProfileServiceGameCenter,
    ]

    private static let imServices: [String: String] = [
        "aim": CNInstantMessageServiceAIM, "facebook": CNInstantMessageServiceFacebook,
        "gadugadu": CNInstantMessageServiceGaduGadu, "googletalk": CNInstantMessageServiceGoogleTalk,
        "icq": CNInstantMessageServiceICQ, "jabber": CNInstantMessageServiceJabber,
        "msn": CNInstantMessageServiceMSN, "qq": CNInstantMessageServiceQQ, "skype": CNInstantMessageServiceSkype,
        "yahoo": CNInstantMessageServiceYahoo,
    ]

    private static func service(_ label: String?, known: [String: String]) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return known[LabelMap.snakeCase(label).replacingOccurrences(of: "_", with: "")] ?? LabelMap.humanize(label)
    }

    private static func socialProfile(
        _ element: AppleListElement, _ original: CNLabeledValue<CNSocialProfile>?
    ) -> CNLabeledValue<CNSocialProfile>? {
        guard case .social(let handle) = element.value else { return nil }
        let text = handle.value
        let isURL = text.contains("://") || text.lowercased().hasPrefix("www.")
        let profile = CNSocialProfile(
            urlString: isURL ? text : nil, username: isURL ? nil : text, userIdentifier: nil,
            service: service(element.label, known: socialServices))
        return original.map { $0.settingLabel($0.label, value: profile) }
            ?? CNLabeledValue(label: nil, value: profile)
    }

    private static func imAddress(
        _ element: AppleListElement, _ original: CNLabeledValue<CNInstantMessageAddress>?
    ) -> CNLabeledValue<CNInstantMessageAddress>? {
        guard case .im(let handle) = element.value else { return nil }
        let address = CNInstantMessageAddress(
            username: handle.value, service: service(element.label, known: imServices) ?? "")
        return original.map { $0.settingLabel($0.label, value: address) }
            ?? CNLabeledValue(label: nil, value: address)
    }

    private static func postalAddress(_ value: AppleValue) -> CNPostalAddress? {
        guard case .address(let address) = value else { return nil }
        let postal = CNMutablePostalAddress()
        if let formatted = address.formatted {
            postal.street = formatted
        } else {
            postal.street = address.street ?? ""
            postal.city = address.city ?? ""
            postal.state = address.region ?? ""
            postal.postalCode = address.postcode ?? ""
            postal.country = address.country ?? ""
            postal.isoCountryCode = address.countryCode?.lowercased() ?? ""
        }
        return postal.copy() as? CNPostalAddress
    }

    private static func clean(_ text: String) -> String? { AppleContactMapper.clean(text) }
}
