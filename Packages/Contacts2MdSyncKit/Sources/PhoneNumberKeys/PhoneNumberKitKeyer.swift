public import ContactModel
internal import Foundation
internal import PhoneNumberKit
internal import Synchronization

/// E.164 phone comparison keys via PhoneNumberKit.
///
/// Numbers without a country code are interpreted in `defaultRegion`
/// (ISO 3166 alpha-2, e.g. `US`). Unparsable numbers fall back to
/// `DigitsPhoneKeyer`. Extensions are appended as `;ext=<digits>`.
///
/// The region is always passed explicitly: PhoneNumberKit's own default
/// would consult `CNContactsUserDefaults`, and nothing here may touch Contacts.
public final class PhoneNumberKitKeyer: PhoneKeyer {
    /// The region used for numbers written without `+<country code>`.
    public let defaultRegion: String

    // `PhoneNumberUtility` is a non-Sendable class with internal caches;
    // serialize access to it.
    private let utility: Mutex<PhoneNumberUtility>
    private let fallback = DigitsPhoneKeyer()

    /// Creates a keyer for `defaultRegion` (uppercased; unknown regions still
    /// parse numbers written in international form).
    public init(defaultRegion: String) {
        self.defaultRegion = defaultRegion.uppercased()
        self.utility = Mutex(PhoneNumberUtility())
    }

    public func key(for raw: String) -> String {
        let (main, ext) = DigitsPhoneKeyer.splitExtension(raw)
        let parsed: String? = utility.withLock { utility in
            guard let number = try? utility.parse(main, withRegion: defaultRegion, ignoreType: true) else {
                return nil
            }
            return utility.format(number, toType: .e164)
        }
        guard let parsed else { return fallback.key(for: raw) }
        guard let ext, !ext.isEmpty else { return parsed }
        return "\(parsed);ext=\(ext)"
    }
}
