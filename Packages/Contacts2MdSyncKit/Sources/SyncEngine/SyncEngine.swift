internal import ContactModel
internal import ContactsAdapter
internal import MarkdownCodec
internal import VaultIndex

/// Two-way reconciliation between Apple Contacts and the markdown vault:
/// diffing, conflict detection, and applying changes to either side.
///
/// No sync logic exists yet (M0 scaffolding).
public enum SyncEngine {
    /// Human-readable engine status, shown in the app until real sync lands.
    public static let status = "idle"

    /// Schema version the engine operates on.
    public static var schemaVersion: Int { ContactModel.schemaVersion }
}
