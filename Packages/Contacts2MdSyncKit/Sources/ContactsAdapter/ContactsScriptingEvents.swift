#if os(macOS)
    public import Foundation

    /// An Apple Event error from Contacts.app or the Apple Event Manager,
    /// with its OSStatus / AppleScript error number.
    public struct ContactsScriptingError: Error, Hashable, Sendable, CustomStringConvertible {
        public var number: Int
        public var message: String

        /// Creates an error.
        public init(number: Int, message: String) {
            self.number = number
            self.message = message
        }

        public var description: String { "Contacts.app scripting error \(number): \(message)" }

        /// `-1743` errAEEventNotPermitted: Automation was refused.
        public var isPermissionDenied: Bool { number == -1743 }
        /// `-1744` errAEEventWouldRequireUserConsent: never asked yet.
        public var needsConsent: Bool { number == -1744 }
        /// `-1728` errAENoSuchObject: e.g. `person id X` does not resolve.
        public var isNoSuchObject: Bool { number == -1728 }

        /// Errors that concern the whole session (permission, Contacts.app not
        /// reachable, timeouts), not one card. Anything else is per card.
        public var isSessionLevel: Bool {
            // -600 procNotFound, -609 connectionInvalid, -1712 errAETimeout,
            // -1708 errAEEventNotHandled (app not ready), -1743/-1744 permission.
            [-600, -609, -1712, -1708, -1743, -1744, -903].contains(number)
        }
    }

    /// Builds the Apple Events that read and write Contacts.app notes, and
    /// parses their replies (architecture §8, spike S12).
    ///
    /// Raw Apple Events with object specifiers, the same events AppleScript
    /// sends for `get note of every person`, `set note of person id X to T`
    /// and `save`. Arguments are descriptors, never spliced into script source,
    /// and unlike `NSAppleScript` this works from any thread. Codes from
    /// `Contacts.app/Contents/Resources/Contacts.sdef`: class `person` =
    /// `azf4`, property `note` = `az37`, property `id` = `ID  `, command `save`
    /// = `core`/`save`.
    public enum ContactsScriptingEvents {
        /// Contacts.app.
        public static let bundleID = "com.apple.AddressBook"

        /// Four-character codes used here.
        public enum Code {
            public static let person = fourCC("azf4")
            public static let note = fourCC("az37")
            public static let id = fourCC("ID  ")

            static let coreSuite = fourCC("core")
            static let getData = fourCC("getd")
            static let setData = fourCC("setd")
            static let save = fourCC("save")
            static let countElements = fourCC("cnte")
            static let directObject = fourCC("----")
            static let data = fourCC("data")
            static let objectClass = fourCC("kocl")
            static let property = fourCC("prop")
            static let formPropertyID = fourCC("prop")
            static let formAbsolutePosition = fourCC("indx")
            static let formUniqueID = fourCC("ID  ")
            static let absoluteOrdinal = fourCC("abso")
            static let all = fourCC("all ")
            static let objectSpecifier = fourCC("obj ")
            static let desiredClass = fourCC("want")
            static let keyForm = fourCC("form")
            static let keyData = fourCC("seld")
            static let container = fourCC("from")
            static let errorNumber = fourCC("errn")
            static let errorString = fourCC("errs")
            static let type = fourCC("type")
            static let enumerated = fourCC("enum")
            static let list = fourCC("list")
            static let null = fourCC("null")
        }

        /// `"azf4"` → its `FourCharCode`.
        public static func fourCC(_ code: String) -> FourCharCode {
            code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
        }

        // MARK: - Object specifiers

        /// `every person`.
        public static func everyPerson() -> NSAppleEventDescriptor {
            var all = Code.all
            let ordinal = NSAppleEventDescriptor(
                descriptorType: Code.absoluteOrdinal, bytes: &all, length: MemoryLayout<FourCharCode>.size)
            return specifier(want: Code.person, form: Code.formAbsolutePosition, data: ordinal ?? .null(), from: nil)
        }

        /// `person id "<card id>"` (Contacts.app's person id is the CNContact card id).
        public static func person(id: String) -> NSAppleEventDescriptor {
            specifier(want: Code.person, form: Code.formUniqueID, data: NSAppleEventDescriptor(string: id), from: nil)
        }

        /// `<property> of <container>`.
        public static func property(
            _ code: FourCharCode, of container: NSAppleEventDescriptor
        ) -> NSAppleEventDescriptor {
            specifier(
                want: Code.property, form: Code.formPropertyID, data: NSAppleEventDescriptor(typeCode: code),
                from: container)
        }

        /// An object specifier record (`want`, `form`, `seld`, `from`).
        static func specifier(
            want: FourCharCode, form: FourCharCode, data: NSAppleEventDescriptor,
            from container: NSAppleEventDescriptor?
        ) -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: Code.desiredClass)
            record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: Code.keyForm)
            record.setDescriptor(data, forKeyword: Code.keyData)
            record.setDescriptor(container ?? .null(), forKeyword: Code.container)
            return record.coerce(toDescriptorType: Code.objectSpecifier) ?? record
        }

        // MARK: - Events

        /// The target: Contacts.app by bundle id.
        public static func target() -> NSAppleEventDescriptor {
            NSAppleEventDescriptor(bundleIdentifier: bundleID)
        }

        private static func event(_ eventID: FourCharCode) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor.appleEvent(
                withEventClass: Code.coreSuite, eventID: eventID, targetDescriptor: target(),
                returnID: AEReturnID(-1),  // kAutoGenerateReturnID
                transactionID: AETransactionID(0))  // kAnyTransactionID
        }

        /// `get <specifier>`.
        public static func get(_ specifier: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let event = event(Code.getData)
            event.setParam(specifier, forKeyword: Code.directObject)
            return event
        }

        /// `set <specifier> to <text>`.
        public static func set(_ specifier: NSAppleEventDescriptor, to text: String) -> NSAppleEventDescriptor {
            let event = event(Code.setData)
            event.setParam(specifier, forKeyword: Code.directObject)
            event.setParam(NSAppleEventDescriptor(string: text), forKeyword: Code.data)
            return event
        }

        /// `save` (Contacts.app commits pending changes).
        public static func save() -> NSAppleEventDescriptor { event(Code.save) }

        /// `count every person` (a cheap readiness probe).
        public static func countPeople() -> NSAppleEventDescriptor {
            let event = event(Code.countElements)
            event.setParam(.null(), forKeyword: Code.directObject)
            event.setParam(NSAppleEventDescriptor(typeCode: Code.person), forKeyword: Code.objectClass)
            return event
        }

        /// `id of every person`.
        public static func idsOfEveryPerson() -> NSAppleEventDescriptor { get(property(Code.id, of: everyPerson())) }

        /// `note of every person`.
        public static func notesOfEveryPerson() -> NSAppleEventDescriptor {
            get(property(Code.note, of: everyPerson()))
        }

        /// `note of person id X`.
        public static func note(ofPerson id: String) -> NSAppleEventDescriptor {
            get(property(Code.note, of: person(id: id)))
        }

        /// `set note of person id X to T`.
        public static func setNote(ofPerson id: String, to text: String) -> NSAppleEventDescriptor {
            set(property(Code.note, of: person(id: id)), to: text)
        }

        // MARK: - Replies

        /// The direct result of a reply, or the error it carries.
        public static func result(of reply: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
            if let number = reply.paramDescriptor(forKeyword: Code.errorNumber)?.int32Value, number != 0 {
                let message = reply.paramDescriptor(forKeyword: Code.errorString)?.stringValue ?? "Apple Event failed"
                throw ContactsScriptingError(number: Int(number), message: message)
            }
            return reply.paramDescriptor(forKeyword: Code.directObject)
        }

        /// Text, or `nil` for `missing value` (and any other non-text value).
        public static func optionalString(_ descriptor: NSAppleEventDescriptor?) -> String? {
            guard let descriptor else { return nil }
            if [Code.type, Code.enumerated, Code.null].contains(descriptor.descriptorType) { return nil }
            return descriptor.stringValue
        }

        /// The items of a list reply (a single value is a one-item list).
        public static func optionalStrings(_ descriptor: NSAppleEventDescriptor?) -> [String?] {
            guard let descriptor else { return [] }
            guard descriptor.descriptorType == Code.list else { return [optionalString(descriptor)] }
            guard descriptor.numberOfItems > 0 else { return [] }
            return (1...descriptor.numberOfItems).map { optionalString(descriptor.atIndex($0)) }
        }
    }
#endif
