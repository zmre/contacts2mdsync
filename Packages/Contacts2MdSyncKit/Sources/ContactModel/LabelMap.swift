internal import Foundation

/// Apple ⇄ markdown label mapping for multi-value fields
/// (markdown-schema §2, "Label mapping").
///
/// Apple stores well-known labels as `_$!<Name>!$_` constants; we spell them
/// as short snake_case words. Custom labels become snake_case on export.
/// `nil` (no label) maps to a bare list item and back.
public enum LabelMap {
    /// Apple constants, as their raw string values (no Contacts import here).
    public enum Apple {
        public static let home = "_$!<Home>!$_"
        public static let work = "_$!<Work>!$_"
        public static let school = "_$!<School>!$_"
        public static let other = "_$!<Other>!$_"
        public static let mobile = "_$!<Mobile>!$_"
        public static let iPhone = "iPhone"
        public static let appleWatch = "Apple Watch"
        public static let main = "_$!<Main>!$_"
        public static let homeFax = "_$!<HomeFAX>!$_"
        public static let workFax = "_$!<WorkFAX>!$_"
        public static let otherFax = "_$!<OtherFAX>!$_"
        public static let pager = "_$!<Pager>!$_"
        public static let homePage = "_$!<HomePage>!$_"
        public static let iCloud = "iCloud"
        public static let anniversary = "_$!<Anniversary>!$_"
    }

    /// Well-known pairs, Apple → markdown. Order matters only for readability.
    public static let wellKnown: [(apple: String, markdown: String)] = [
        (Apple.mobile, "mobile"),
        (Apple.iPhone, "iphone"),
        (Apple.appleWatch, "apple_watch"),
        (Apple.main, "main"),
        (Apple.home, "home"),
        (Apple.work, "work"),
        (Apple.other, "other"),
        (Apple.homeFax, "home_fax"),
        (Apple.workFax, "work_fax"),
        (Apple.otherFax, "other_fax"),
        (Apple.pager, "pager"),
        (Apple.homePage, "homepage"),
        (Apple.iCloud, "icloud"),
        (Apple.school, "school"),
        (Apple.anniversary, "anniversary"),
    ]

    private static let appleToMarkdown = Dictionary(uniqueKeysWithValues: wellKnown.map { ($0.apple, $0.markdown) })
    private static let markdownToApple = Dictionary(uniqueKeysWithValues: wellKnown.map { ($0.markdown, $0.apple) })

    /// The markdown label for an Apple label. Unknown `_$!<Name>!$_` constants
    /// and custom labels become snake_case; `nil`/empty stays `nil`.
    public static func markdownLabel(fromApple label: String?) -> String? {
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let known = appleToMarkdown[label] { return known }
        let snake = snakeCase(unwrapAppleConstant(label) ?? label)
        return snake.isEmpty ? nil : snake
    }

    /// The Apple label for a markdown label. Well-known labels map to Apple
    /// constants; others become a readable custom label (`summer_house` →
    /// `Summer House`). When `existing` (the Apple label currently on the
    /// value) already maps to `label`, it is returned unchanged so labels never
    /// flap and custom casing survives.
    public static func appleLabel(fromMarkdown label: String?, existing: String? = nil) -> String? {
        guard let label, !label.isEmpty else { return nil }
        if let existing, markdownLabel(fromApple: existing) == snakeCase(label) { return existing }
        if let known = markdownToApple[snakeCase(label)] { return known }
        return humanize(label)
    }

    /// `"Summer House"` → `"summer_house"`: lowercased, runs of anything that
    /// is not a letter or digit become one `_`, trimmed of `_`.
    public static func snakeCase(_ text: String) -> String {
        var result = ""
        var pendingSeparator = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !result.isEmpty { result.append("_") }
                pendingSeparator = false
                result.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    /// `"summer_house"` → `"Summer House"`.
    public static func humanize(_ label: String) -> String {
        label.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// `"_$!<Home>!$_"` → `"Home"`; `nil` when not an Apple constant.
    public static func unwrapAppleConstant(_ label: String) -> String? {
        guard label.hasPrefix("_$!<"), label.hasSuffix(">!$_"), label.count > 8 else { return nil }
        return String(label.dropFirst(4).dropLast(4))
    }

    /// Social-profile / IM label: the service name in snake_case
    /// (`LinkedIn` → `linkedin`), else the mapped value label.
    public static func serviceLabel(service: String?, label: String?) -> String? {
        if let service, !snakeCase(service).isEmpty { return snakeCase(service) }
        return markdownLabel(fromApple: label)
    }
}

/// Apple relation label ⇄ mbr relationship `type` + `label` (markdown-schema §6).
public enum RelationLabelMap {
    private static let table: [String: (type: String, label: String?)] = [
        "father": ("parent", "father"),
        "mother": ("parent", "mother"),
        "parent": ("parent", nil),
        "son": ("child", "son"),
        "daughter": ("child", "daughter"),
        "child": ("child", nil),
        "spouse": ("spouse", nil),
        "husband": ("spouse", "husband"),
        "wife": ("spouse", "wife"),
        "partner": ("spouse", "partner"),
        "brother": ("sibling", "brother"),
        "sister": ("sibling", "sister"),
        "sibling": ("sibling", nil),
        "manager": ("reports_to", nil),
        "assistant": ("assistant", nil),
    ]

    /// Maps an Apple relation label (constant or custom) to an mbr type and
    /// optional label. Unknown labels become a snake_case custom type; a
    /// missing label becomes `related`.
    public static func mbr(fromApple label: String?) -> (type: String, label: String?) {
        guard let label, !label.isEmpty else { return ("related", nil) }
        let word = LabelMap.snakeCase(LabelMap.unwrapAppleConstant(label) ?? label)
        if let known = table[word] { return known }
        return (word.isEmpty ? "related" : word, nil)
    }

    /// Maps an mbr type + label back to an Apple relation label
    /// (`_$!<Father>!$_`, …). Custom types become humanized custom labels.
    public static func apple(type: String, label: String?) -> String {
        let type = LabelMap.snakeCase(type)
        if let label, let entry = table[LabelMap.snakeCase(label)], entry.type == type {
            return constant(LabelMap.snakeCase(label))
        }
        switch type {
        case "parent", "child", "spouse", "sibling", "assistant": return constant(type)
        case "reports_to": return constant("manager")
        default: return LabelMap.humanize(type)
        }
    }

    private static func constant(_ word: String) -> String {
        "_$!<\(word.prefix(1).uppercased() + word.dropFirst())>!$_"
    }
}
