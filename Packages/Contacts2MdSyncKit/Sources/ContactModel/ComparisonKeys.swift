internal import Foundation

/// Turns a phone number's display form into its comparison key.
///
/// The production implementation (`PhoneNumberKeys.PhoneNumberKitKeyer`)
/// yields E.164 using a configurable default region; `DigitsPhoneKeyer` is the
/// dependency-free fallback used for unparsable numbers and in tests.
public protocol PhoneKeyer: Sendable {
    /// The comparison key for `raw` (E.164 when parseable, else digits).
    func key(for raw: String) -> String
}

/// Fallback phone keyer: keeps a leading `+` and the digits, and renders an
/// extension (`x123`, `ext. 123`, `;ext=123`) as `;ext=123`.
public struct DigitsPhoneKeyer: PhoneKeyer {
    /// Creates the keyer.
    public init() {}

    public func key(for raw: String) -> String {
        let (main, ext) = Self.splitExtension(raw)
        let trimmed = main.trimmingCharacters(in: .whitespaces)
        var key = trimmed.hasPrefix("+") ? "+" : ""
        key += main.filter(\.isASCIIDigit)
        if let ext, !ext.isEmpty { key += ";ext=\(ext)" }
        return key
    }

    /// Splits `raw` at an extension marker (`;ext=`, `ext`, `x`, `#`),
    /// returning the main part and the extension's digits.
    public static func splitExtension(_ raw: String) -> (main: String, ext: String?) {
        let lower = raw.lowercased()
        for marker in [";ext=", "extension", "ext.", "ext", "x", "#"] {
            guard let range = lower.range(of: marker, options: .backwards) else { continue }
            let tail = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let digits = tail.filter(\.isASCIIDigit)
            // Only a marker followed by nothing but digits is an extension.
            guard !digits.isEmpty, digits.count == tail.count else { continue }
            let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
            return (String(raw.prefix(offset)), digits)
        }
        return (raw, nil)
    }
}

/// Normalized comparison keys (architecture §3). Display values are never
/// rewritten just because their key is unchanged.
public enum ComparisonKeys {
    /// Email: trimmed, lowercased.
    public static func email(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Phone: delegated to a `PhoneKeyer` (E.164 or digits fallback).
    public static func phone(_ value: String, keyer: any PhoneKeyer) -> String {
        keyer.key(for: value)
    }

    /// URL: lowercase scheme and host, default port and trailing `/` dropped.
    /// Non-URLs fall back to trimmed text.
    public static func url(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            components.host != nil
        else { return trimmed }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        var result = components.string ?? trimmed
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// One address component: NFC, case-folded, whitespace collapsed.
    public static func addressComponent(_ value: String?) -> String {
        guard let value else { return "" }
        return collapseWhitespace(value.precomposedStringWithCanonicalMapping.lowercased())
    }

    /// A whole address, component by component; `country_code` uppercased.
    public static func address(_ value: PostalAddress) -> String {
        if let formatted = value.formatted { return addressComponent(formatted) }
        let parts = [value.street, value.city, value.region, value.postcode, value.country].map(addressComponent)
        return (parts + [(value.countryCode ?? "").uppercased()]).joined(separator: "|")
    }

    /// Name / title (matching only): NFC, case-folded, diacritic-folded,
    /// whitespace collapsed.
    public static func name(_ value: String) -> String {
        let folded = value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return collapseWhitespace(folded)
    }

    /// Date: `YYYY-MM-DD` or `--MM-DD` (see `PartialDate.iso`).
    public static func date(_ value: PartialDate) -> String { value.iso }

    /// Body: `\r\n` → `\n`, trailing whitespace trimmed.
    public static func body(_ value: String?) -> String {
        guard let value else { return "" }
        var text = value.replacingOccurrences(of: "\r\n", with: "\n")
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    /// Tag: mbr normalization (trim, lowercase, spaces → `_`).
    public static func tag(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
