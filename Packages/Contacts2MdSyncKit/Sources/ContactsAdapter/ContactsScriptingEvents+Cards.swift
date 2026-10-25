#if os(macOS)
    public import Foundation

    /// Apple Events for card writes through Contacts.app (architecture §6
    /// "Write routing", spike S15): the events AppleScript sends for
    ///
    /// - `set <property> of person id P to V`
    /// - `set <property> of <element> id E of person id P to V`
    /// - `make new <element> at end of <elements> of person id P with properties {…}`
    /// - `delete <element> id E of person id P`
    /// - `add person id P to group id G` / `remove person id P from group id G`
    ///
    /// Codes from `sdef /System/Applications/Contacts.app`. Every id and value
    /// is a descriptor; nothing is spliced into script source.
    extension ContactsScriptingEvents {
        /// Contacts.sdef codes for card writes.
        public enum CardCode {
            // Classes (elements of `person`).
            public static let email = fourCC("az21")
            public static let phone = fourCC("az20")
            public static let url = fourCC("az70")
            public static let address = fourCC("az27")
            public static let customDate = fourCC("az52")
            public static let relatedName = fourCC("az53")
            public static let socialProfile = fourCC("sp01")
            public static let instantMessage = fourCC("az80")
            public static let group = fourCC("azf5")

            // `contact info` (email, phone, url, related name, custom date, instant message).
            public static let label = fourCC("az18")
            public static let value = fourCC("az17")

            // `person` properties.
            public static let firstName = fourCC("azf7")
            public static let lastName = fourCC("azf8")
            public static let middleName = fourCC("az40")
            /// `title` is the name prefix (Dr., Ms.).
            public static let title = fourCC("az39")
            public static let suffix = fourCC("az41")
            public static let nickname = fourCC("az43")
            /// `maiden name` is `CNContact.previousFamilyName`.
            public static let maidenName = fourCC("az42")
            public static let organization = fourCC("az38")
            public static let department = fourCC("az55")
            public static let jobTitle = fourCC("az12")
            public static let phoneticFirstName = fourCC("azf9")
            public static let phoneticMiddleName = fourCC("az56")
            public static let phoneticLastName = fourCC("az10")

            // `address` properties.
            public static let street = fourCC("az28")
            public static let city = fourCC("az29")
            public static let state = fourCC("az30")
            public static let zip = fourCC("az31")
            public static let country = fourCC("az32")
            public static let countryCode = fourCC("az33")

            // `social profile` properties.
            public static let serviceName = fourCC("az81")
            public static let userName = fourCC("az83")
            public static let userIdentifier = fourCC("spid")
            public static let profileURL = fourCC("spur")

            // Events and keywords.
            static let make = fourCC("crel")
            static let delete = fourCC("delo")
            static let contactsSuite = fourCC("az00")
            static let add = fourCC("az44")
            static let addTo = fourCC("az45")
            static let remove = fourCC("az46")
            static let removeFrom = fourCC("az47")
            static let insertHere = fourCC("insh")
            static let properties = fourCC("prdt")
            static let insertionLocation = fourCC("insl")
            static let insertionObject = fourCC("kobj")
            static let insertionPosition = fourCC("kpos")
            static let end = fourCC("end ")

        }

        // MARK: - Specifiers

        /// `<element class> id "E" of person id "P"`.
        public static func element(_ code: FourCharCode, id: String, ofPerson person: String) -> NSAppleEventDescriptor
        {
            specifier(
                want: code, form: Code.formUniqueID, data: NSAppleEventDescriptor(string: id),
                from: self.person(id: person))
        }

        /// `every <element class> of person id "P"`.
        public static func every(_ code: FourCharCode, ofPerson person: String) -> NSAppleEventDescriptor {
            var all = Code.all
            let ordinal = NSAppleEventDescriptor(
                descriptorType: Code.absoluteOrdinal, bytes: &all, length: MemoryLayout<FourCharCode>.size)
            return specifier(
                want: code, form: Code.formAbsolutePosition, data: ordinal ?? .null(), from: self.person(id: person))
        }

        /// `get id of person id "P"` (does Contacts.app resolve the person?).
        public static func personID(_ person: String) -> NSAppleEventDescriptor {
            get(property(Code.id, of: self.person(id: person)))
        }

        /// `group id "G"`.
        public static func group(id: String) -> NSAppleEventDescriptor {
            specifier(
                want: CardCode.group, form: Code.formUniqueID, data: NSAppleEventDescriptor(string: id), from: nil)
        }

        /// `end of <container>` (an insertion location).
        static func end(of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(container, forKeyword: CardCode.insertionObject)
            record.setDescriptor(NSAppleEventDescriptor(enumCode: CardCode.end), forKeyword: CardCode.insertionPosition)
            return record.coerce(toDescriptorType: CardCode.insertionLocation) ?? record
        }

        // MARK: - Events

        /// `set <specifier> to <value>` for any descriptor value.
        public static func set(
            _ specifier: NSAppleEventDescriptor, toDescriptor value: NSAppleEventDescriptor
        ) -> NSAppleEventDescriptor {
            let event = appleEvent(Code.coreSuite, Code.setData)
            event.setParam(specifier, forKeyword: Code.directObject)
            event.setParam(value, forKeyword: Code.data)
            return event
        }

        /// `make new <class> at end of <class plural> of person id P with properties {…}`.
        public static func make(
            _ code: FourCharCode, ofPerson person: String, properties: [(FourCharCode, NSAppleEventDescriptor)]
        ) -> NSAppleEventDescriptor {
            let event = appleEvent(Code.coreSuite, CardCode.make)
            event.setParam(NSAppleEventDescriptor(typeCode: code), forKeyword: Code.objectClass)
            event.setParam(end(of: every(code, ofPerson: person)), forKeyword: CardCode.insertHere)
            let record = NSAppleEventDescriptor.record()
            for (key, value) in properties { record.setDescriptor(value, forKeyword: key) }
            event.setParam(record, forKeyword: CardCode.properties)
            return event
        }

        /// `delete <specifier>`.
        public static func delete(_ specifier: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let event = appleEvent(Code.coreSuite, CardCode.delete)
            event.setParam(specifier, forKeyword: Code.directObject)
            return event
        }

        /// `add person id P to group id G`.
        public static func add(person: String, toGroup group: String) -> NSAppleEventDescriptor {
            let event = appleEvent(CardCode.contactsSuite, CardCode.add)
            event.setParam(self.person(id: person), forKeyword: Code.directObject)
            event.setParam(self.group(id: group), forKeyword: CardCode.addTo)
            return event
        }

        /// `remove person id P from group id G`.
        public static func remove(person: String, fromGroup group: String) -> NSAppleEventDescriptor {
            let event = appleEvent(CardCode.contactsSuite, CardCode.remove)
            event.setParam(self.person(id: person), forKeyword: Code.directObject)
            event.setParam(self.group(id: group), forKeyword: CardCode.removeFrom)
            return event
        }

        static func appleEvent(_ eventClass: FourCharCode, _ eventID: FourCharCode) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor.appleEvent(
                withEventClass: eventClass, eventID: eventID, targetDescriptor: target(),
                returnID: AEReturnID(-1),  // kAutoGenerateReturnID
                transactionID: AETransactionID(0))  // kAnyTransactionID
        }
    }
#endif
