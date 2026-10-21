/// Pure value types describing a contact independent of any storage backend.
///
/// `ContactModel` is the shared vocabulary between the Apple Contacts side
/// (`ContactsAdapter`) and the markdown side (`MarkdownCodec`, `VaultIndex`).
/// It must stay free of framework dependencies so it is trivially testable.
public enum ContactModel {
    /// Version of the canonical contact schema. Bump when the on-disk
    /// representation of a contact changes incompatibly.
    public static let schemaVersion = 1
}
