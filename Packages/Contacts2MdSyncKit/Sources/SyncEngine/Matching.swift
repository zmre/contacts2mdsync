internal import ContactModel
internal import Foundation
internal import VaultIndex

/// How strongly an Apple contact and a note look like the same person
/// (architecture §6 matching cascade, steps 3–6).
public struct MatchScore: Hashable, Sendable, Comparable {
    /// 0.9 strong key + same name, 0.7 strong key + compatible names, 0.5
    /// name + organization, 0.3 name only, or a shared email whose names
    /// disagree (`advisory`).
    public var confidence: Double
    /// Human-readable reasons (`same email`, `same name`, …).
    public var reasons: [String]
    /// A warning only: an email shared by people whose names disagree
    /// (a couple sharing an address). Never blocks a create or binds.
    public var advisory = false

    public static func < (lhs: MatchScore, rhs: MatchScore) -> Bool { lhs.confidence < rhs.confidence }

    /// Strong key and name equal: auto-bind during adoption.
    public static let adoptThreshold = 0.9
    /// Blocks auto-create (create gate).
    public static let gateThreshold = 0.5
}

/// Matching keys of one side (an Apple contact or a note).
struct MatchProfile {
    /// `email:…`, `phone:…` keys.
    var strong: Set<String>
    /// Name keys: the personal name plus, for notes, title and aliases; for
    /// Apple contacts, the generated title and name variants.
    var names: Set<String>
    /// Organization name key.
    var organization: String?
    /// The person name, for `NameCompatibility`.
    var person: NameCompatibility.Profile

    init(apple contact: CanonicalContact, keyer: any PhoneKeyer) {
        strong = Self.strongKeys(contact, keyer: keyer)
        person = NameCompatibility.Profile(contact)
        // A bare nickname ("Bob") is too weak to match on unless it is the title.
        let nickname = contact.nickname.map(ComparisonKeys.name)
        var names = Set(TitleGenerator.nameVariants(for: contact).map(ComparisonKeys.name).filter { $0 != nickname })
        names.insert(ComparisonKeys.name(TitleGenerator.title(for: contact)))
        self.names = names.filter { !$0.isEmpty }
        organization = Self.organization(contact)
    }

    init(note entry: VaultEntry, contact: CanonicalContact, keyer: any PhoneKeyer) {
        strong = Self.strongKeys(contact, keyer: keyer)
        // Hand-written notes often carry only a title.
        var named = contact
        if named.title.isEmpty { named.title = entry.title }
        person = NameCompatibility.Profile(named, titleFallback: true)
        var names = Set([entry.title] + entry.aliasNames).map(ComparisonKeys.name)
        if let personal = MatchKeys.nameKey(contact) { names.append(personal) }
        if contact.kind == .organization, let company = contact.company?.name {
            names.append(ComparisonKeys.name(company))
        }
        self.names = Set(names.filter { !$0.isEmpty })
        organization = Self.organization(contact)
    }

    private static func strongKeys(_ contact: CanonicalContact, keyer: any PhoneKeyer) -> Set<String> {
        Set(MatchKeys.keys(for: contact, keyer: keyer).map(\.key).filter { !$0.hasPrefix("nameorg:") })
    }

    private static func organization(_ contact: CanonicalContact) -> String? {
        guard let name = contact.company?.name else { return nil }
        let key = ComparisonKeys.name(name)
        return key.isEmpty ? nil : key
    }

    /// The cascade score of `self` (Apple) against `other` (a note), or nil.
    ///
    /// Emails and phones count only when the names are compatible
    /// (`NameCompatibility`): a husband's contact and his wife's note share a
    /// home phone, and that alone is no match. A shared email with
    /// incompatible names is an advisory 0.3; a shared phone with
    /// incompatible names is nothing.
    func score(against other: MatchProfile) -> MatchScore? {
        let shared = strong.intersection(other.strong)
        let sameName = !names.isDisjoint(with: other.names)
        let verdict = NameCompatibility.verdict(person, other.person)
        let sharedEmail = shared.contains { $0.hasPrefix("email:") }
        var reasons: [String] = []
        if sharedEmail { reasons.append("same email") }
        if shared.contains(where: { $0.hasPrefix("phone:") }) { reasons.append("same phone") }
        if sameName { reasons.append("same name") }
        if !shared.isEmpty, sameName || verdict.isCompatible {
            if !sameName, case .compatible(let detail) = verdict { reasons.append("names match (\(detail))") }
            return MatchScore(confidence: sameName ? 0.9 : 0.7, reasons: reasons)
        }
        if !sameName {
            guard sharedEmail, case .incompatible(let detail) = verdict else { return nil }
            return MatchScore(
                confidence: 0.3, reasons: ["same email", "names differ (\(detail))"], advisory: true)
        }
        if let organization, organization == other.organization {
            return MatchScore(confidence: 0.5, reasons: reasons + ["same company"])
        }
        return MatchScore(confidence: 0.3, reasons: reasons)
    }
}

/// Indexes candidate notes by strong key and name key so each Apple contact
/// is scored only against notes sharing at least one key.
struct CandidateIndex {
    struct Candidate {
        var entry: VaultEntry
        var profile: MatchProfile
    }

    private(set) var candidates: [Candidate] = []
    private var byKey: [String: [Int]] = [:]

    init(entries: [VaultEntry], keyer: any PhoneKeyer) {
        for entry in entries {
            guard let contact = entry.contact else { continue }
            let profile = MatchProfile(note: entry, contact: contact, keyer: keyer)
            let index = candidates.count
            candidates.append(Candidate(entry: entry, profile: profile))
            for key in profile.strong { byKey[key, default: []].append(index) }
            for name in profile.names { byKey["name:" + name, default: []].append(index) }
        }
    }

    /// Candidates scoring at least name-only against `profile`, best first
    /// (ties by path).
    func matches(for profile: MatchProfile) -> [(index: Int, score: MatchScore)] {
        var indices = Set<Int>()
        for key in profile.strong { indices.formUnion(byKey[key] ?? []) }
        for name in profile.names { indices.formUnion(byKey["name:" + name] ?? []) }
        return indices.compactMap { index in profile.score(against: candidates[index].profile).map { (index, $0) } }
            .sorted { lhs, rhs in
                (-lhs.score.confidence, candidates[lhs.index].entry.path)
                    < (-rhs.score.confidence, candidates[rhs.index].entry.path)
            }
    }
}
