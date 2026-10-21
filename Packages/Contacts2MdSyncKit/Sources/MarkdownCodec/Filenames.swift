internal import Foundation

/// Filename rules for new contact notes (markdown-schema §5).
public enum Filenames {
    /// Maximum length of a filename stem, in characters.
    public static let maxStemLength = 120

    /// A safe filename stem for `title`: NFC-normalized; `/ : \` replaced
    /// with `-`; control characters dropped; leading dots and edge whitespace
    /// stripped; at most 120 characters. Never empty.
    public static func stem(for title: String) -> String {
        var result = ""
        for scalar in title.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "/", ":", "\\": result.unicodeScalars.append("-")
            case "\n", "\r", "\t": result.unicodeScalars.append(" ")
            default:
                if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                    continue
                }
                result.unicodeScalars.append(scalar)
            }
        }
        result = result.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        while result.hasPrefix(".") || result.hasPrefix(" ") { result.removeFirst() }
        if result.count > maxStemLength {
            result = String(result.prefix(maxStemLength)).trimmingCharacters(in: .whitespaces)
        }
        return result.isEmpty ? "Unnamed" : result
    }

    /// Picks a unique filename stem.
    ///
    /// Tries `Title`, then `Title (Company)`, then `Title 2`, `Title 3`, …
    /// `isTaken` gets lowercased stems (file systems here are case-insensitive,
    /// and mbr resolves links by stem case-insensitively).
    public static func uniqueStem(title: String, company: String?, isTaken: (String) -> Bool) -> String {
        let base = stem(for: title)
        if !isTaken(base.lowercased()) { return base }
        if let company = company?.trimmingCharacters(in: .whitespaces), !company.isEmpty,
            company.lowercased() != title.lowercased()
        {
            let withCompany = stem(for: "\(title) (\(company))")
            if !isTaken(withCompany.lowercased()) { return withCompany }
        }
        var counter = 2
        while true {
            let candidate = "\(base) \(counter)"
            if !isTaken(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }
}
