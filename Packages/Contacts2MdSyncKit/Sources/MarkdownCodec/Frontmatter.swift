/// A markdown file split into its YAML frontmatter and body.
public struct FrontmatterSplit: Hashable, Sendable {
    /// The YAML between the `---` delimiters (no delimiters), `\n` line endings.
    public var yaml: String
    /// Everything after the closing delimiter line, byte-exact.
    public var body: String
    /// `true` when the file used `\r\n` line endings in its frontmatter.
    public var usesCRLF: Bool
}

/// Splitting and joining of `---` frontmatter blocks.
public enum Frontmatter {
    /// The delimiter line.
    public static let delimiter = "---"

    /// Splits `text`, or returns `nil` when it has no frontmatter block (no
    /// opening `---` on the first line, or no closing `---`/`...` line).
    public static func split(_ text: String) -> FrontmatterSplit? {
        var rest = Substring(text)
        if rest.hasPrefix("\u{FEFF}") { rest = rest.dropFirst() }
        guard let firstLineEnd = rest.firstIndex(where: \.isNewline) else { return nil }
        guard rest[..<firstLineEnd].trimmingTrailingSpaces() == delimiter else { return nil }
        let usesCRLF = rest[firstLineEnd] == "\r\n"
        var cursor = rest.index(after: firstLineEnd)
        var yamlLines: [Substring] = []
        while cursor < rest.endIndex {
            let lineEnd = rest[cursor...].firstIndex(where: \.isNewline) ?? rest.endIndex
            let line = rest[cursor..<lineEnd]
            let trimmed = line.trimmingTrailingSpaces()
            if trimmed == delimiter || trimmed == "..." {
                let bodyStart = lineEnd < rest.endIndex ? rest.index(after: lineEnd) : lineEnd
                let yaml = yamlLines.map { $0 + "\n" }.joined()
                return FrontmatterSplit(yaml: yaml, body: String(rest[bodyStart...]), usesCRLF: usesCRLF)
            }
            yamlLines.append(line)
            cursor = lineEnd < rest.endIndex ? rest.index(after: lineEnd) : lineEnd
        }
        return nil
    }

    /// Joins YAML (with `\n` endings) and a body into a file.
    public static func join(yaml: String, body: String, useCRLF: Bool = false) -> String {
        var frontmatter = delimiter + "\n" + yaml + delimiter + "\n"
        if useCRLF { frontmatter = frontmatter.replacingNewlines(with: "\r\n") }
        return frontmatter + body
    }
}

extension Substring {
    func trimmingTrailingSpaces() -> Substring {
        var end = endIndex
        while end > startIndex, let previous = self[..<end].last, previous == " " || previous == "\t" {
            end = index(before: end)
        }
        return self[startIndex..<end]
    }
}

extension String {
    func replacingNewlines(with ending: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false).joined(separator: ending)
    }
}
