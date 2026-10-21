internal import ContactModel

/// Reconciliation between Apple Contacts and the markdown vault.
///
/// M1 implements one-way export (`ExportPlanner` → `ExportExecutor`); the
/// engine sees Apple Contacts only through `ContactStore` and the notes
/// folder only through `VaultFS`.
public enum SyncEngine {
    /// Human-readable engine status, shown in the app until live sync lands.
    public static let status = "idle"

    /// Schema version the engine operates on.
    public static var schemaVersion: Int { ContactModel.schemaVersion }

    /// `transactionAuthor` prefix for our Apple writes (excluded from history).
    public static let transactionAuthorPrefix = "com.zmre.contacts2mdsync."
}
