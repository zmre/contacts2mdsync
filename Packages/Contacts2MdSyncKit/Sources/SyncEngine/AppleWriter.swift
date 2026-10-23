public import ContactModel

/// Applies Apple writes. Requires a `BackupReceipt`, which only
/// `VCardBackup.backup` can create, so no Apple write happens without a
/// fresh vCard backup of the whole address book (architecture §9).
public enum AppleWriter {
    /// Saves `batch` tagged with `author`.
    public static func apply(
        _ batch: AppleWriteBatch, in store: any ContactStore, backup: BackupReceipt, author: String
    ) throws -> AppleWriteResult {
        _ = backup  // The receipt's existence is the precondition.
        guard !batch.operations.isEmpty else { return AppleWriteResult(applied: []) }
        return try store.apply(batch, author: author)
    }
}
