#if os(macOS)
    public import Contacts
    public import Foundation

    /// A value in a Contacts.app scripting command.
    public enum ScriptValue: Hashable, Sendable {
        case text(String)
        /// An enumerator (`instant message service type`).
        case enumerated(FourCharCode)

        var descriptor: NSAppleEventDescriptor {
            switch self {
            case .text(let text): NSAppleEventDescriptor(string: text)
            case .enumerated(let code): NSAppleEventDescriptor(enumCode: code)
            }
        }
    }

    /// One property of a scripting object (a 4CC from Contacts.sdef and a value).
    public struct ScriptProperty: Hashable, Sendable {
        public var code: FourCharCode
        public var value: ScriptValue

        /// Creates a property.
        public init(_ code: FourCharCode, _ value: ScriptValue) {
            self.code = code
            self.value = value
        }
    }

    /// How to find a labeled value Contacts.app does not resolve by `id`
    /// (instant messages, spike S16): `first <element> whose` every term
    /// equals its value — the element's values before the write, updated as
    /// commands change them.
    public struct ElementMatch: Hashable, Sendable {
        public var element: FourCharCode
        public var terms: [ScriptProperty]

        /// Creates a match.
        public init(element: FourCharCode, terms: [ScriptProperty]) {
            self.element = element
            self.terms = terms
        }

        /// The match after `property` was set on the element.
        func updating(_ property: ScriptProperty) -> ElementMatch {
            var copy = self
            copy.terms = terms.map { $0.code == property.code ? property : $0 }
            return copy
        }

        /// `first <element> of person id P whose …`.
        func specifier(person cardID: String) -> NSAppleEventDescriptor {
            ContactsScriptingEvents.firstElement(
                element, ofPerson: cardID, whose: terms.map { ($0.code, $0.value.descriptor) })
        }
    }

    /// One Contacts.app scripting command on one person (card).
    public enum ScriptCommand: Hashable, Sendable {
        /// `set <property> of person id P to V`.
        case setPerson(FourCharCode, String)
        /// `set <property> of <element> id E of person id P to V` (edits in place: the id stays).
        case setElement(FourCharCode, id: String, property: ScriptProperty)
        /// `make new <element> at end of … of person id P with properties {…}`.
        case make(FourCharCode, properties: [ScriptProperty])
        /// `delete <element> id E of person id P`.
        case delete(FourCharCode, id: String)
        /// `add person id P to group id G`.
        case addToGroup(String)
        /// `remove person id P from group id G`.
        case removeFromGroup(String)

        /// The Apple Event for this command on person `cardID`.
        public func event(person cardID: String) -> NSAppleEventDescriptor {
            typealias Events = ContactsScriptingEvents
            switch self {
            case .setPerson(let property, let text):
                return Events.set(
                    Events.property(property, of: Events.person(id: cardID)),
                    toDescriptor: NSAppleEventDescriptor(string: text))
            case .setElement(let element, let id, let property):
                return Events.set(
                    Events.property(property.code, of: Events.element(element, id: id, ofPerson: cardID)),
                    toDescriptor: property.value.descriptor)
            case .make(let element, let properties):
                return Events.make(
                    element, ofPerson: cardID, properties: properties.map { ($0.code, $0.value.descriptor) })
            case .delete(let element, let id):
                return Events.delete(Events.element(element, id: id, ofPerson: cardID))
            case .addToGroup(let group):
                return Events.add(person: cardID, toGroup: group)
            case .removeFromGroup(let group):
                return Events.remove(person: cardID, fromGroup: group)
            }
        }

        /// The same command on the element `match` finds instead of `<element> id E`
        /// (`nil` for commands that do not address an existing element).
        public func event(person cardID: String, matching match: ElementMatch) -> NSAppleEventDescriptor? {
            typealias Events = ContactsScriptingEvents
            switch self {
            case .setElement(_, _, let property):
                return Events.set(
                    Events.property(property.code, of: match.specifier(person: cardID)),
                    toDescriptor: property.value.descriptor)
            case .delete:
                return Events.delete(match.specifier(person: cardID))
            default:
                return nil
            }
        }

        /// The existing element this command addresses by id (`set … of <element> id E`, `delete`).
        public var target: (element: FourCharCode, id: String)? {
            switch self {
            case .setElement(let element, let id, _), .delete(let element, let id): (element, id)
            default: nil
            }
        }

        /// `true` for commands that change the card's own fields (not groups).
        var changesFields: Bool {
            switch self {
            case .addToGroup, .removeFromGroup: false
            default: true
            }
        }
    }

    /// The scripting commands that turn one card (`before`) into `after`,
    /// both as the Contacts framework sees them (architecture §6 "Write
    /// routing"). The writer computes `after` with the same `CardWriter`
    /// edits the Contacts-framework path uses, so both routes make the same
    /// change:
    ///
    /// - Single-valued fields that differ are set (`""` clears).
    /// - Labeled values are matched by `CNLabeledValue.identifier`, which is
    ///   Contacts.app's element `id` (spike S15): gone → `delete … id`, kept
    ///   with a different value or label → `set … of … id` (the id stays), new
    ///   → `make new … at end`. A label is only sent when it changed or the
    ///   value is new; it is sent as the raw Contacts label (`_$!<Mobile>!$_`,
    ///   `Summer House`), which is what `CNLabeledValue.label` holds.
    /// - Order is not kept: new values go to the end.
    ///
    /// Not expressible (reported in `unsupported`): an instant-message
    /// service Contacts.app has no `service type` for.
    ///
    /// Instant messages: Contacts.app answers `-1728` for `instant message id
    /// E` (spike S16), so `matches` also gives each existing IM a `whose`
    /// form (`user name` + `service type`, the values before the write) for
    /// the writer to fall back to. An IM whose user name and service another
    /// IM of the card shares gets none (`first … whose` could pick the other).
    public struct ScriptedCardPlan: Hashable, Sendable {
        public var commands: [ScriptCommand] = []
        /// Fields with a change scripting cannot express (`im`).
        public var unsupported: Set<String> = []
        /// `whose` forms of existing elements, by element id (instant messages only).
        public var matches: [String: ElementMatch] = [:]

        /// The commands from `before` to `after`.
        public init(before: CNContact, after: CNContact) {
            scalars(before: before, after: after)
            typealias Code = ContactsScriptingEvents.CardCode
            list(Code.email, before.emailAddresses, after.emailAddresses) {
                [ScriptProperty(Code.value, .text($0 as String))]
            }
            list(Code.phone, before.phoneNumbers, after.phoneNumbers) {
                [ScriptProperty(Code.value, .text($0.stringValue))]
            }
            list(Code.url, before.urlAddresses, after.urlAddresses) {
                [ScriptProperty(Code.value, .text($0 as String))]
            }
            list(Code.relatedName, before.contactRelations, after.contactRelations) {
                [ScriptProperty(Code.value, .text($0.name))]
            }
            list(Code.address, before.postalAddresses, after.postalAddresses, properties: Self.address)
            list(
                Code.socialProfile, before.socialProfiles, after.socialProfiles, labeled: false, properties: Self.social
            )
            list(Code.instantMessage, before.instantMessageAddresses, after.instantMessageAddresses, field: "im") {
                Self.instantMessage($0)
            }
            matches = Self.instantMessageMatches(before.instantMessageAddresses)
        }

        /// The `whose` form of each IM in `ims` that it identifies uniquely.
        static func instantMessageMatches(_ ims: [CNLabeledValue<CNInstantMessageAddress>]) -> [String: ElementMatch] {
            let forms = ims.compactMap { entry in instantMessage(entry.value).map { (entry.identifier, $0) } }
            var counts: [[ScriptProperty]: Int] = [:]
            for (_, terms) in forms { counts[terms, default: 0] += 1 }
            var matches: [String: ElementMatch] = [:]
            for (id, terms) in forms where counts[terms] == 1 {
                matches[id] = ElementMatch(element: ContactsScriptingEvents.CardCode.instantMessage, terms: terms)
            }
            return matches
        }

        // MARK: Single-valued fields

        /// Person properties and their Contacts-framework values.
        static var scalarProperties: [(FourCharCode, (CNContact) -> String)] {
            typealias Code = ContactsScriptingEvents.CardCode
            return [
                (Code.title, \.namePrefix), (Code.firstName, \.givenName), (Code.middleName, \.middleName),
                (Code.lastName, \.familyName), (Code.suffix, \.nameSuffix), (Code.nickname, \.nickname),
                (Code.maidenName, \.previousFamilyName), (Code.organization, \.organizationName),
                (Code.department, \.departmentName), (Code.jobTitle, \.jobTitle),
                (Code.phoneticFirstName, \.phoneticGivenName), (Code.phoneticMiddleName, \.phoneticMiddleName),
                (Code.phoneticLastName, \.phoneticFamilyName),
            ]
        }

        private mutating func scalars(before: CNContact, after: CNContact) {
            for (code, value) in Self.scalarProperties where value(before) != value(after) {
                commands.append(.setPerson(code, value(after)))
            }
        }

        // MARK: Labeled values

        /// Adds the commands for one labeled-value list. `properties` is the
        /// scripting form of a value (`nil`: not expressible); unlabeled
        /// classes (`social profile` has no `label`) never send one.
        private mutating func list<Value>(
            _ element: FourCharCode, _ before: [CNLabeledValue<Value>], _ after: [CNLabeledValue<Value>],
            labeled: Bool = true, field: String? = nil, properties: (Value) -> [ScriptProperty]?
        ) where Value: NSObject {
            let label = ContactsScriptingEvents.CardCode.label
            let afterIDs = Set(after.map(\.identifier))
            let old = Dictionary(before.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            for entry in before where !afterIDs.contains(entry.identifier) {
                commands.append(.delete(element, id: entry.identifier))
            }
            for entry in after {
                guard let wanted = properties(entry.value) else {
                    if old[entry.identifier].map({ !Self.same($0, entry) }) ?? true {
                        unsupported.insert(field ?? "\(element)")
                    }
                    continue
                }
                guard let original = old[entry.identifier] else {
                    var initial = wanted.filter { if case .text(let text) = $0.value { !text.isEmpty } else { true } }
                    if labeled, let text = entry.label { initial.insert(ScriptProperty(label, .text(text)), at: 0) }
                    commands.append(.make(element, properties: initial))
                    continue
                }
                if labeled, original.label != entry.label {
                    commands.append(
                        .setElement(
                            element, id: entry.identifier, property: ScriptProperty(label, .text(entry.label ?? ""))))
                }
                let current = properties(original.value) ?? []
                for property in wanted where !current.contains(property) {
                    commands.append(.setElement(element, id: entry.identifier, property: property))
                }
            }
        }

        private static func same<Value: NSObject>(_ lhs: CNLabeledValue<Value>, _ rhs: CNLabeledValue<Value>) -> Bool {
            lhs.label == rhs.label && lhs.value.isEqual(rhs.value)
        }

        static func address(_ address: CNPostalAddress) -> [ScriptProperty] {
            typealias Code = ContactsScriptingEvents.CardCode
            return [
                ScriptProperty(Code.street, .text(address.street)), ScriptProperty(Code.city, .text(address.city)),
                ScriptProperty(Code.state, .text(address.state)), ScriptProperty(Code.zip, .text(address.postalCode)),
                ScriptProperty(Code.country, .text(address.country)),
                ScriptProperty(Code.countryCode, .text(address.isoCountryCode)),
            ]
        }

        static func social(_ profile: CNSocialProfile) -> [ScriptProperty] {
            typealias Code = ContactsScriptingEvents.CardCode
            return [
                ScriptProperty(Code.serviceName, .text(profile.service)),
                ScriptProperty(Code.userName, .text(profile.username)),
                ScriptProperty(Code.profileURL, .text(profile.urlString)),
                ScriptProperty(Code.userIdentifier, .text(profile.userIdentifier)),
            ]
        }

        /// `service type` + `user name`; `nil` for a service Contacts.app has no enumerator for.
        static func instantMessage(_ address: CNInstantMessageAddress) -> [ScriptProperty]? {
            typealias Code = ContactsScriptingEvents.CardCode
            guard let type = serviceTypes[address.service] else { return nil }
            return [
                ScriptProperty(Code.serviceType, .enumerated(type)),
                ScriptProperty(Code.userName, .text(address.username)),
            ]
        }

        /// Contacts framework IM services → `instant message service type` enumerators.
        static let serviceTypes: [String: FourCharCode] = {
            typealias Code = ContactsScriptingEvents.CardCode
            return [
                CNInstantMessageServiceAIM: Code.serviceAIM, CNInstantMessageServiceFacebook: Code.serviceFacebook,
                CNInstantMessageServiceGaduGadu: Code.serviceGaduGadu,
                CNInstantMessageServiceGoogleTalk: Code.serviceGoogleTalk, CNInstantMessageServiceICQ: Code.serviceICQ,
                CNInstantMessageServiceJabber: Code.serviceJabber, CNInstantMessageServiceMSN: Code.serviceMSN,
                CNInstantMessageServiceQQ: Code.serviceQQ, CNInstantMessageServiceSkype: Code.serviceSkype,
                CNInstantMessageServiceYahoo: Code.serviceYahoo,
            ]
        }()
    }
#endif
