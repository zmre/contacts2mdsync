public import Foundation

/// The URL stamp that ties an Apple card to a markdown record.
public enum SyncStamp {
    /// Label of the stamp URL.
    public static let label = "c2mdsync"
    /// Scheme prefix of the stamp URL value.
    public static let prefix = "x-c2mdsync:"

    /// `x-c2mdsync:<uuid>` for `id`.
    public static func url(for id: UUID) -> String { prefix + id.uuidString.lowercased() }

    /// The id in a stamp URL value, or `nil` when `value` is not a stamp.
    public static func id(fromURL value: String) -> UUID? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(trimmed.dropFirst(prefix.count)))
    }

    /// `true` for any value using our scheme (even with a malformed uuid);
    /// such values are never exported to markdown.
    public static func isStamp(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix)
    }
}
