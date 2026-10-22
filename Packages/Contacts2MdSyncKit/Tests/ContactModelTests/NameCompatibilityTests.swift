import ContactModel
import Testing

@Suite("Name compatibility")
struct NameCompatibilityTests {
    private func person(
        _ given: String?, _ family: String?, aliases: [Alias] = [], title: String = ""
    ) -> CanonicalContact {
        CanonicalContact(kind: .person, title: title, name: PersonName(given: given, family: family), aliases: aliases)
    }

    private func compatible(_ lhs: CanonicalContact, _ rhs: CanonicalContact) -> Bool {
        NameCompatibility.compatible(lhs, rhs)
    }

    @Test("equal names, case and diacritics folded")
    func equal() {
        #expect(compatible(person("José", "Álvarez"), person("jose", "ALVAREZ")))
    }

    @Test("spouses and siblings: same family name, different given names, are incompatible")
    func household() {
        #expect(!compatible(person("John", "Doe"), person("Jane", "Doe")))
        #expect(!compatible(person("Amy", "Park"), person("Beth", "Park")))
        #expect(!compatible(person("Christopher", "Lee"), person("Christine", "Lee")))
        #expect(!compatible(person("Alexander", "Wu"), person("Alexandra", "Wu")))
        let verdict = NameCompatibility.verdict(
            NameCompatibility.Profile(person("John", "Doe")), NameCompatibility.Profile(person("Jane", "Doe")))
        #expect(verdict == .incompatible(detail: "John / Jane"))
    }

    @Test(
        "initials and prefixes",
        arguments: [("J", "James"), ("J.", "James"), ("Chris", "Christopher"), ("Sam", "Samantha")])
    func initials(short: String, long: String) {
        #expect(compatible(person(short, "Smith"), person(long, "Smith")))
    }

    @Test("two-letter prefixes are not enough")
    func shortPrefix() {
        #expect(!compatible(person("Al", "Smith"), person("Alice", "Smith")))
    }

    @Test(
        "nickname pairs",
        arguments: [
            ("Bob", "Robert"), ("Bill", "William"), ("Liz", "Elizabeth"), ("Beth", "Elizabeth"), ("Jim", "James"),
            ("Mike", "Michael"), ("Kate", "Katherine"), ("Kathy", "Katherine"), ("Dick", "Richard"),
            ("Peg", "Margaret"), ("Tony", "Anthony"), ("Ted", "Theodore"), ("Ted", "Edward"), ("Steve", "Stephen"),
            ("Steven", "Stephen"), ("Bob", "Rob"), ("Will", "Bill"),
        ])
    func nicknames(nickname: String, formal: String) {
        #expect(compatible(person(nickname, "Smith"), person(formal, "Smith")))
        #expect(compatible(person(formal, "Smith"), person(nickname, "Smith")))
    }

    @Test("a missing given name or no person name at all is compatible")
    func missing() {
        #expect(compatible(person(nil, "Smith"), person("John", "Smith")))
        #expect(compatible(person("Cher", nil), person("Cher", "Sarkisian")))
        let organization = CanonicalContact(kind: .organization, title: "Acme", company: .plain("Acme"))
        #expect(compatible(organization, person("Jane", "Doe")))
        #expect(compatible(CanonicalContact(kind: .person, title: ""), person("Jane", "Doe")))
        // A bare given name never equals a bare family name.
        #expect(!compatible(person("Smith", nil), person(nil, "Smith")))
    }

    @Test("different family names are incompatible unless hyphenated, compound or a maiden name")
    func families() {
        #expect(!compatible(person("Jane", "Doe"), person("Jane", "Roe")))
        #expect(compatible(person("Ana", "García-López"), person("Ana", "Garcia")))
        #expect(compatible(person("Ana", "García López"), person("Ana", "Lopez")))
        #expect(compatible(person("Pieter", "van der Berg"), person("Pieter", "Berg")))
        #expect(compatible(person("Jane", "Doe", aliases: [.maidenName("Smith")]), person("Jane", "Smith")))
        #expect(compatible(person("Jane", "Doe", aliases: [.maidenName("Jane Smith")]), person("Jane", "Smith")))
    }

    @Test("nickname aliases and plain aliases are alternative spellings")
    func aliases() {
        #expect(compatible(person("Margaret", "Hale", aliases: [.nickname("Daisy")]), person("Daisy", "Hale")))
        #expect(compatible(person("Jo", "March", aliases: [.plain("Josephine Bhaer")]), person("Josephine", "Bhaer")))
    }

    @Test("hand-written notes: the title stands in for missing name parts")
    func titleFallback() {
        let note = CanonicalContact(kind: .person, title: "Jane Doe")
        let husband = NameCompatibility.Profile(person("John", "Doe"))
        #expect(!NameCompatibility.verdict(NameCompatibility.Profile(note, titleFallback: true), husband).isCompatible)
        #expect(NameCompatibility.verdict(NameCompatibility.Profile(note), husband) == .noPersonName)
    }

    @Test("household phone labels")
    func phoneLabels() {
        for label in ["home", "main", "work", "other", "home_fax", "work_fax", "pager", "grandma_s"] {
            #expect(PhoneLabels.isHousehold(label), "\(label)")
        }
        for label: String? in ["mobile", "iphone", "iPhone", nil, ""] {
            #expect(!PhoneLabels.isHousehold(label), "\(label ?? "nil")")
        }
    }
}
