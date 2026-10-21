internal import ContactModel
internal import ContactsShim

/// Bridges Apple's Contacts framework (`CNContactStore`) to `ContactModel`
/// values: fetching, change-history enumeration, and saving edits back.
///
/// Calls that can raise Objective-C exceptions (change history) go through
/// `ContactsShim`, which converts them into Swift-catchable `NSError`s.
public enum ContactsAdapter {
    /// The `ContactModel` schema version this adapter maps to.
    public static let schemaVersion = ContactModel.schemaVersion
}
