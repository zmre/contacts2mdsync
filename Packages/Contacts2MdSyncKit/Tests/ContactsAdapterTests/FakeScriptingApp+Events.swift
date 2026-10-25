import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

/// The event interpreter of `FakeScriptingApp`: what Contacts.app does with
/// each card-write event (per the sdef and spike S15), on in-memory cards.
extension FakeScriptingApp {
    static func code(_ text: String) -> FourCharCode { ContactsScriptingEvents.fourCC(text) }

    static func text(_ value: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }

    private static func noSuchObject(_ what: String) -> ContactsScriptingError {
        ContactsScriptingError(number: -1728, message: "Can't get \(what).")
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func handle(_ kind: String, _ event: NSAppleEventDescriptor, _ state: inout State) throws {
        let direct = Spec.decode(event.paramDescriptor(forKeyword: Self.code("----")))
        switch kind {
        case "core/cnte":
            break
        case "core/save":
            if let error = state.saveError { throw ContactsScriptingError(number: error, message: "save failed") }
            state.saves += 1
            for (id, card) in state.pending { state.saved[id] = card.copy() as? CNContact }
            state.savedGroups = state.pendingGroups
        case "core/setd":
            guard case .property(let property, let target)? = direct,
                let value = event.paramDescriptor(forKeyword: Self.code("data"))
            else { throw noSuchObject("property") }
            switch target {
            case .person(let id):
                guard let card = state.pending[id], !state.missingPeople.contains(id) else {
                    throw noSuchObject("person id \(id)")
                }
                try refusePerson(id, state)
                try setPerson(property, value.stringValue ?? "", on: card)
            default:
                let found = try resolve(target, &state)
                guard let card = state.pending[found.person] else { throw noSuchObject("person id \(found.person)") }
                try setElement(found.element, found.entry, property, value, on: card)
            }
        case "core/getd":
            guard case .property(ContactsScriptingEvents.Code.id, .person(let id))? = direct,
                state.pending[id] != nil, !state.missingPeople.contains(id)
            else { throw noSuchObject("person") }
        case "core/crel":
            try makeElement(event, &state)
        case "core/delo":
            guard let direct else { throw noSuchObject("element") }
            let found = try resolve(direct, &state)
            guard let card = state.pending[found.person] else { throw noSuchObject("element") }
            try delete(found.element, found.entry, on: card)
        case "az00/az44", "az00/az46":
            guard case .person(let id)? = direct, state.pending[id] != nil,
                case .group(let group)? = Spec.decode(
                    event.paramDescriptor(forKeyword: code(kind == "az00/az44" ? "az45" : "az47")))
            else { throw noSuchObject("person or group") }
            try refusePerson(id, state)
            if kind == "az00/az44" {
                state.pendingGroups[group, default: []].insert(id)
            } else {
                state.pendingGroups[group, default: []].remove(id)
            }
        default:
            throw ContactsScriptingError(number: -1708, message: "not handled: \(kind)")
        }
    }

    /// A resolved element: its class, its id and its person.
    struct Resolved {
        var element: FourCharCode
        var entry: String
        var person: String
    }

    /// Person-level commands of a `failing` card fail (`-10000`).
    private static func refusePerson(_ id: String, _ state: State) throws {
        if state.failing.contains(id) { throw ContactsScriptingError(number: -10000, message: "refused") }
    }

    /// Records an element command of class `element`; throws its configured error.
    private static func receive(_ element: FourCharCode, _ state: inout State) throws {
        state.elementCommands.append(element)
        if let error = state.elementErrors[element] {
            throw ContactsScriptingError(number: error, message: "Apple Event failed")
        }
    }

    /// An existing element: `<element> id E of person id P` → its id.
    private static func resolve(_ spec: Spec, _ state: inout State) throws -> Resolved {
        guard case .element(let element, let entry, .person(let id)) = spec else { throw noSuchObject("element") }
        if state.missingPeople.contains(id) { throw noSuchObject("person id \(id)") }
        try receive(element, &state)
        return Resolved(element: element, entry: entry, person: id)
    }

    /// `make new <element> at end of <elements> of person id P with properties {…}`.
    private static func makeElement(_ event: NSAppleEventDescriptor, _ state: inout State) throws {
        let element = event.paramDescriptor(forKeyword: Self.code("kocl"))?.typeCodeValue ?? 0
        guard let location = event.paramDescriptor(forKeyword: Self.code("insh")),
            let record = location.coerce(toDescriptorType: Self.code("reco")),
            case .every(let want, .person(let id))? = Spec.decode(record.forKeyword(Self.code("kobj"))),
            want == element, record.forKeyword(Self.code("kpos"))?.enumCodeValue == Self.code("end "),
            let card = state.pending[id]
        else { throw noSuchObject("insertion location") }
        if state.missingPeople.contains(id) { throw noSuchObject("person id \(id)") }
        try receive(element, &state)
        var properties: [FourCharCode: NSAppleEventDescriptor] = [:]
        if let record = event.paramDescriptor(forKeyword: Self.code("prdt")), record.numberOfItems > 0 {
            for index in 1...record.numberOfItems {
                properties[record.keywordForDescriptor(at: index)] = record.atIndex(index)
            }
        }
        try make(element, properties, on: card)
    }

    typealias Card = ContactsScriptingEvents.CardCode

    private static func setPerson(_ property: FourCharCode, _ value: String, on card: CNMutableContact) throws {
        let setters: [FourCharCode: ReferenceWritableKeyPath<CNMutableContact, String>] = [
            Card.title: \.namePrefix, Card.firstName: \.givenName, Card.middleName: \.middleName,
            Card.lastName: \.familyName, Card.suffix: \.nameSuffix, Card.nickname: \.nickname,
            Card.maidenName: \.previousFamilyName, Card.organization: \.organizationName,
            Card.department: \.departmentName, Card.jobTitle: \.jobTitle,
            Card.phoneticFirstName: \.phoneticGivenName, Card.phoneticMiddleName: \.phoneticMiddleName,
            Card.phoneticLastName: \.phoneticFamilyName,
        ]
        guard let keyPath = setters[property] else { throw noSuchObject("property \(Self.text(property))") }
        card[keyPath: keyPath] = value
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func setElement(
        _ element: FourCharCode, _ id: String, _ property: FourCharCode, _ value: NSAppleEventDescriptor,
        on card: CNMutableContact
    ) throws {
        let text = value.stringValue ?? ""
        func edit<V>(
            _ list: [CNLabeledValue<V>], _ change: (CNLabeledValue<V>) -> CNLabeledValue<V>?
        ) throws
            -> [CNLabeledValue<V>]
        {
            guard let index = list.firstIndex(where: { $0.identifier == id }) else {
                throw noSuchObject("element id \(id)")
            }
            guard let changed = change(list[index]) else { throw noSuchObject("property") }
            var copy = list
            copy[index] = changed
            return copy
        }
        let isLabel = property == Card.label
        let isValue = property == Card.value
        switch element {
        case Card.email:
            card.emailAddresses = try edit(card.emailAddresses) {
                isLabel ? $0.settingLabel(text) : isValue ? $0.settingValue(text as NSString) : nil
            }
        case Card.url:
            card.urlAddresses = try edit(card.urlAddresses) {
                isLabel ? $0.settingLabel(text) : isValue ? $0.settingValue(text as NSString) : nil
            }
        case Card.phone:
            card.phoneNumbers = try edit(card.phoneNumbers) {
                isLabel ? $0.settingLabel(text) : isValue ? $0.settingValue(CNPhoneNumber(stringValue: text)) : nil
            }
        case Card.relatedName:
            card.contactRelations = try edit(card.contactRelations) {
                isLabel ? $0.settingLabel(text) : isValue ? $0.settingValue(CNContactRelation(name: text)) : nil
            }
        case Card.address:
            card.postalAddresses = try edit(card.postalAddresses) { entry in
                if isLabel { return entry.settingLabel(text) }
                guard let address = entry.value.mutableCopy() as? CNMutablePostalAddress else { return nil }
                switch property {
                case Card.street: address.street = text
                case Card.city: address.city = text
                case Card.state: address.state = text
                case Card.zip: address.postalCode = text
                case Card.country: address.country = text
                case Card.countryCode: address.isoCountryCode = text
                default: return nil
                }
                return entry.settingValue(address)
            }
        case Card.socialProfile:
            card.socialProfiles = try edit(card.socialProfiles) { entry in
                var (url, user, ident, service) = (
                    entry.value.urlString, entry.value.username, entry.value.userIdentifier, entry.value.service
                )
                switch property {
                case Card.profileURL: url = text
                case Card.userName: user = text
                case Card.userIdentifier: ident = text
                case Card.serviceName: service = text
                default: return nil
                }
                return entry.settingValue(
                    CNSocialProfile(urlString: url, username: user, userIdentifier: ident, service: service))
            }
        default:
            throw noSuchObject("element class \(Self.text(element))")
        }
    }

    private static func make(
        _ element: FourCharCode, _ properties: [FourCharCode: NSAppleEventDescriptor], on card: CNMutableContact
    ) throws {
        let text = { (code: FourCharCode) in properties[code]?.stringValue ?? "" }
        let label = properties[Card.label]?.stringValue
        switch element {
        case Card.email: card.emailAddresses.append(CNLabeledValue(label: label, value: text(Card.value) as NSString))
        case Card.url: card.urlAddresses.append(CNLabeledValue(label: label, value: text(Card.value) as NSString))
        case Card.phone:
            card.phoneNumbers.append(CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: text(Card.value))))
        case Card.relatedName:
            card.contactRelations.append(CNLabeledValue(label: label, value: CNContactRelation(name: text(Card.value))))
        case Card.address:
            let address = CNMutablePostalAddress()
            address.street = text(Card.street)
            address.city = text(Card.city)
            address.state = text(Card.state)
            address.postalCode = text(Card.zip)
            address.country = text(Card.country)
            address.isoCountryCode = text(Card.countryCode)
            card.postalAddresses.append(CNLabeledValue(label: label, value: address))
        case Card.socialProfile:
            let profile = CNSocialProfile(
                urlString: properties[Card.profileURL]?.stringValue, username: properties[Card.userName]?.stringValue,
                userIdentifier: properties[Card.userIdentifier]?.stringValue,
                service: properties[Card.serviceName]?.stringValue)
            card.socialProfiles.append(CNLabeledValue(label: nil, value: profile))
        default:
            throw noSuchObject("element class \(Self.text(element))")
        }
    }

    private static func delete(_ element: FourCharCode, _ id: String, on card: CNMutableContact) throws {
        func remove<V>(_ list: [CNLabeledValue<V>]) throws -> [CNLabeledValue<V>] {
            guard list.contains(where: { $0.identifier == id }) else { throw noSuchObject("element id \(id)") }
            return list.filter { $0.identifier != id }
        }
        switch element {
        case Card.email: card.emailAddresses = try remove(card.emailAddresses)
        case Card.url: card.urlAddresses = try remove(card.urlAddresses)
        case Card.phone: card.phoneNumbers = try remove(card.phoneNumbers)
        case Card.relatedName: card.contactRelations = try remove(card.contactRelations)
        case Card.address: card.postalAddresses = try remove(card.postalAddresses)
        case Card.socialProfile: card.socialProfiles = try remove(card.socialProfiles)
        default: throw noSuchObject("element class \(Self.text(element))")
        }
    }
}
