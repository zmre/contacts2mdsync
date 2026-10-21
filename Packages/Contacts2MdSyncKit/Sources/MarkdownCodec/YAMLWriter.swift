public import ContactModel

/// Our own block-style YAML emitter.
///
/// We do not use Yams' emitter for anything that lands in a note: its output
/// (quoting, wrapping, indentation) is not under our control and could shift
/// between versions, producing diff noise in users' notes. This writer is
/// small, deterministic and matches markdown-schema §1 byte for byte.
///
/// Layout: two-space indentation, block sequences indented under their key
/// (`emails:\n  - work: x`), one-key list items written inline (`- home:`).
public enum YAMLWriter {
    /// Characters that may not start a plain scalar (YAML indicators).
    private static let indicatorStarts: Set<Character> = [
        "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`",
    ]

    /// Plain words YAML 1.1 or 1.2 resolve to booleans/null (compared lowercased).
    private static let reservedWords: Set<String> = [
        "y", "n", "yes", "no", "on", "off", "true", "false", "null", "~", "=", "<<",
    ]

    /// A scalar for a managed value: plain when that is unambiguous, otherwise
    /// double-quoted. `forceQuotes` quotes regardless (phones, postcodes, dates).
    public static func scalar(_ text: String, forceQuotes: Bool = false) -> YAMLValue {
        .scalar(text, plain: !forceQuotes && isPlainSafe(text))
    }

    /// `true` when `text` reads back as the same **string** when written plain
    /// in YAML 1.1 and 1.2 (so mbr's yaml-rust2 and Yams agree): not empty, no
    /// edge whitespace, no indicator start, no `: ` / ` #`, not a bool/null
    /// word, not number-like.
    public static func isPlainSafe(_ text: String) -> Bool {
        guard isStructurallyPlainSafe(text) else { return false }
        if reservedWords.contains(text.lowercased()) { return false }
        return !looksNumeric(text)
    }

    /// `true` when `text` can be written plain without changing its *text*
    /// (it may still resolve to a number/bool — used for values that were
    /// authored plain and must stay so).
    public static func isStructurallyPlainSafe(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        if first.isWhitespace || last.isWhitespace || last == ":" { return false }
        if indicatorStarts.contains(first) {
            // `-5` / `-.5` are fine plain (negative numbers), `- x` / `-x` are not.
            guard first == "-", text.dropFirst().first.map({ $0.isASCIIDigit || $0 == "." }) == true else {
                return false
            }
        }
        if text.contains(": ") || text.contains(" #") { return false }
        return !text.unicodeScalars.contains(where: needsEscape)
    }

    private static func looksNumeric(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if first.isASCIIDigit { return true }
        if first == "+" || first == "-" {
            let second = text.dropFirst().first
            return second?.isASCIIDigit == true || second == "."
        }
        let lower = text.lowercased()
        if first == "." {
            let second = text.dropFirst().first
            return second?.isASCIIDigit == true || lower == ".inf" || lower == ".nan"
        }
        return false
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x85, 0x2028, 0x2029, 0xFEFF: true
        case 0x80...0x9F: true
        default: false
        }
    }

    /// Named escapes for double-quoted scalars.
    private static let escapes: [Unicode.Scalar: String] = [
        "\\": "\\\\", "\"": "\\\"", "\n": "\\n", "\t": "\\t", "\r": "\\r",
        "\u{85}": "\\N", "\u{2028}": "\\L", "\u{2029}": "\\P", "\u{FEFF}": "\\uFEFF",
    ]

    /// `text` as a double-quoted YAML scalar.
    public static func doubleQuoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            if let escape = escapes[scalar] {
                out += escape
            } else if needsEscape(scalar) {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                out += "\\x" + String(repeating: "0", count: max(0, 2 - hex.count)) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A mapping key: plain when safe, else double-quoted.
    public static func key(_ text: String) -> String {
        isPlainSafe(text) ? text : doubleQuoted(text)
    }

    /// Inline text of a scalar value.
    static func inline(_ text: String, plain: Bool) -> String {
        plain && isStructurallyPlainSafe(text) ? text : doubleQuoted(text)
    }

    /// One `key: value` entry at `indent` spaces, with trailing newline.
    public static func entry(_ key: String, _ value: YAMLValue, indent: Int = 0) -> String {
        entry(key: key, value: value, indent: indent, linePrefix: String(repeating: " ", count: indent))
    }

    private static func entry(key: String, value: YAMLValue, indent: Int, linePrefix: String) -> String {
        let head = linePrefix + self.key(key) + ":"
        switch value {
        case .null:
            return head + "\n"
        case .scalar(let text, let plain):
            return head + " " + inline(text, plain: plain) + "\n"
        case .sequence(let items) where items.isEmpty:
            return head + " []\n"
        case .mapping(let fields) where fields.isEmpty:
            return head + " {}\n"
        case .sequence(let items):
            return head + "\n" + items.map { item($0, indent: indent + 2) }.joined()
        case .mapping(let fields):
            return head + "\n" + fields.map { entry($0.key, $0.value, indent: indent + 2) }.joined()
        }
    }

    /// One `- value` sequence item at `indent` spaces.
    public static func item(_ value: YAMLValue, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null:
            return pad + "-\n"
        case .scalar(let text, let plain):
            return pad + "- " + inline(text, plain: plain) + "\n"
        case .sequence(let items) where items.isEmpty:
            return pad + "- []\n"
        case .mapping(let fields) where fields.isEmpty:
            return pad + "- {}\n"
        case .sequence(let items):
            return pad + "-\n" + items.map { item($0, indent: indent + 2) }.joined()
        case .mapping(let fields):
            // First pair shares the dash line; the rest align under it.
            var out = entry(key: fields[0].key, value: fields[0].value, indent: indent + 2, linePrefix: pad + "- ")
            for field in fields.dropFirst() {
                out += entry(field.key, field.value, indent: indent + 2)
            }
            return out
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
