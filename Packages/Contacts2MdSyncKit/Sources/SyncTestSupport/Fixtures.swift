public import ContactModel
public import Foundation

/// The standard fixture address book: ~60 contacts covering the edge cases
/// the exporter must handle (see `Fixtures.contacts`). Shared by golden-file
/// tests, round-trip tests and the mbr validation check.
public enum Fixtures {
    public static let iCloud = AppleContainer(id: "icloud", name: "iCloud", kind: .iCloud, isDefault: true)
    public static let google = AppleContainer(id: "google", name: "Google", kind: .google)
    public static let local = AppleContainer(id: "local", name: "On My Mac", kind: .local)
    public static let containers = [iCloud, google, local]

    public static let family = AppleGroup(id: "g-family", name: "Family", containerID: "icloud")
    public static let closeFriends = AppleGroup(id: "g-close", name: "Close Friends", containerID: "icloud")
    public static let work = AppleGroup(id: "g-work", name: "Work", containerID: "icloud")
    public static let groups = [family, closeFriends, work]

    /// A tiny JPEG-looking blob (header bytes are what the exporter sniffs).
    public static let jpegBytes = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xFF, 0xD9,
    ])
    /// A tiny PNG-looking blob.
    public static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    /// Stamp already present on "Stella Stamped" (exported earlier on another device).
    public static let stellaID = UUID(uuidString: "5fe1a1d0-0000-4000-8000-00000000057e") ?? UUID()

    /// A store holding the standard fixtures.
    public static func store(notesEntitled: Bool = true) -> FakeContactStore {
        FakeContactStore(contacts: contacts(), containers: containers, groups: groups, notesEntitled: notesEntitled)
    }

    // MARK: - Builders

    /// One unified contact. `accounts` lists its cards (first = unified id).
    public static func contact(
        _ id: String,
        kind: ContactKind = .person,
        accounts: [AccountKind] = [.iCloud],
        groups: [AppleGroup] = [],
        image: Data? = nil,
        stamp: UUID? = nil,
        _ build: (inout CanonicalContact) -> Void
    ) -> AppleContact {
        var canonical = CanonicalContact(kind: kind, title: "")
        build(&canonical)
        let cards = accounts.enumerated().map { offset, kind in
            AppleCard(
                id: "\(id):\(kind.rawValue)",
                containerID: containers.first { $0.kind == kind }?.id ?? kind.rawValue,
                accountKind: kind,
                stampID: offset == 0 ? stamp : nil
            )
        }
        return AppleContact(
            unifiedID: cards[0].id, cards: cards, contact: canonical, imageData: image, groupIDs: groups.map(\.id))
    }

    private static func person(
        _ id: String, _ given: String?, _ family: String?, accounts: [AccountKind] = [.iCloud],
        groups: [AppleGroup] = [], image: Data? = nil, stamp: UUID? = nil,
        _ build: (inout CanonicalContact) -> Void = { _ in }
    ) -> AppleContact {
        contact(id, accounts: accounts, groups: groups, image: image, stamp: stamp) { contact in
            contact.name = PersonName(given: given, family: family)
            build(&contact)
        }
    }

    private static func org(
        _ id: String, _ name: String, _ build: (inout CanonicalContact) -> Void = { _ in }
    )
        -> AppleContact
    {
        contact(id, kind: .organization) { contact in
            contact.company = .plain(name)
            build(&contact)
        }
    }

    private static func related(_ type: String, _ name: String, label: String? = nil) -> RelationshipRef {
        RelationshipRef(type: type, label: label, target: .name(name))
    }

    // MARK: - The address book

    // swiftlint:disable function_body_length
    /// The fixtures, each covering at least one edge case (noted inline).
    public static func contacts() -> [AppleContact] {
        [
            // c01: the markdown-schema §1 example, nearly every field.
            person("c01", "Jane", "Doe", groups: [family, closeFriends], image: jpegBytes) {
                $0.name = PersonName(prefix: "Dr.", given: "Jane", middle: "Quinn", family: "Doe")
                $0.aliases = [.nickname("JJ"), .maidenName("Jane Smith")]
                $0.company = .plain("Acme Corp")
                $0.department = "R&D"
                $0.jobTitle = "CTO"
                $0.emails = [Labeled("work", "jane@acme.com"), Labeled("home", "jane@example.com")]
                $0.phones = [Labeled("mobile", "+1 415 555 0100"), Labeled("work", "(415) 555-0199")]
                $0.urls = [Labeled("homepage", "https://janedoe.example")]
                $0.social = [Labeled("linkedin", SocialHandle("https://www.linkedin.com/in/janedoe"))]
                $0.im = [Labeled("signal", IMHandle("+1 415 555 0100"))]
                $0.addresses = [
                    Labeled(
                        "home",
                        PostalAddress(
                            street: "1 Main St", city: "Springfield", region: "IL", postcode: "62701", country: "USA",
                            countryCode: "US"))
                ]
                $0.dates = [
                    Labeled("birthday", .full(year: 1980, month: 3, day: 19)),
                    Labeled("anniversary", .monthDay(month: 6, day: 10)),
                ]
                $0.relationships = [related("spouse", "John Doe"), related("parent", "Bob Smith", label: "father")]
                $0.apple = AppleExtras(phoneticFamily: "ドウ")
                $0.body = "Met at the **2019** conference.\n\n- likes tea\n"
            },
            // c02: reverse relation label (wife), Family group.
            person("c02", "John", "Doe", groups: [family]) {
                $0.relationships = [related("spouse", "Jane Doe", label: "wife")]
                $0.phones = [Labeled("iphone", "415-555-0123")]
            },
            // c03: parent, year-less birthday.
            person("c03", "Bob", "Smith", groups: [family]) {
                $0.dates = [Labeled("birthday", .monthDay(month: 12, day: 25))]
                $0.relationships = [related("child", "Jane Doe", label: "daughter")]
            },
            // c04: organization contact (company wikilinks resolve to it).
            org("c04", "Acme Corp") {
                $0.phones = [Labeled("main", "+1 800 555 0000")]
                $0.urls = [Labeled("homepage", "https://acme.example/")]
                $0.apple = AppleExtras(phoneticOrganization: "アクメ")
            },
            // c05: CJK name → family+given title.
            person("c05", "太郎", "山田") { $0.emails = [Labeled("home", "taro@example.jp")] },
            // c06: diacritics.
            person("c06", "José", "Álvarez") { $0.phones = [Labeled("mobile", "+34 612 345 678")] },
            // c07: apostrophe + diaeresis.
            person("c07", "Zoë", "O'Brien"),
            // c08: Icelandic letters.
            person("c08", "Ægir", "Þórsson"),
            // c09: family name only.
            person("c09", nil, "Müller"),
            // c10: given name only.
            person("c10", "Cher", nil),
            // c11: organization only.
            org("c11", "Globex") { $0.emails = [Labeled("work", "info@globex.example")] },
            // c12: person record with no name, only an organization.
            contact("c12") { $0.company = .plain("Initech") },
            // c13: email only.
            contact("c13") { $0.emails = [Labeled(nil, "mystery@example.com")] },
            // c14: nothing at all.
            contact("c14") { _ in },
            // c15: YAML-trap first name "Yes".
            person("c15", "Yes", nil),
            // c16: YAML-trap words everywhere.
            person("c16", "No", "On") {
                $0.jobTitle = "null"
                $0.department = "~"
                $0.company = .plain("False")
                $0.aliases = [.nickname("off")]
            },
            // c17: leading zero phone, postcode with leading zero.
            person("c17", "Zero", "Lead") {
                $0.phones = [Labeled("home", "0123 456 789")]
                $0.addresses = [
                    Labeled("home", PostalAddress(street: "12 Elm St", city: "Boston", region: "MA", postcode: "02134"))
                ]
            },
            // c18: date-looking and number-looking text values.
            person("c18", "Date", "Looking") {
                $0.department = "1980-03-19"
                $0.jobTitle = "42"
                $0.aliases = [.nickname("3.14")]
            },
            // c19: @handle social (username, no URL) and IM.
            person("c19", "Handle", "Person") {
                $0.social = [Labeled("twitter", SocialHandle("@handle"))]
                $0.im = [Labeled("skype", IMHandle("handle.person"))]
            },
            // c20: colons and hashes.
            person("c20", "Colon", "Hash") {
                $0.jobTitle = "CEO: Special Projects"
                $0.aliases = [.nickname("#1 Fan")]
                $0.department = "R&D # internal"
                $0.urls = [Labeled("work", "https://example.com/a:b#frag")]
            },
            // c21: leading indicator characters.
            person("c21", "Indicator", "Chars") {
                $0.aliases = [.nickname("[draft]")]
                $0.jobTitle = "*star* & !bang"
                $0.department = "%percent"
            },
            // c22: multi-line street.
            person("c22", "Multi", "Line") {
                $0.addresses = [
                    Labeled(
                        "work",
                        PostalAddress(
                            street: "1 Main St\nApt 4B", city: "Portland", region: "OR", postcode: "97201",
                            country: "USA", countryCode: "us"))
                ]
            },
            // c23: custom labels.
            person("c23", "Custom", "Labels") {
                $0.emails = [Labeled("summer_house", "summer@example.com")]
                $0.phones = [Labeled("grandma_s", "+1 212 555 0101")]
                $0.addresses = [Labeled("beach_cabin", PostalAddress(city: "Malibu", region: "CA"))]
            },
            // c24 / c25: duplicate name, different people (no shared keys,
            // different organizations: equal names alone would cluster).
            person("c24", "John", "Smith") {
                $0.company = .plain("Initech")
                $0.emails = [Labeled("home", "john.smith@example.com")]
            },
            person("c25", "John", "Smith") {
                $0.company = .plain("Globex")
                $0.emails = [Labeled("work", "jsmith@globex.example")]
            },
            // c26 / c27: unlinked iCloud + Google duplicate pair (same email).
            person("c26", "Chris", "Martin") {
                $0.emails = [Labeled("home", "chris@example.com")]
                $0.phones = [Labeled("mobile", "+1 303 555 0142")]
            },
            person("c27", "Chris", "Martin", accounts: [.google]) {
                $0.emails = [Labeled("home", "Chris@Example.com")]
                $0.phones = [Labeled("mobile", "(303) 555-0142")]
            },
            // c28: one unified contact linked across iCloud and Google.
            person("c28", "Sam", "Lee", accounts: [.iCloud, .google]) {
                $0.emails = [Labeled("work", "sam@example.com"), Labeled("home", "sam.lee@gmail.example")]
            },
            // c29: Google-only contact.
            person("c29", "Pat", "Google", accounts: [.google]) { $0.phones = [Labeled("mobile", "+44 20 7946 0958")] },
            // c30: On My Mac contact.
            person("c30", "Larry", "Local", accounts: [.local]),
            // c31: relations — resolved, unresolved, custom, ambiguous.
            person("c31", "Alex", "Boss") {
                $0.relationships = [
                    related("assistant", "Robin Helper"),
                    related("mentor", "Nobody Known"),
                    related("friend", "John Smith"),
                ]
            },
            person("c32", "Robin", "Helper") { $0.relationships = [related("reports_to", "Alex Boss")] },
            // c33: notes body with markdown and trailing whitespace lines.
            person("c33", "Note", "Taker") { $0.body = "# Heading\n\nSome *notes*.\n\n```\ncode: true\n```\n" },
            // c34: already stamped on another device.
            person("c34", "Stella", "Stamped", stamp: stellaID) { $0.emails = [Labeled("home", "stella@example.com")] },
            // c35: emoji in name.
            org("c35", "🎉 Party Co"),
            // c36: slash and colon in name → filename sanitized.
            org("c36", "AC/DC: Live"),
            // c37: leading dot.
            org("c37", ".hidden Org"),
            // c38: very long name.
            person("c38", String(repeating: "Bartholomew ", count: 8).trimmingCharacters(in: .whitespaces), "Longname"),
            // c39: address with only a country; address label spelled like a field.
            person("c39", "Address", "Edge") {
                $0.addresses = [
                    Labeled(nil, PostalAddress(country: "Canada")),
                    Labeled("street", PostalAddress(street: "9 Label Rd", city: "Ottawa")),
                ]
            },
            // c40: custom date label, unlabeled date (→ other), duplicate labels.
            person("c40", "Dated", "Person") {
                $0.dates = [
                    Labeled("birthday", .full(year: 1975, month: 1, day: 2)),
                    Labeled("first_met", .full(year: 2001, month: 9, day: 9)),
                    Labeled("anniversary", .full(year: 2005, month: 5, day: 5)),
                    Labeled("anniversary", .monthDay(month: 7, day: 7)),
                ]
            },
            // c41: phone with extension.
            person("c41", "Ext", "Ension") { $0.phones = [Labeled("work", "+1 415 555 0100 x123")] },
            // c42: same email twice in one contact.
            person("c42", "Twice", "Email") {
                $0.emails = [Labeled("home", "twice@example.com"), Labeled("work", "twice@example.com")]
            },
            // c43: nickname used in another contact's relation.
            person("c43", "William", "Gates") { $0.aliases = [.nickname("Bill")] },
            person("c44", "Melinda", "Gates") { $0.relationships = [related("sibling", "Bill", label: "brother")] },
            // c45: Work group only.
            person("c45", "Wendy", "Worker", groups: [work]) {
                $0.company = .plain("Acme Corp")
                $0.jobTitle = "Engineer"
            },
            // c46: PNG photo.
            person("c46", "Png", "Photo", image: pngBytes),
            // c47: prefix and suffix.
            person("c47", "Martin", "King") {
                $0.name = PersonName(prefix: "Rev.", given: "Martin", middle: "Luther", family: "King", suffix: "Jr.")
            },
            // c48: quotes and backslashes.
            person("c48", "Quote", "Marks") {
                $0.aliases = [.nickname("The \"Boss\"")]
                $0.department = "C:\\Users\\boss"
            },
            // c49: control characters (tab).
            person("c49", "Tab", "Char") { $0.jobTitle = "Lead\tEngineer" },
            // c50: custom label "On" (YAML bool word as a key).
            person("c50", "Label", "Trap") { $0.phones = [Labeled("on", "+1 415 555 0177")] },
            // c51: uppercase email, URL with trailing slash.
            person("c51", "Upper", "Case") {
                $0.emails = [Labeled("work", "UPPER@EXAMPLE.COM")]
                $0.urls = [Labeled(nil, "https://Example.com/")]
            },
            // c52: company is an organization contact → wikilink.
            person("c52", "Gina", "Globex") {
                $0.company = .plain("Globex")
                $0.emails = [Labeled("work", "gina@globex.example")]
            },
            // c53: unified contact with a Google card first in the list.
            person("c53", "Gail", "Both", accounts: [.google, .iCloud]) {
                $0.emails = [Labeled("home", "gail@example.com")]
            },
            // c54: middle-name-only edge plus Close Friends group.
            person("c54", "Ann", "Marie", groups: [closeFriends]) {
                $0.name = PersonName(given: "Ann", middle: "Q.", family: "Marie")
            },
            // c55: values with trailing/leading whitespace from Apple.
            person("c55", "  Spacey ", " Name  ") { $0.jobTitle = "  padded  " },
            // c56: a name that is a number.
            person("c56", "2Pac", nil),
            // c57: name with a hash and colon (filename + YAML).
            person("c57", "Mr: #1", nil),
            // c58: relationship to a contact that is skipped as a duplicate.
            person("c58", "Dana", "Friend") { $0.relationships = [related("friend", "Chris Martin")] },
            // c59: Google-only org.
            contact("c59", kind: .organization, accounts: [.google]) { $0.company = .plain("Hooli") },
            // c60: phone-only contact.
            contact("c60") { $0.phones = [Labeled("mobile", "+1 650 555 0110")] },
        ]
    }
    // swiftlint:enable function_body_length
}
