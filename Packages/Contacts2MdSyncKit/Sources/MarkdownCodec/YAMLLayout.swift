/// The top-level layout of a block-style YAML mapping: each top-level key's
/// exact source lines, plus the comments/blank lines between them.
///
/// This is what lets us patch only the managed keys of an existing note and
/// copy everything else byte for byte. It deliberately understands only the
/// common shape (block mapping at column 0, plain or quoted keys). Anything
/// else — flow mappings, directives, complex `?` keys, document markers —
/// makes the layout `nil`, and callers fall back to a full re-emit.
public struct YAMLLayout: Hashable, Sendable {
    /// One piece of the document, in order.
    public enum Segment: Hashable, Sendable {
        /// Blank lines and full-line comments between entries.
        case trivia(String)
        /// A top-level `key:` and all its continuation lines.
        case entry(key: String, text: String)
    }

    /// The pieces, which concatenate back to the original text exactly.
    public var segments: [Segment]

    /// Top-level keys in order.
    public var keys: [String] {
        segments.compactMap {
            if case .entry(let key, _) = $0 { return key }
            return nil
        }
    }

    /// Scans `yaml` (`\n` line endings). Returns `nil` when the text is not a
    /// plain block mapping we can patch safely.
    public init?(scanning yaml: String) {
        var segments: [Segment] = []
        var trivia = ""
        var current: (key: String, text: String)?

        func flushEntry() {
            if let entry = current { segments.append(.entry(key: entry.key, text: entry.text)) }
            current = nil
        }

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false).dropLast(
            yaml.hasSuffix("\n") ? 1 : 0)
        {
            let line = String(rawLine) + "\n"
            let isBlankOrComment = rawLine.allSatisfy { $0 == " " || $0 == "\t" } || rawLine.first == "#"
            let isIndented = rawLine.first == " " || rawLine.first == "\t"
            if isIndented && !isBlankOrComment {
                // Continuation of the current entry (pending blank/comment lines
                // inside a value belong to it too).
                guard current != nil else { return nil }
                current?.text += trivia + line
                trivia = ""
                continue
            }
            if isBlankOrComment {
                trivia += line
                continue
            }
            if let first = rawLine.first, first == "-" || first == "]" || first == "}" {
                // Column-0 `- item` lines belong to the previous key
                // (`tags:\n- a`), as do closing flow brackets.
                if rawLine.hasPrefix("---") || current == nil { return nil }
                current?.text += trivia + line
                trivia = ""
                continue
            }
            guard let key = Self.topLevelKey(rawLine) else { return nil }
            flushEntry()
            if !trivia.isEmpty { segments.append(.trivia(trivia)) }
            trivia = ""
            current = (key, line)
        }
        flushEntry()
        if !trivia.isEmpty { segments.append(.trivia(trivia)) }
        if !yaml.isEmpty, !yaml.hasSuffix("\n") { return nil }
        self.segments = segments
    }

    /// Reassembled text.
    public var text: String {
        segments.map {
            switch $0 {
            case .trivia(let text): text
            case .entry(_, let text): text
            }
        }.joined()
    }

    /// Conservative textual check for YAML anchors (`&name`) or aliases
    /// (`*name`) outside quotes. False positives only cost a full re-emit.
    static func mayUseAnchors(_ yaml: String) -> Bool {
        let characters = Array(yaml)
        for index in characters.indices.dropLast() where characters[index] == "&" || characters[index] == "*" {
            let before: Character = index == 0 ? "\n" : characters[index - 1]
            let after = characters[index + 1]
            if " \t\n[{,:-".contains(before), after.isLetter || after.isNumber || after == "_" { return true }
        }
        return false
    }

    /// The key of a column-0 `key: …` line, unquoted; `nil` if the line is not one.
    static func topLevelKey(_ line: Substring) -> String? {
        guard let first = line.first else { return nil }
        if first == "\"" || first == "'" {
            guard let close = line.dropFirst().firstIndex(of: first) else { return nil }
            let after = line[line.index(after: close)...]
            guard after.first == ":", after.dropFirst().first.map({ $0 == " " }) ?? true else { return nil }
            let inner = line[line.index(after: line.startIndex)..<close]
            // Escapes inside quoted keys are rare; refuse rather than mis-decode.
            if inner.contains("\\") || (first == "'" && inner.contains("''")) { return nil }
            return String(inner)
        }
        if "?{[&*!|>%@`".contains(first) { return nil }
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " {
                    let key = line[..<index]
                    if key.hasSuffix(" ") || key.contains(" #") { return nil }
                    return String(key)
                }
            }
            index = line.index(after: index)
        }
        return nil
    }
}
