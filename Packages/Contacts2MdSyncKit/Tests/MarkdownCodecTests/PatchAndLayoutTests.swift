import ContactModel
import Foundation
import MarkdownCodec
import Testing

@Suite("Patching existing notes")
struct PatchTests {
    static let original = """
        ---
        # Contact card
        type: person
        title: Jane Doe   # hand-written title
        first_name: Jane
        gender: female
        phones:
        - mobile: +1 415 555 0100   # unquoted, block list at column 0
        custom:
          nested: [1, 2]

        tags: [family, me]
        ---
        Body text.
        """

    @Test("no change → identical bytes")
    func unchanged() throws {
        let note = try MarkdownCodec.parse(Self.original)
        let contact = try #require(note.contact)
        #expect(try MarkdownCodec.encode(contact, patching: note) == Self.original)
    }

    @Test("changing one key rewrites only that key; comments and unknown keys stay put")
    func singleKey() throws {
        let note = try MarkdownCodec.parse(Self.original)
        var contact = try #require(note.contact)
        contact.phones = [Labeled("mobile", "+1 415 555 0101")]
        let text = try MarkdownCodec.encode(contact, patching: note)
        let expected = Self.original.replacingOccurrences(
            of: "phones:\n- mobile: +1 415 555 0100   # unquoted, block list at column 0\n",
            with: "phones:\n  - mobile: \"+1 415 555 0101\"\n")
        #expect(text == expected)
    }

    @Test("new managed keys go to their canonical position; removed keys disappear")
    func insertAndRemove() throws {
        let note = try MarkdownCodec.parse(Self.original)
        var contact = try #require(note.contact)
        contact.name.family = "Doe"
        contact.emails = [Labeled("work", "jane@acme.com")]
        contact.sync = SyncMetadata(id: UUID(uuidString: "6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13"))
        contact.tags = []
        let text = try MarkdownCodec.encode(contact, patching: note)
        let expected = """
            ---
            # Contact card
            type: person
            title: Jane Doe   # hand-written title
            first_name: Jane
            last_name: Doe
            emails:
              - work: jane@acme.com
            gender: female
            phones:
            - mobile: +1 415 555 0100   # unquoted, block list at column 0
            custom:
              nested: [1, 2]

            mdsync:
              id: 6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13
            ---
            Body text.
            """
        #expect(text == expected)
    }

    @Test("non-patchable YAML (flow mapping) falls back to a full re-emit, keeping unknown values")
    func fallback() throws {
        let original = "---\n{type: person, title: X, gender: f, extra: {a: 1}}\n---\n"
        let note = try MarkdownCodec.parse(original)
        #expect(!note.isPatchable)
        var contact = try #require(note.contact)
        contact.jobTitle = "Boss"
        let text = try MarkdownCodec.encode(contact, patching: note)
        #expect(text == "---\ntype: person\ntitle: X\njob_title: Boss\ngender: f\nextra:\n  a: 1\n---\n")
        #expect(try parseContact(text) == contact)
    }
}

@Suite("Filenames")
struct FilenameTests {
    @Test("sanitizing")
    func sanitize() {
        #expect(Filenames.stem(for: "AC/DC: Live") == "AC-DC- Live")
        #expect(Filenames.stem(for: "..hidden") == "hidden")
        #expect(Filenames.stem(for: "a\\b") == "a-b")
        #expect(Filenames.stem(for: "Tab\tName\u{0007}") == "Tab Name")
        #expect(Filenames.stem(for: "   ") == "Unnamed")
        #expect(Filenames.stem(for: String(repeating: "x", count: 300)).count == Filenames.maxStemLength)
        // NFC: decomposed é becomes one scalar.
        #expect(Filenames.stem(for: "Jose\u{0301}").unicodeScalars.count == 4)
    }

    @Test("collisions: Title, Title (Company), Title 2, Title 3")
    func collisions() {
        var taken: Set<String> = []
        func next(_ company: String?) -> String {
            let stem = Filenames.uniqueStem(title: "John Smith", company: company) { taken.contains($0) }
            taken.insert(stem.lowercased())
            return stem
        }
        #expect(next("Acme") == "John Smith")
        #expect(next("Acme") == "John Smith (Acme)")
        #expect(next("Acme") == "John Smith 2")
        #expect(next(nil) == "John Smith 3")
        #expect(Filenames.uniqueStem(title: "JOHN SMITH", company: nil) { taken.contains($0) } == "JOHN SMITH 4")
    }
}

@Suite("Frontmatter and layout")
struct LayoutTests {
    @Test("split keeps the body byte-exact")
    func split() throws {
        let split = try #require(Frontmatter.split("---\na: 1\n---\n\nbody\n---\nmore"))
        #expect(split.yaml == "a: 1\n")
        #expect(split.body == "\nbody\n---\nmore")
        #expect(Frontmatter.split("no frontmatter") == nil)
        #expect(try #require(Frontmatter.split("\u{FEFF}---\na: 1\n...\nx")).body == "x")
    }

    @Test("layout segments reassemble to the source")
    func layout() throws {
        let yaml = "# c\na: 1\n\nb:\n  - x\n\n  - y\nc: |\n  text\n\n  more\n# end\n"
        let layout = try #require(YAMLLayout(scanning: yaml))
        #expect(layout.text == yaml)
        #expect(layout.keys == ["a", "b", "c"])
        #expect(YAMLLayout(scanning: "{a: 1}\n") == nil)
        #expect(YAMLLayout(scanning: "? complex\n: value\n") == nil)
        #expect(try #require(YAMLLayout(scanning: "\"quoted key\": 1\n")).keys == ["quoted key"])
    }
}
