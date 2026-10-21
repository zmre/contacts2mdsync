public import ContactModel
internal import Foundation

/// A parsed markdown note: frontmatter fields, the contact they describe (if
/// any), the body, and what is needed to patch the file in place later.
public struct ParsedNote: Sendable {
    /// `false` when the file has no frontmatter block at all.
    public var hasFrontmatter: Bool
    /// Top-level frontmatter fields in authored order.
    public var fields: [YAMLField]
    /// The contact, when `type` is `person` or `organization`.
    public var contact: CanonicalContact?
    /// Everything after the frontmatter, byte-exact.
    public var body: String
    /// Source layout for span patching; `nil` when the YAML is not a plain
    /// block mapping (then a rewrite re-emits unknown keys generically).
    var layout: YAMLLayout?
    var usesCRLF: Bool

    /// The frontmatter `title`, if set.
    public var title: String? { ContactDecoding.text(fields.first { $0.key == "title" }?.value) }

    /// Names in `aliases` (any shape mbr accepts), labels dropped.
    public var aliasNames: [String] {
        ContactDecoding.labeledValues("aliases", fields.first { $0.key == "aliases" }?.value)
            .compactMap { ContactDecoding.text($0.1) }
    }

    /// `true` when the YAML can be patched span-by-span.
    public var isPatchable: Bool { layout != nil }
}

/// Encodes and decodes contacts to and from markdown files with YAML
/// frontmatter (markdown-schema §4).
///
/// - Decoding accepts every shape mbr accepts.
/// - Encoding uses our own emitter (`YAMLWriter`) for byte-stable output in
///   the fixed key order of markdown-schema §1.
/// - When given the note's previous parse, encoding **patches**: keys whose
///   value did not change keep their original bytes, unknown keys and
///   comments stay exactly where they were, and only changed managed keys are
///   re-emitted. New managed keys are inserted at their canonical position.
/// - Every encode is decoded again and compared to the intended contact; a
///   mismatch throws instead of producing a file that reads back differently.
public enum MarkdownCodec {
    /// The `ContactModel` schema version this codec reads and writes.
    public static let supportedSchemaVersion = ContactModel.schemaVersion

    /// Delimiter that opens and closes a YAML frontmatter block.
    public static let frontmatterDelimiter = Frontmatter.delimiter

    /// Parses a standalone YAML document (e.g. `.mdsync/config.yaml`) with the
    /// same scalar rules as frontmatter: text preserved, no type resolution.
    public static func parseYAML(_ text: String) throws(CodecError) -> YAMLValue {
        try YAMLReader.parse(text)
    }

    /// Parses a markdown note.
    public static func parse(_ text: String) throws(CodecError) -> ParsedNote {
        guard let split = Frontmatter.split(text) else {
            if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") { throw .unterminatedFrontmatter }
            return ParsedNote(hasFrontmatter: false, fields: [], contact: nil, body: text, layout: nil, usesCRLF: false)
        }
        let fields: [YAMLField]
        let parsed = try YAMLReader.parseReportingAnchors(split.yaml)
        switch parsed.value {
        case .mapping(let mapping): fields = mapping
        case .null: fields = []
        default: throw .notAMapping
        }
        // Span patching needs every top-level key found by the line scanner to
        // match the real parse, and no anchors (a kept `*alias` could dangle).
        let usesAnchors = parsed.usesAnchors || YAMLLayout.mayUseAnchors(split.yaml)
        var layout = usesAnchors ? nil : YAMLLayout(scanning: split.yaml)
        if layout?.keys != fields.map(\.key) { layout = nil }
        return ParsedNote(
            hasFrontmatter: true,
            fields: fields,
            contact: ContactDecoding.contact(from: fields, body: split.body),
            body: split.body,
            layout: layout,
            usesCRLF: split.usesCRLF
        )
    }

    /// The contact as the codec will store it: strings trimmed, empty values
    /// dropped, tags deduplicated, date text re-parsed. `encode` validates
    /// against this form, so callers comparing contacts should normalize too.
    public static func normalize(_ contact: CanonicalContact) -> CanonicalContact {
        Normalizer.normalize(contact)
    }

    /// Encodes `contact` as a complete markdown file.
    ///
    /// - Parameter original: the previous parse of the same file, to patch in
    ///   place. `nil` for a new file.
    /// - Throws: `CodecError.unresolvedRecordReference` for `.record` targets;
    ///   `.roundTripMismatch` if the output would not read back as `contact`.
    public static func encode(
        _ contact: CanonicalContact, patching original: ParsedNote? = nil
    ) throws(CodecError)
        -> String
    {
        if contact.relationships.contains(where: { if case .record = $0.target { true } else { false } }) {
            throw .unresolvedRecordReference
        }
        let intended = normalize(contact)
        let yaml: String
        if let original, let layout = original.layout, let previous = original.contact {
            yaml = patch(layout: layout, previous: previous, with: intended)
        } else {
            yaml = fresh(intended)
        }
        let text = Frontmatter.join(yaml: yaml, body: intended.body ?? "", useCRLF: original?.usesCRLF ?? false)
        try validate(text, intended: intended)
        return text
    }

    // MARK: - Emission

    private static func fresh(_ contact: CanonicalContact) -> String {
        let managed = ManagedKeys.all.compactMap { key in key.emit(contact).map { YAMLWriter.entry(key.name, $0) } }
        let unknown = contact.passthrough.map { YAMLWriter.entry($0.key, $0.value) }
        return (managed + unknown).joined()
    }

    private static func patch(
        layout: YAMLLayout, previous: CanonicalContact, with contact: CanonicalContact
    )
        -> String
    {
        let managed = Dictionary(uniqueKeysWithValues: ManagedKeys.all.map { ($0.name, $0) })
        var remainingPassthrough = contact.passthrough
        var emitted = Set<String>()
        // Output pieces; managed keys remember their canonical rank so new keys
        // can be slotted in next to their neighbours.
        var pieces: [(rank: Int?, text: String)] = []

        for segment in layout.segments {
            switch segment {
            case .trivia(let text):
                pieces.append((nil, text))
            case .entry(let key, let text):
                if let spec = managed[key] {
                    guard !emitted.contains(key), let value = spec.emit(contact) else { continue }
                    emitted.insert(key)
                    let unchanged = spec.equal(previous, contact)
                    pieces.append((ManagedKeys.order[key], unchanged ? text : YAMLWriter.entry(key, value)))
                } else if let index = remainingPassthrough.firstIndex(where: { $0.key == key }) {
                    let field = remainingPassthrough.remove(at: index)
                    let original = previous.passthrough.first { $0.key == key }
                    pieces.append((nil, original == field ? text : YAMLWriter.entry(field.key, field.value)))
                }
            }
        }

        for spec in ManagedKeys.all where !emitted.contains(spec.name) {
            guard let value = spec.emit(contact), let rank = ManagedKeys.order[spec.name] else { continue }
            let entry = (Optional(rank), YAMLWriter.entry(spec.name, value))
            // After the nearest earlier managed key; at the end when no later
            // managed key exists; else before the first later one.
            let hasLater = pieces.contains { piece in piece.rank.map { $0 > rank } ?? false }
            if hasLater, let after = pieces.lastIndex(where: { piece in piece.rank.map { $0 < rank } ?? false }) {
                pieces.insert(entry, at: after + 1)
            } else if let before = pieces.firstIndex(where: { piece in piece.rank.map { $0 > rank } ?? false }) {
                pieces.insert(entry, at: before)
            } else {
                pieces.append(entry)
            }
        }
        pieces += remainingPassthrough.map { (nil, YAMLWriter.entry($0.key, $0.value)) }
        return pieces.map(\.text).joined()
    }

    // MARK: - Validation

    private static func validate(_ text: String, intended: CanonicalContact) throws(CodecError) {
        let reread = try parse(text)
        guard let decoded = reread.contact else { throw .roundTripMismatch(fields: ["type"]) }
        guard decoded != intended else { return }
        throw .roundTripMismatch(fields: differingKeys(decoded, intended))
    }

    /// Top-level keys on which two contacts differ (`body`, `passthrough` included).
    public static func differingKeys(_ lhs: CanonicalContact, _ rhs: CanonicalContact) -> [String] {
        var keys = ManagedKeys.all.filter { !$0.equal(lhs, rhs) }.map(\.name)
        if lhs.body != rhs.body { keys.append("body") }
        if lhs.passthrough != rhs.passthrough { keys.append("other keys") }
        return keys
    }
}
