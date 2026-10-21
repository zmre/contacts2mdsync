/// A framework-free YAML value, used for data the engine carries but does not
/// interpret: unknown frontmatter keys, extra relationship attributes and
/// unknown `apple:` sub-keys.
///
/// Scalars keep their text exactly as YAML resolved it plus whether they were
/// written plain (unquoted) so that re-emitting a value never changes how mbr
/// types it (`count: 3` stays an integer, `"3"` stays a string).
public indirect enum YAMLValue: Hashable, Sendable, Codable {
    /// `~`, `null` or an empty value.
    case null
    /// A scalar's text; `plain` is `false` for quoted and block scalars.
    case scalar(String, plain: Bool)
    /// A block or flow sequence.
    case sequence([YAMLValue])
    /// A mapping, in authored order.
    case mapping([YAMLField])

    /// A quoted (always-string) scalar.
    public static func string(_ text: String) -> YAMLValue { .scalar(text, plain: false) }

    /// The scalar text, if this is a scalar.
    public var scalarText: String? {
        if case .scalar(let text, _) = self { return text }
        return nil
    }
}

/// One `key: value` pair of a `YAMLValue.mapping`.
public struct YAMLField: Hashable, Sendable, Codable {
    /// The mapping key as text.
    public var key: String
    /// The value.
    public var value: YAMLValue

    /// Creates a field.
    public init(key: String, value: YAMLValue) {
        self.key = key
        self.value = value
    }
}
