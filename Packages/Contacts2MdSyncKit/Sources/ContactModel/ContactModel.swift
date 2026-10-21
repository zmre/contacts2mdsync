/// Pure value types describing a contact independent of any storage backend.
///
/// `ContactModel` is the shared vocabulary between the Apple Contacts side
/// (`ContactsAdapter`) and the markdown side (`MarkdownCodec`, `VaultIndex`).
/// It stays free of framework dependencies (Foundation only) so it is
/// trivially testable. The `ContactStore` seam the sync engine talks to also
/// lives here, so the engine never imports Contacts.framework.
public enum ContactModel {
    /// Version of the canonical contact schema. Bump when the on-disk
    /// representation of a contact changes incompatibly.
    public static let schemaVersion = 1
}
