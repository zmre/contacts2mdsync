internal import ContactModel
internal import Yams

/// Encodes and decodes contacts to and from markdown files with YAML
/// frontmatter, preserving any user-authored body content untouched.
public enum MarkdownCodec {
    /// The `ContactModel` schema version this codec reads and writes.
    public static let supportedSchemaVersion = ContactModel.schemaVersion

    /// Delimiter that opens and closes a YAML frontmatter block.
    public static let frontmatterDelimiter = "---"

    /// Round-trips a trivial mapping through Yams. Exists so M0 proves the
    /// dependency resolves, links, and runs; replaced by the real codec in M1.
    public static func yamlSmokeTest() throws -> Bool {
        let yaml = try Yams.dump(object: ["schema": supportedSchemaVersion])
        let decoded = try Yams.load(yaml: yaml) as? [String: Int]
        return decoded?["schema"] == supportedSchemaVersion
    }
}
