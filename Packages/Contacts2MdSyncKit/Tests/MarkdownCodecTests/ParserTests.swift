import ContactModel
import Foundation
import MarkdownCodec
import Testing

@Suite("Parser accepts every mbr shape")
struct ParserTests {
    @Test("multi-value: map, list of one-key maps, bare items, scalar, {label,value}, {label,name}")
    func shapes() throws {
        let text = """
            ---
            type: person
            emails: {work: a@x.com, home: b@x.com}
            phones:
              - mobile: "+1 555"
              - "+1 556"
              - {label: work, value: "+1 557"}
            urls: https://x.example
            social:
              - label: github
                name: https://github.com/x
            im: [{signal: "+1 555"}, skype.handle]
            ---
            """
        let contact = try parseContact(text)
        #expect(contact.emails == [Labeled("work", "a@x.com"), Labeled("home", "b@x.com")])
        #expect(contact.phones == [Labeled("mobile", "+1 555"), Labeled(nil, "+1 556"), Labeled("work", "+1 557")])
        #expect(contact.urls == [Labeled(nil, "https://x.example")])
        #expect(contact.social == [Labeled("github", SocialHandle("https://github.com/x"))])
        #expect(contact.im == [Labeled("signal", IMHandle("+1 555")), Labeled(nil, IMHandle("skype.handle"))])
    }

    @Test("malformed entries are skipped, not fatal (like mbr)")
    func malformed() throws {
        let text = """
            ---
            type: person
            emails:
              - {a: 1, b: 2}
              - [nested]
              - ok@x.com
            ---
            """
        #expect(try parseContact(text).emails == [Labeled(nil, "ok@x.com")])
    }

    @Test("addresses: map of label→object, address object, string, label inside object")
    func addressShapes() throws {
        let text = """
            ---
            type: person
            addresses:
              - home:
                  street: 1 Main St
                  postcode: 02134
              - street: 2 Side St
                label: work
              - city: Ottawa
              - "Line 1\\nLine 2"
            ---
            """
        let contact = try parseContact(text)
        #expect(contact.addresses.count == 4)
        #expect(contact.addresses[0] == Labeled("home", PostalAddress(street: "1 Main St", postcode: "02134")))
        #expect(contact.addresses[1] == Labeled("work", PostalAddress(street: "2 Side St")))
        #expect(contact.addresses[2] == Labeled(nil, PostalAddress(city: "Ottawa")))
        #expect(contact.addresses[3] == Labeled(nil, PostalAddress(formatted: "Line 1\nLine 2")))
        // A single address object (not a list) is one unlabeled address.
        let single = try parseContact("---\ntype: person\naddresses: {city: Oslo}\n---\n")
        #expect(single.addresses == [Labeled(nil, PostalAddress(city: "Oslo"))])
    }

    @Test("tags: list, flow array, comma string")
    func tags() throws {
        #expect(try parseContact("---\ntype: person\ntags: [a, b]\n---\n").tags == ["a", "b"])
        #expect(try parseContact("---\ntype: person\ntags: a, b , a\n---\n").tags == ["a", "b"])
        #expect(try parseContact("---\ntype: person\ntags:\n- x\n- y\n---\n").tags == ["x", "y"])
    }

    @Test("aliases: string, mixed list, map")
    func aliases() throws {
        #expect(try parseContact("---\ntype: person\naliases: Bob\n---\n").aliases == [.plain("Bob")])
        let mixed = try parseContact(
            "---\ntype: person\naliases: [Bobby, {nickname: Bob}, {maiden_name: Smith}]\n---\n")
        #expect(mixed.aliases == [.plain("Bobby"), .nickname("Bob"), .maidenName("Smith")])
        let map = try parseContact("---\ntype: person\naliases: {nickname: Bob, formerly: Rob}\n---\n")
        #expect(map.aliases == [.nickname("Bob"), Alias(label: "formerly", name: "Rob")])
    }

    @Test("dates: map, list, unlabeled dropped, unparseable kept as text, scalars keep source text")
    func dates() throws {
        let contact = try parseContact(
            "---\ntype: person\ndates:\n  birthday: 1980-03-19\n  death: circa 1855\n  first_met: 2001\n---\n")
        #expect(
            contact.dates == [
                Labeled("birthday", .full(year: 1980, month: 3, day: 19)), Labeled("death", .text("circa 1855")),
                Labeled("first_met", .year(2001)),
            ])
        #expect(try parseContact("---\ntype: person\ndates: [1999-01-01]\n---\n").dates.isEmpty)
    }

    @Test("scalars are read as written: no YAML 1.1 coercion")
    func noCoercion() throws {
        let contact = try parseContact("---\ntype: person\nfirst_name: no\nlast_name: 0123\njob_title: 1.50\n---\n")
        #expect(contact.name.given == "no")
        #expect(contact.name.family == "0123")
        #expect(contact.jobTitle == "1.50")
    }

    @Test("type must be exactly person or organization")
    func types() throws {
        #expect(try MarkdownCodec.parse("---\ntype: Person\n---\n").contact == nil)
        #expect(try MarkdownCodec.parse("---\ntype: \" organization \"\n---\n").contact?.kind == .organization)
        #expect(try MarkdownCodec.parse("# Just a note\n").contact == nil)
        #expect(try MarkdownCodec.parse("# Just a note\n").hasFrontmatter == false)
    }

    @Test("unknown keys are passed through in order")
    func passthrough() throws {
        let contact = try parseContact(
            "---\ntype: person\ngender: f\nborn_place: Oslo\ntitle: X\ncustom: [1, 2]\n---\n")
        #expect(contact.passthrough.map(\.key) == ["gender", "born_place", "custom"])
    }

    @Test("c2mdsync: id parsed, bad id preserved verbatim")
    func c2mdsync() throws {
        let good = try parseContact("---\ntype: person\nc2mdsync:\n  id: 6F1C2E0A-8C1B-4B0E-9A57-2D0D4A1C9F13\n---\n")
        #expect(good.sync.id?.uuidString == "6F1C2E0A-8C1B-4B0E-9A57-2D0D4A1C9F13")
        let bad = try parseContact("---\ntype: person\nc2mdsync:\n  id: nope\n  status: detached\n---\n")
        #expect(bad.sync.id == nil)
        #expect(bad.sync.status == "detached")
        #expect(bad.sync.other == [YAMLField(key: "id", value: .scalar("nope", plain: true))])
    }

    @Test("errors: invalid YAML, unterminated, merge keys")
    func errors() {
        #expect(throws: CodecError.self) { try MarkdownCodec.parse("---\ntype: person\nemails: [\n---\n") }
        #expect(throws: CodecError.unterminatedFrontmatter) { try MarkdownCodec.parse("---\ntype: person\n") }
        #expect(throws: CodecError.self) { try MarkdownCodec.parse("---\na: &x {b: 1}\nc:\n  <<: *x\n---\n") }
    }

    @Test("anchors and aliases are expanded, and make the note non-patchable")
    func anchors() throws {
        let note = try MarkdownCodec.parse("---\ntype: person\nfirst_name: &n Jane\ntitle: *n\n---\n")
        #expect(note.contact?.title == "Jane")
        #expect(!note.isPatchable)
    }

    @Test("title and alias names for any note")
    func noteNames() throws {
        let note = try MarkdownCodec.parse("---\ntitle: Hello\naliases: [A, {nickname: B}]\n---\n")
        #expect(note.title == "Hello")
        #expect(note.aliasNames == ["A", "B"])
    }
}
