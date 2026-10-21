internal import Foundation

/// Generates a contact's `title:` (and so its default filename) from Apple data.
///
/// Deterministic and locale-independent on purpose (no
/// `PersonNameComponentsFormatter`), so every device generates the same title.
public enum TitleGenerator {
    /// Fallback when a contact has nothing name-like at all.
    public static let unnamed = "Unnamed Contact"

    /// Person: `given family suffix` (CJK names: `familygiven`; no middle
    /// name, as in Contacts' list and most filename conventions);
    /// then nickname, organization, first email, first phone. Organization:
    /// the company name first.
    public static func title(for contact: CanonicalContact) -> String {
        let organization = contact.company?.name.trimmed
        if contact.kind == .organization, let organization, !organization.isEmpty { return organization }
        if let personal = personalName(contact.name), !personal.isEmpty { return personal }
        let fallbacks = [
            contact.nickname?.trimmed, organization, contact.emails.first?.value.trimmed,
            contact.phones.first?.value.trimmed,
        ]
        return fallbacks.compactMap { $0 }.first { !$0.isEmpty } ?? unnamed
    }

    /// The person's name (`given family suffix`), or `nil` when there are none.
    /// A middle name alone (no given/family) is used as a last resort.
    public static func personalName(_ name: PersonName) -> String? {
        let given = name.given?.trimmed
        let family = name.family?.trimmed
        if let given, let family, isEastAsian(given + family) {
            let core = family + given
            return [core, name.suffix?.trimmed].compactMap { $0 }.joined(separator: " ")
        }
        let parts = [given, family, name.suffix?.trimmed].compactMap { $0 }
            .filter { !$0.isEmpty }
        if parts.isEmpty, let middle = name.middle?.trimmed, !middle.isEmpty { return middle }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Every way another card may spell this person (Apple relation names are
    /// free text): the title, `given family`, `given middle family`, with
    /// prefix/suffix, and the nickname.
    public static func nameVariants(for contact: CanonicalContact) -> [String] {
        let name = contact.name
        let parts = { (values: [String?]) in
            values.compactMap { $0?.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let variants = [
            personalName(name),
            parts([name.given, name.middle, name.family]),
            parts([name.prefix, name.given, name.middle, name.family, name.suffix]),
            parts([name.prefix, name.given, name.family]),
            contact.nickname,
            contact.nickname.map { parts([$0, name.family]) },
        ]
        var seen = Set<String>()
        return variants.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isEastAsian(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true
            default: false
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
