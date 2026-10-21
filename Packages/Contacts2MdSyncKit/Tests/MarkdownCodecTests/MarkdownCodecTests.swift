import ContactModel
import Foundation
import MarkdownCodec
import SyncTestSupport
import Testing
import Yams

/// The contact described by markdown-schema §1.
func schemaExample() throws -> CanonicalContact {
    var contact = CanonicalContact(kind: .person, title: "Jane Q. Doe")
    contact.name = PersonName(prefix: "Dr.", given: "Jane", middle: "Quinn", family: "Doe")
    contact.aliases = [.nickname("JJ"), .maidenName("Jane Smith")]
    contact.company = .wikilink("Acme Corp")
    contact.department = "R&D"
    contact.jobTitle = "CTO"
    contact.image = ImageRef(path: "../_images/6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13.jpg")
    contact.emails = [Labeled("work", "jane@acme.com"), Labeled("home", "jane@example.com")]
    contact.phones = [Labeled("mobile", "+1 415 555 0100"), Labeled("work", "+1 415 555 0199")]
    contact.urls = [Labeled("homepage", "https://janedoe.example")]
    contact.social = [Labeled("linkedin", SocialHandle("https://www.linkedin.com/in/janedoe"))]
    contact.im = [Labeled("signal", IMHandle("+1 415 555 0100"))]
    contact.addresses = [
        Labeled(
            "home",
            PostalAddress(
                street: "1 Main St", city: "Springfield", region: "IL", postcode: "62701", country: "USA",
                countryCode: "US"))
    ]
    contact.dates = [
        Labeled("birthday", .full(year: 1980, month: 3, day: 19)), Labeled("anniversary", .monthDay(month: 6, day: 10)),
    ]
    contact.relationships = [
        RelationshipRef(type: "spouse", target: .wikilink("John Doe")),
        RelationshipRef(type: "parent", label: "father", target: .wikilink("Bob Smith")),
    ]
    contact.tags = ["family", "close_friends"]
    contact.apple = AppleExtras(phoneticFamily: "ドウ")
    contact.sync = SyncMetadata(id: UUID(uuidString: "6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13"))
    contact.body = """
        Everything below the frontmatter is the Apple Contacts "Notes" field
        (when the notes entitlement is available; otherwise it is markdown-only).

        """
    return contact
}

func parseContact(_ text: String) throws -> CanonicalContact {
    try #require(try MarkdownCodec.parse(text).contact)
}

@Suite("Emitter")
struct EmitterTests {
    @Test("emits markdown-schema §1 byte for byte")
    func schemaGolden() throws {
        let emitted = try MarkdownCodec.encode(try schemaExample())
        let golden = GoldenFiles.directory("schema-example.md")
        if GoldenFiles.updating { try Data(emitted.utf8).write(to: golden) }
        #expect(emitted == (try String(contentsOf: golden, encoding: .utf8)))
    }

    @Test("parse(emit(x)) == x for the schema example")
    func schemaRoundTrip() throws {
        let contact = try schemaExample()
        #expect(try parseContact(try MarkdownCodec.encode(contact)) == contact)
    }

    @Test("unlabeled values are bare list items")
    func bareItems() throws {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.emails = [Labeled(nil, "a@example.com"), Labeled("work", "b@example.com")]
        contact.aliases = [.plain("Old Name")]
        let text = try MarkdownCodec.encode(contact)
        #expect(text.contains("emails:\n  - a@example.com\n  - work: b@example.com\n"))
        #expect(text.contains("aliases:\n  - Old Name\n"))
    }

    @Test("dates fall back to the list form for repeated labels")
    func datesList() throws {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.dates = [Labeled("anniversary", .monthDay(month: 1, day: 1)), Labeled("anniversary", .year(1990))]
        let text = try MarkdownCodec.encode(contact)
        #expect(text.contains("dates:\n  - anniversary: \"--01-01\"\n  - anniversary: \"1990\"\n"))
        #expect(try parseContact(text) == contact)
    }

    @Test("relationship targets: wikilink quoted, plain names, attributes and from: kept")
    func relationships() throws {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.relationships = [
            RelationshipRef(
                type: "spouse", target: .wikilink("John Doe"),
                attributes: [YAMLField(key: "married", value: .scalar("1948-06-01", plain: true))]),
            RelationshipRef(type: "friend", target: .name("Somebody Else")),
            RelationshipRef(
                type: "employee", target: nil, attributes: [YAMLField(key: "from", value: .string("[[Acme]]"))]),
        ]
        let text = try MarkdownCodec.encode(contact)
        #expect(text.contains("  - type: spouse\n    to: \"[[John Doe]]\"\n    married: 1948-06-01\n"))
        #expect(text.contains("  - type: friend\n    to: Somebody Else\n"))
        #expect(try parseContact(text) == contact)
    }

    @Test(".record targets must be resolved before encoding")
    func unresolvedRecord() {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.relationships = [RelationshipRef(type: "spouse", target: .record(UUID()))]
        #expect(throws: CodecError.unresolvedRecordReference) { try MarkdownCodec.encode(contact) }
    }

    @Test("addresses: unlabeled object, string form, field-like label uses label:")
    func addresses() throws {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.addresses = [
            Labeled(nil, PostalAddress(city: "Ottawa")),
            Labeled("home", PostalAddress(formatted: "1 Main St\nSpringfield")),
            Labeled("city", PostalAddress(street: "9 Rd")),
            Labeled("value", PostalAddress(formatted: "Somewhere")),
        ]
        let text = try MarkdownCodec.encode(contact)
        #expect(text.contains("  - city: Ottawa\n"))
        #expect(text.contains("  - home: \"1 Main St\\nSpringfield\"\n"))
        #expect(text.contains("  - label: city\n    street: \"9 Rd\"\n"))
        #expect(text.contains("  - label: value\n    value: Somewhere\n"))
        #expect(try parseContact(text) == contact)
    }

    @Test("CRLF files keep CRLF")
    func crlf() throws {
        let original = "---\r\ntype: person\r\ntitle: X\r\nfoo: bar\r\n---\r\nBody\r\n"
        let note = try MarkdownCodec.parse(original)
        var contact = try #require(note.contact)
        contact.jobTitle = "Boss"
        let text = try MarkdownCodec.encode(contact, patching: note)
        #expect(text == "---\r\ntype: person\r\ntitle: X\r\nfoo: bar\r\njob_title: Boss\r\n---\r\nBody\r\n")
    }
}

@Suite("Quoting traps")
struct QuotingTests {
    static let traps = [
        "no", "No", "yes", "YES", "on", "off", "true", "False", "null", "Null", "~", "y", "n", "0123", "123", "1.5",
        "+1 415", "-1", ".5", ".inf", "1980-03-19", "--06-10", "@handle", "#tag", "a #b", "a: b", "trailing:",
        "[x]", "{x}", "*star", "&anchor", "!bang", "%pct", "|pipe", ">gt", "'single", "\"double", "`tick",
        "- dash", "-dash", "? q", ": colon", ",comma", "tab\there", "line\nbreak", "back\\slash", "<<", "=",
        "ドウ", "emoji 🎉", "C:\\path", "https://example.com/a:b#c", "0x1F", "1e3", "12:30", "\u{FEFF}bom",
    ]

    @Test("trap values round-trip as strings through our parser", arguments: traps)
    func roundTrip(value: String) throws {
        var contact = CanonicalContact(kind: .person, title: value)
        contact.jobTitle = value
        contact.emails = [Labeled(value, value)]
        contact.tags = [value]
        let text = try MarkdownCodec.encode(contact)
        #expect(try parseContact(text) == MarkdownCodec.normalize(contact))
    }

    @Test("trap values stay strings under a YAML 1.1 resolver (Yams)", arguments: traps)
    func typedReading(value: String) throws {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.jobTitle = value
        let text = try MarkdownCodec.encode(contact)
        let yaml = try #require(Frontmatter.split(text)).yaml
        let loaded = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        #expect(loaded["job_title"] as? String == MarkdownCodec.normalize(contact).jobTitle)
    }

    @Test("phones, postcodes and dates are always quoted")
    func forcedQuotes() throws {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.phones = [Labeled("main", "ABC-DEF")]
        contact.addresses = [Labeled(nil, PostalAddress(postcode: "SW1A 1AA"))]
        contact.dates = [Labeled("birthday", .full(year: 1980, month: 3, day: 19))]
        let text = try MarkdownCodec.encode(contact)
        #expect(text.contains("- main: \"ABC-DEF\""))
        #expect(text.contains("postcode: \"SW1A 1AA\""))
        #expect(text.contains("birthday: \"1980-03-19\""))
    }

    @Test("keys that YAML would reinterpret are quoted")
    func keys() throws {
        var contact = CanonicalContact(kind: .person, title: "X")
        contact.phones = [Labeled("on", "+1 555 0100"), Labeled("123", "+1 555 0101")]
        let text = try MarkdownCodec.encode(contact)
        #expect(text.contains("  - \"on\": \"+1 555 0100\"\n  - \"123\": \"+1 555 0101\"\n"))
        #expect(try parseContact(text) == contact)
    }
}
