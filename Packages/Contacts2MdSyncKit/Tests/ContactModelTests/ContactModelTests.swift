import ContactModel
import Foundation
import PhoneNumberKeys
import Testing

@Suite("Label map")
struct LabelMapTests {
    @Test("every well-known Apple label maps to markdown and back", arguments: LabelMap.wellKnown)
    func wellKnownRoundTrip(pair: (apple: String, markdown: String)) {
        #expect(LabelMap.markdownLabel(fromApple: pair.apple) == pair.markdown)
        #expect(LabelMap.appleLabel(fromMarkdown: pair.markdown) == pair.apple)
    }

    @Test("schema §2 table")
    func schemaTable() {
        let table: [(String, String)] = [
            ("_$!<Mobile>!$_", "mobile"), ("iPhone", "iphone"), ("_$!<Main>!$_", "main"), ("_$!<Home>!$_", "home"),
            ("_$!<Work>!$_", "work"), ("_$!<Other>!$_", "other"), ("_$!<HomeFAX>!$_", "home_fax"),
            ("_$!<WorkFAX>!$_", "work_fax"), ("_$!<OtherFAX>!$_", "other_fax"), ("_$!<Pager>!$_", "pager"),
            ("_$!<HomePage>!$_", "homepage"), ("iCloud", "icloud"), ("_$!<School>!$_", "school"),
            ("_$!<Anniversary>!$_", "anniversary"),
        ]
        for (apple, markdown) in table { #expect(LabelMap.markdownLabel(fromApple: apple) == markdown) }
    }

    @Test("custom labels become snake_case; nil and empty are bare")
    func customLabels() {
        #expect(LabelMap.markdownLabel(fromApple: "Summer House") == "summer_house")
        #expect(LabelMap.markdownLabel(fromApple: "Grandma's  Place!") == "grandma_s_place")
        #expect(LabelMap.markdownLabel(fromApple: "_$!<Custom Thing>!$_") == "custom_thing")
        #expect(LabelMap.markdownLabel(fromApple: nil) == nil)
        #expect(LabelMap.markdownLabel(fromApple: "  ") == nil)
        #expect(LabelMap.markdownLabel(fromApple: "Café") == "café")
    }

    @Test("markdown → Apple: custom labels humanized, existing label kept when equivalent")
    func toApple() {
        #expect(LabelMap.appleLabel(fromMarkdown: "summer_house") == "Summer House")
        #expect(LabelMap.appleLabel(fromMarkdown: nil) == nil)
        #expect(LabelMap.appleLabel(fromMarkdown: "summer_house", existing: "SUMMER house") == "SUMMER house")
        #expect(LabelMap.appleLabel(fromMarkdown: "work", existing: "_$!<Home>!$_") == "_$!<Work>!$_")
        #expect(LabelMap.appleLabel(fromMarkdown: "Mobile") == "_$!<Mobile>!$_")
    }

    @Test("social / IM labels use the service name")
    func serviceLabels() {
        #expect(LabelMap.serviceLabel(service: "LinkedIn", label: "_$!<Work>!$_") == "linkedin")
        #expect(LabelMap.serviceLabel(service: nil, label: "_$!<Work>!$_") == "work")
        #expect(LabelMap.serviceLabel(service: "", label: nil) == nil)
    }

    @Test("relation labels → mbr type and label (schema §6)")
    func relationsToMbr() {
        let cases: [String?: (type: String, label: String?)] = [
            "_$!<Father>!$_": ("parent", "father"),
            "_$!<Mother>!$_": ("parent", "mother"),
            "_$!<Parent>!$_": ("parent", nil),
            "_$!<Son>!$_": ("child", "son"),
            "_$!<Daughter>!$_": ("child", "daughter"),
            "_$!<Child>!$_": ("child", nil),
            "_$!<Spouse>!$_": ("spouse", nil),
            "_$!<Husband>!$_": ("spouse", "husband"),
            "_$!<Wife>!$_": ("spouse", "wife"),
            "_$!<Partner>!$_": ("spouse", "partner"),
            "_$!<Brother>!$_": ("sibling", "brother"),
            "_$!<Sister>!$_": ("sibling", "sister"),
            "_$!<Manager>!$_": ("reports_to", nil),
            "_$!<Assistant>!$_": ("assistant", nil),
            "_$!<Friend>!$_": ("friend", nil),
            "Old Roommate": ("old_roommate", nil),
            nil: ("related", nil),
        ]
        for (apple, expected) in cases {
            let mapped = RelationLabelMap.mbr(fromApple: apple)
            #expect(mapped.type == expected.type, "\(String(describing: apple))")
            #expect(mapped.label == expected.label, "\(String(describing: apple))")
        }
    }

    @Test("mbr type and label → Apple relation label")
    func relationsToApple() {
        #expect(RelationLabelMap.apple(type: "parent", label: "father") == "_$!<Father>!$_")
        #expect(RelationLabelMap.apple(type: "parent", label: nil) == "_$!<Parent>!$_")
        #expect(RelationLabelMap.apple(type: "spouse", label: "wife") == "_$!<Wife>!$_")
        #expect(RelationLabelMap.apple(type: "reports_to", label: nil) == "_$!<Manager>!$_")
        #expect(RelationLabelMap.apple(type: "old_roommate", label: nil) == "Old Roommate")
        // A label that belongs to another type is ignored.
        #expect(RelationLabelMap.apple(type: "sibling", label: "father") == "_$!<Sibling>!$_")
    }
}

@Suite("Comparison keys")
struct ComparisonKeyTests {
    let usKeyer = PhoneNumberKitKeyer(defaultRegion: "US")

    @Test("email: trimmed and lowercased")
    func email() {
        #expect(ComparisonKeys.email("  Jane@Example.COM ") == "jane@example.com")
    }

    @Test("phone: E.164 regardless of formatting")
    func phoneE164() {
        for raw in ["(415) 555-0100", "415.555.0100", "+1 415 555 0100", "1-415-555-0100", "4155550100"] {
            #expect(usKeyer.key(for: raw) == "+14155550100", "\(raw)")
        }
        #expect(usKeyer.key(for: "+44 20 7946 0958") == "+442079460958")
        #expect(PhoneNumberKitKeyer(defaultRegion: "gb").key(for: "020 7946 0958") == "+442079460958")
    }

    @Test("phone: extensions become ;ext=")
    func phoneExtension() {
        #expect(usKeyer.key(for: "+1 415 555 0100 x123") == "+14155550100;ext=123")
        #expect(usKeyer.key(for: "415-555-0100 ext. 9") == "+14155550100;ext=9")
    }

    @Test("phone: unparsable numbers fall back to digits")
    func phoneFallback() {
        #expect(usKeyer.key(for: "*31#") == DigitsPhoneKeyer().key(for: "*31#"))
        #expect(DigitsPhoneKeyer().key(for: "+1 (415) 555-0100") == "+14155550100")
        #expect(DigitsPhoneKeyer().key(for: "555 0100 ;ext=7") == "5550100;ext=7")
    }

    @Test("url: scheme/host lowercased, default port and trailing slash dropped")
    func url() {
        #expect(ComparisonKeys.url("HTTPS://Example.COM:443/Path/") == "https://example.com/Path")
        #expect(ComparisonKeys.url("http://example.com:80") == "http://example.com")
        #expect(ComparisonKeys.url("not a url") == "not a url")
    }

    @Test("address: per component, case-folded, whitespace collapsed, country code uppercased")
    func address() {
        let left = PostalAddress(street: "1  Main St", city: "Springfield", countryCode: "us")
        let right = PostalAddress(street: "1 main st", city: "SPRINGFIELD", countryCode: "US")
        #expect(ComparisonKeys.address(left) == ComparisonKeys.address(right))
    }

    @Test("name: case-, diacritic- and width-insensitive")
    func name() {
        #expect(ComparisonKeys.name("José  ÁLVAREZ") == ComparisonKeys.name("jose alvarez"))
        #expect(ComparisonKeys.name("Zoë") == ComparisonKeys.name("zoe"))
    }

    @Test("date, body and tag keys")
    func others() {
        #expect(ComparisonKeys.date(.monthDay(month: 6, day: 10)) == "--06-10")
        #expect(ComparisonKeys.body("a\r\nb  \n\n") == "a\nb")
        #expect(ComparisonKeys.body(nil).isEmpty)
        #expect(ComparisonKeys.tag(" Close Friends ") == "close_friends")
    }
}

@Suite("Partial dates")
struct PartialDateTests {
    @Test("parses mbr's forms")
    func forms() {
        #expect(PartialDate(parsing: "1980-03-19") == .full(year: 1980, month: 3, day: 19))
        #expect(PartialDate(parsing: "--06-10") == .monthDay(month: 6, day: 10))
        #expect(PartialDate(parsing: "06-10") == .monthDay(month: 6, day: 10))
        #expect(PartialDate(parsing: "1980-03") == .yearMonth(year: 1980, month: 3))
        #expect(PartialDate(parsing: "1980") == .year(1980))
        #expect(PartialDate(parsing: "--02-29") == .monthDay(month: 2, day: 29))
    }

    @Test("rejects garbage as text")
    func garbage() {
        #expect(PartialDate(parsing: "circa 1855") == .text("circa 1855"))
        #expect(PartialDate(parsing: "1980-13-01") == .text("1980-13-01"))
        #expect(PartialDate(parsing: "80-03-19") == .text("80-03-19"))
        #expect(PartialDate(parsing: "--04-31") == .text("--04-31"))
    }

    @Test("iso is canonical and zero-padded")
    func iso() {
        #expect(PartialDate.full(year: 980, month: 3, day: 9).iso == "0980-03-09")
        #expect(PartialDate.monthDay(month: 1, day: 2).iso == "--01-02")
    }
}

@Suite("Titles")
struct TitleTests {
    private func person(_ name: PersonName, build: (inout CanonicalContact) -> Void = { _ in }) -> String {
        var contact = CanonicalContact(kind: .person, title: "", name: name)
        build(&contact)
        return TitleGenerator.title(for: contact)
    }

    @Test("person: given family suffix, no middle or prefix")
    func person() {
        #expect(person(PersonName(prefix: "Dr.", given: "Jane", middle: "Quinn", family: "Doe")) == "Jane Doe")
        #expect(person(PersonName(given: "Martin", family: "King", suffix: "Jr.")) == "Martin King Jr.")
        #expect(person(PersonName(family: "Müller")) == "Müller")
        #expect(person(PersonName(given: "太郎", family: "山田")) == "山田太郎")
    }

    @Test("fallbacks: nickname, organization, email, phone, unnamed")
    func fallbacks() {
        #expect(person(PersonName()) { $0.aliases = [.nickname("JJ")] } == "JJ")
        #expect(person(PersonName()) { $0.company = .plain("Initech") } == "Initech")
        #expect(person(PersonName()) { $0.emails = [Labeled(nil, "a@b.c")] } == "a@b.c")
        #expect(person(PersonName()) { $0.phones = [Labeled(nil, "+1 555")] } == "+1 555")
        #expect(person(PersonName()) == TitleGenerator.unnamed)
    }

    @Test("organization: company name")
    func organization() {
        let org = CanonicalContact(kind: .organization, title: "", company: .wikilink("Acme|ACME Inc"))
        #expect(TitleGenerator.title(for: org) == "ACME Inc")
    }

    @Test("name variants include middle-name and nickname spellings")
    func variants() {
        var contact = CanonicalContact(
            kind: .person, title: "", name: PersonName(given: "William", middle: "H", family: "Gates"))
        contact.aliases = [.nickname("Bill")]
        let variants = TitleGenerator.nameVariants(for: contact)
        #expect(variants.contains("William Gates"))
        #expect(variants.contains("William H Gates"))
        #expect(variants.contains("Bill"))
        #expect(variants.contains("Bill Gates"))
    }
}

@Suite("Sync stamp and wikilinks")
struct StampTests {
    @Test("stamp URL round-trips; malformed stamps are still stamps")
    func stamp() throws {
        let id = try #require(UUID(uuidString: "6F1C2E0A-8C1B-4B0E-9A57-2D0D4A1C9F13"))
        let url = SyncStamp.url(for: id)
        #expect(url == "x-c2mdsync:6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13")
        #expect(SyncStamp.id(fromURL: url) == id)
        #expect(SyncStamp.id(fromURL: "X-C2MDSYNC:" + id.uuidString) == id)
        #expect(SyncStamp.id(fromURL: "x-c2mdsync:nope") == nil)
        #expect(SyncStamp.isStamp("x-c2mdsync:nope"))
        #expect(!SyncStamp.isStamp("https://example.com"))
    }

    @Test("company wikilinks")
    func company() {
        #expect(CompanyRef(raw: "[[Acme Corp]]").isWikilink)
        #expect(CompanyRef(raw: "[[Acme Corp]]").name == "Acme Corp")
        #expect(CompanyRef(raw: "[[acme|Acme Corp]]").name == "Acme Corp")
        #expect(!CompanyRef(raw: "Acme [[Corp]]").isWikilink)
        #expect(Wikilink.target(of: "[[ X | Y ]]") == "X")
        #expect(Wikilink.inner(of: "[[]]") == nil)
    }

    @Test("stamp target prefers the iCloud card")
    func stampTarget() {
        let contact = AppleContact(
            unifiedID: "a",
            cards: [
                AppleCard(id: "g", containerID: "google", accountKind: .google),
                AppleCard(id: "i", containerID: "icloud", accountKind: .iCloud),
            ],
            contact: CanonicalContact(kind: .person, title: "")
        )
        #expect(contact.stampTargetCard?.id == "i")
        #expect(contact.isICloudBacked)
    }
}
