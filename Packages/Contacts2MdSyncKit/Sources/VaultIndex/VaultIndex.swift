internal import ContactModel
internal import MarkdownCodec

/// Scans the user's notes folder for contact markdown files and maintains an
/// index from contact identity to file URL, so the sync engine can find the
/// markdown counterpart of an Apple contact without re-reading the vault.
public enum VaultIndex {
    /// Version of the on-disk index format.
    public static let indexVersion = 1
}
