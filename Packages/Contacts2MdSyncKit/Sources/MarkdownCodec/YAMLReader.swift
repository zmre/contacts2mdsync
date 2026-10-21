internal import ContactModel
internal import Yams

/// Parses YAML text into framework-free `YAMLValue`s via Yams.
///
/// Only Yams' *parser* is used. Scalars keep their source text (no type
/// resolution), so `0123`, `no` and `1980-03-19` read back exactly as written.
enum YAMLReader {
    /// Parses one YAML document. Empty text is an empty mapping. Anchors and
    /// aliases are resolved (expanded); `usesAnchors` reports whether any were
    /// present, since such text cannot be patched span-by-span.
    static func parse(_ yaml: String) throws(CodecError) -> YAMLValue {
        try parseReportingAnchors(yaml).value
    }

    static func parseReportingAnchors(_ yaml: String) throws(CodecError) -> (value: YAMLValue, usesAnchors: Bool) {
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            throw .invalidYAML(String(describing: error))
        }
        guard let node else { return (.mapping([]), false) }
        var usesAnchors = false
        let value = try value(node, usesAnchors: &usesAnchors)
        return (value, usesAnchors)
    }

    private static func value(_ node: Node, usesAnchors: inout Bool) throws(CodecError) -> YAMLValue {
        if node.anchor != nil { usesAnchors = true }
        switch node {
        case .scalar(let scalar):
            if scalar.style == .plain, ["", "~", "null", "Null", "NULL"].contains(scalar.string) { return .null }
            return .scalar(scalar.string, plain: scalar.style == .plain)
        case .sequence(let sequence):
            var items: [YAMLValue] = []
            for item in sequence { items.append(try value(item, usesAnchors: &usesAnchors)) }
            return .sequence(items)
        case .mapping(let mapping):
            var fields: [YAMLField] = []
            for (key, entry) in mapping {
                guard case .scalar(let keyScalar) = key else {
                    throw .unsupportedYAML("non-scalar mapping key")
                }
                if keyScalar.string == "<<", keyScalar.style == .plain { throw .unsupportedYAML("merge key `<<`") }
                fields.append(YAMLField(key: keyScalar.string, value: try value(entry, usesAnchors: &usesAnchors)))
            }
            return .mapping(fields)
        case .alias:
            usesAnchors = true
            throw .unsupportedYAML("unresolved YAML alias")
        }
    }
}

/// Errors from decoding or encoding a contact note.
public enum CodecError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The frontmatter is not valid YAML (mbr would ignore the whole block).
    case invalidYAML(String)
    /// Valid YAML we refuse to rewrite (aliases, merge keys, complex keys).
    case unsupportedYAML(String)
    /// The frontmatter is not a mapping.
    case notAMapping
    /// An opening `---` without a closing one.
    case unterminatedFrontmatter
    /// Emitted text did not decode back to the intended contact.
    case roundTripMismatch(fields: [String])
    /// A relationship still points at a `.record` id (must be resolved to a title first).
    case unresolvedRecordReference

    public var description: String {
        switch self {
        case .invalidYAML(let message): "invalid YAML frontmatter: \(message)"
        case .unsupportedYAML(let what): "unsupported YAML construct: \(what)"
        case .notAMapping: "frontmatter is not a key/value mapping"
        case .unterminatedFrontmatter: "frontmatter has no closing ---"
        case .roundTripMismatch(let fields):
            "emitted markdown does not read back identically (\(fields.joined(separator: ", "))); not written"
        case .unresolvedRecordReference: "relationship target not resolved to a title"
        }
    }
}
