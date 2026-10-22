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

    @Test("a title that is not plainly a name is no person name; one word is a given name")
    func titleShapes() {
        let jane = NameCompatibility.Profile(person("Jane", "Doe"))
        for title in ["Dr. Jane Doe", "Jane Doe Jr.", "Jane Doe, MD", "Doe, Jane", "Jane Doe (Acme)", "Jane Doe 2"] {
            let note = NameCompatibility.Profile(CanonicalContact(kind: .person, title: title), titleFallback: true)
            #expect(NameCompatibility.verdict(note, jane) == .noPersonName, "\(title)")
        }
        func titled(_ title: String) -> NameSpelling? {
            NameCompatibility.Profile(CanonicalContact(kind: .person, title: title), titleFallback: true).primary
        }
        #expect(titled("Jane Q. Doe")?.given == "jane" && titled("Jane Q. Doe")?.family == "doe")
        #expect(titled("Jane")?.given == "jane" && titled("Jane")?.family == "")
    }

    @Test(
        "spouse and sibling pairs where one name starts the other are different people",
        arguments: [
            ("Daniel", "Danielle"), ("Paul", "Paula"), ("Eric", "Erica"), ("Robert", "Roberta"), ("Joan", "Joanna"),
            ("Louis", "Louise"), ("Gabriel", "Gabriella"),
        ])
    func masculineFeminine(lhs: String, rhs: String) {
        #expect(!compatible(person(lhs, "Doe"), person(rhs, "Doe")))
    }

    @Test(
        "short forms and pet forms not in the nickname table still match",
        arguments: [("Jess", "Jessica"), ("Theo", "Theodore"), ("Ann", "Annie"), ("Jenn", "Jenny")])
    func shortForms(short: String, long: String) {
        #expect(compatible(person(short, "Smith"), person(long, "Smith")))
    }

    @Test("compound given names agree word by word")
    func compoundGivenNames() {
        #expect(!compatible(person("Jean-Luc", "Picard"), person("Jean-Pierre", "Picard")))
        #expect(!compatible(person("Mary Ann", "Lee"), person("Mary Beth", "Lee")))
        #expect(!compatible(person("José Luis", "García"), person("José Antonio", "García")))
        #expect(compatible(person("Mary", "Lee"), person("Mary Ann", "Lee")))
        #expect(compatible(person("Jean Luc", "Picard"), person("Jean-Luc", "Picard")))
        #expect(compatible(person("J. L.", "Picard"), person("Jean-Luc", "Picard")))
    }

    @Test("different generational suffixes are different people; a missing suffix is not")
    func generations() {
        func smith(_ suffix: String?) -> CanonicalContact {
            CanonicalContact(kind: .person, title: "", name: PersonName(given: "John", family: "Smith", suffix: suffix))
        }
        #expect(!compatible(smith("Sr."), smith("Jr.")))
        #expect(!compatible(smith("II"), smith("III")))
        #expect(compatible(smith("Jr."), smith("jr")))
        #expect(compatible(smith("Jr."), smith(nil)))
        #expect(compatible(smith("PhD"), smith("MD")))
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
