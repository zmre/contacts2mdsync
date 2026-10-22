internal import Foundation

/// Whether two contacts' person names could belong to the same person
/// (architecture §6, "Name compatibility").
///
/// Shared phone numbers and emails are household signals: spouses share a
/// home phone, couples share an email. They count toward "same person" only
/// when the names agree. Names are compatible when:
///
/// - either side has no person name (organization-only or empty), or
/// - the family names agree (equal comparison keys, one hyphenated or
///   compound part of the other, or a maiden name) **and** the given names
///   agree: equal, one an initial or prefix of the other (`J.` / `James`,
///   `Chris` / `Christopher`), a known nickname pair (`Bob` / `Robert`),
///   or one of them empty.
///
/// Same family name with two different given names (spouses, siblings) is
/// explicitly incompatible. All comparisons are case- and diacritic-folded.
public enum NameCompatibility {
    /// The ways one contact's person name may be spelled.
    public struct Profile: Hashable, Sendable {
        /// Alternative `(given, family)` spellings, folded. Empty: no person name.
        public var spellings: [NameSpelling]

        /// `true` without any person name.
        public var isEmpty: Bool { spellings.isEmpty }

        /// The person name of `contact`: its name parts, its maiden name
        /// (`previousFamilyName`) as an alternative family name, its nickname
        /// as an alternative given name, and its aliases. With `titleFallback`
        /// (hand-written notes, which often have only a `title:`), a person
        /// without name parts is read from the title (`Jane Doe` → Jane / Doe).
        public init(_ contact: CanonicalContact, titleFallback: Bool = false) {
            guard contact.kind == .person else {
                spellings = []
                return
            }
            var given = NameCompatibility.fold(contact.name.given)
            var family = NameCompatibility.fold(contact.name.family)
            if given.isEmpty, family.isEmpty, let middle = contact.name.middle {
                given = NameCompatibility.fold(middle)
            }
            if given.isEmpty, family.isEmpty, titleFallback {
                (given, family) = NameCompatibility.split(contact.title)
            }
            guard !given.isEmpty || !family.isEmpty else {
                spellings = []
                return
            }
            let primary = NameSpelling(given: given, family: family)
            var seen = Set<NameSpelling>()
            spellings = ([primary] + contact.aliases.compactMap { Self.spelling(of: $0, primary: primary) })
                .filter { seen.insert($0).inserted }
        }

        /// The alternative spelling an alias stands for: a maiden name
        /// replaces the family name, a nickname the given name; a plain
        /// alias with two words is a full name.
        static func spelling(of alias: Alias, primary: NameSpelling) -> NameSpelling? {
            let (aliasGiven, aliasFamily) = NameCompatibility.split(alias.name)
            switch alias.label {
            case Alias.maidenNameLabel:
                // Apple stores only the previous family name; hand-written
                // notes sometimes put the whole maiden name there.
                let maiden = aliasFamily.isEmpty ? aliasGiven : aliasFamily
                return maiden.isEmpty ? nil : NameSpelling(given: primary.given, family: maiden)
            case Alias.nicknameLabel:
                guard !aliasGiven.isEmpty, aliasFamily.isEmpty else { return nil }
                return NameSpelling(given: aliasGiven, family: primary.family)
            default:
                guard !aliasGiven.isEmpty, !aliasFamily.isEmpty else { return nil }
                return NameSpelling(given: aliasGiven, family: aliasFamily)
            }
        }

        /// A profile from explicit spellings (tests, previews).
        public init(given: String?, family: String?) {
            let spelling = NameSpelling(given: NameCompatibility.fold(given), family: NameCompatibility.fold(family))
            spellings = spelling.given.isEmpty && spelling.family.isEmpty ? [] : [spelling]
        }

        /// The primary spelling.
        public var primary: NameSpelling? { spellings.first }
    }

    /// The outcome of comparing two profiles.
    public enum Verdict: Hashable, Sendable {
        /// At least one side has no person name.
        case noPersonName
        /// The names agree; `detail` says how (`Jane / Jane`, `Bob / Robert`).
        case compatible(detail: String)
        /// Different people (spouses, siblings) or simply different names.
        case incompatible(detail: String)

        /// `true` unless incompatible.
        public var isCompatible: Bool {
            if case .incompatible = self { return false }
            return true
        }
    }

    /// `true` when `lhs` and `rhs` could be the same person.
    public static func compatible(_ lhs: CanonicalContact, _ rhs: CanonicalContact) -> Bool {
        verdict(Profile(lhs), Profile(rhs)).isCompatible
    }

    /// Compares two profiles: compatible when any pair of spellings agrees.
    public static func verdict(_ lhs: Profile, _ rhs: Profile) -> Verdict {
        guard let left = lhs.primary, let right = rhs.primary else { return .noPersonName }
        for first in lhs.spellings {
            for second in rhs.spellings where spellingsAgree(first, second) {
                return .compatible(detail: describe(first, second))
            }
        }
        return .incompatible(detail: describe(left, right))
    }

    // MARK: - Rules

    static func spellingsAgree(_ lhs: NameSpelling, _ rhs: NameSpelling) -> Bool {
        let familyAgrees = lhs.family.isEmpty || rhs.family.isEmpty || familiesAgree(lhs.family, rhs.family)
        guard familyAgrees else { return false }
        // Two bare family names ("Müller" / "Müller") agree; a bare family name
        // never matches a bare given name.
        if lhs.given.isEmpty || rhs.given.isEmpty {
            return !(lhs.given.isEmpty && rhs.family.isEmpty) && !(rhs.given.isEmpty && lhs.family.isEmpty)
        }
        return givenNamesAgree(lhs.given, rhs.given)
    }

    /// Equal, or one hyphenated/compound family name contains the other
    /// (`Garcia-Lopez` / `Garcia`, `van der Berg` / `Berg`), ignoring particles.
    public static func familiesAgree(_ lhs: String, _ rhs: String) -> Bool {
        let left = fold(lhs)
        let right = fold(rhs)
        if left == right { return true }
        let leftParts = familyParts(left)
        let rightParts = familyParts(right)
        guard !leftParts.isEmpty, !rightParts.isEmpty else { return false }
        return leftParts.isSubset(of: rightParts) || rightParts.isSubset(of: leftParts)
    }

    /// Equal, an initial or prefix (≥ 3 letters) of the other, or a nickname pair.
    public static func givenNamesAgree(_ lhs: String, _ rhs: String) -> Bool {
        let left = fold(lhs).replacingOccurrences(of: ".", with: "")
        let right = fold(rhs).replacingOccurrences(of: ".", with: "")
        if left == right { return true }
        let leftFirst = firstWord(left)
        let rightFirst = firstWord(right)
        guard !leftFirst.isEmpty, !rightFirst.isEmpty else { return false }
        if leftFirst == rightFirst { return true }
        let (short, long) = leftFirst.count <= rightFirst.count ? (leftFirst, rightFirst) : (rightFirst, leftFirst)
        if long.hasPrefix(short), short.count == 1 || short.count >= 3 { return true }
        return !Nicknames.canonical(leftFirst).isDisjoint(with: Nicknames.canonical(rightFirst))
    }

    // MARK: - Folding

    /// Case-, diacritic- and width-folded, whitespace collapsed (`ComparisonKeys.name`).
    public static func fold(_ value: String?) -> String {
        guard let value else { return "" }
        return ComparisonKeys.name(value)
    }

    /// `Jane Q. Doe` → (`jane`, `doe`); one word → (word, ``).
    static func split(_ text: String) -> (given: String, family: String) {
        let words = fold(text).split(separator: " ").map(String.init)
        guard let first = words.first else { return ("", "") }
        guard words.count > 1, let last = words.last else { return (first, "") }
        return (first, last)
    }

    private static func firstWord(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init) ?? ""
    }

    private static let particles: Set<String> = [
        "de", "del", "della", "der", "den", "di", "da", "dos", "das", "du", "la", "le", "van", "von", "y", "e",
        "st", "st.", "bin", "ibn", "al",
    ]

    private static func familyParts(_ value: String) -> Set<String> {
        Set(
            value.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
                .filter { !particles.contains($0) })
    }

    private static func describe(_ lhs: NameSpelling, _ rhs: NameSpelling) -> String {
        func show(_ spelling: NameSpelling) -> String {
            let name = spelling.given.isEmpty ? spelling.family : spelling.given
            return name.isEmpty ? "—" : name.capitalized
        }
        return "\(show(lhs)) / \(show(rhs))"
    }
}

/// A folded given/family pair (either may be empty).
public struct NameSpelling: Hashable, Sendable {
    public var given: String
    public var family: String
}

/// A small table of common English given-name nicknames.
///
/// `canonical(name)` is the set of formal names `name` may stand for (a
/// formal name stands for itself). Two given names are a nickname pair when
/// those sets meet, so `Bob` ~ `Robert` ~ `Rob`, but `Christopher` and
/// `Christine` stay different although both are `Chris`.
public enum Nicknames {
    /// Nickname → formal names.
    static let table: [String: [String]] = [
        "abby": ["abigail"], "al": ["albert", "alan", "alfred"], "alex": ["alexander", "alexandra"],
        "alexa": ["alexandra"], "allie": ["allison", "alexandra"], "andy": ["andrew"], "angie": ["angela"],
        "barb": ["barbara"], "becky": ["rebecca"], "ben": ["benjamin"], "beth": ["elizabeth"],
        "betsy": ["elizabeth"], "betty": ["elizabeth"], "bill": ["william"], "billy": ["william"],
        "bob": ["robert"], "bobby": ["robert"], "cathy": ["catherine", "katherine"], "charlie": ["charles"],
        "chris": ["christopher", "christine", "christina", "christian"], "chuck": ["charles"],
        "cindy": ["cynthia"], "dan": ["daniel"], "danny": ["daniel"], "dave": ["david"], "deb": ["deborah"],
        "debbie": ["deborah"], "dick": ["richard"], "don": ["donald"], "doug": ["douglas"], "ed": ["edward"],
        "eddie": ["edward"], "fred": ["frederick"], "gabe": ["gabriel"], "greg": ["gregory"], "hank": ["henry"],
        "jack": ["john"], "jake": ["jacob"], "jan": ["janet", "janice"], "jeff": ["jeffrey"],
        "jen": ["jennifer"], "jenny": ["jennifer"], "jerry": ["gerald", "jerome"], "jim": ["james"],
        "jimmy": ["james"], "joe": ["joseph"], "joey": ["joseph"], "john": ["jonathan"], "jon": ["jonathan"],
        "josh": ["joshua"], "judy": ["judith"], "kate": ["katherine", "catherine", "kathleen"],
        "kathy": ["katherine", "kathleen"], "katie": ["katherine", "kathleen"], "ken": ["kenneth"],
        "kim": ["kimberly"], "larry": ["lawrence"], "len": ["leonard"], "liz": ["elizabeth"],
        "lizzie": ["elizabeth"], "maggie": ["margaret"], "matt": ["matthew"], "meg": ["margaret"],
        "mike": ["michael"], "mickey": ["michael"], "mitch": ["mitchell"], "nate": ["nathan", "nathaniel"],
        "nick": ["nicholas"], "nicky": ["nicholas", "nicole"], "pam": ["pamela"],
        "pat": ["patrick", "patricia"], "patty": ["patricia"], "peg": ["margaret"], "peggy": ["margaret"],
        "pete": ["peter"], "phil": ["philip", "phillip"], "ray": ["raymond"], "rich": ["richard"],
        "rick": ["richard"], "rob": ["robert"], "robbie": ["robert"], "ron": ["ronald"], "russ": ["russell"],
        "sam": ["samuel", "samantha"], "sandy": ["sandra"], "steph": ["stephanie"],
        "steve": ["steven", "stephen"], "steven": ["stephen"], "stu": ["stuart"], "sue": ["susan"],
        "susie": ["susan"], "ted": ["edward", "theodore"], "teddy": ["edward", "theodore"],
        "terry": ["terrence", "teresa"], "tim": ["timothy"], "tom": ["thomas"], "tommy": ["thomas"],
        "tony": ["anthony"], "trish": ["patricia"], "vicky": ["victoria"], "vince": ["vincent"],
        "walt": ["walter"], "will": ["william"], "zach": ["zachary"],
    ]

    /// The formal names `name` may stand for (`name` itself included).
    public static func canonical(_ name: String) -> Set<String> {
        let key = NameCompatibility.fold(name)
        return Set([key] + (table[key] ?? []))
    }
}

/// Phone labels that belong to a household or an office rather than one
/// person: shared by spouses and colleagues, so never an identity signal.
public enum PhoneLabels {
    /// Markdown labels whose numbers are personal enough to count
    /// (with an email and agreeing names): mobile, iPhone, or no label.
    public static let personal: Set<String> = ["mobile", "iphone", "apple_watch"]

    /// `true` for `home`, `main`, `work`, `other`, faxes, pagers and custom
    /// labels; `false` for mobile / iPhone / unlabeled numbers.
    public static func isHousehold(_ label: String?) -> Bool {
        guard let label, !label.isEmpty else { return false }
        return !personal.contains(LabelMap.snakeCase(label))
    }
}
