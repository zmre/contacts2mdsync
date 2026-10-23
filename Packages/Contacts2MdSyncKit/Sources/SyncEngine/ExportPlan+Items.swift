public import Foundation

/// A contact left out of this export, and why.
public struct SkippedContact: Hashable, Sendable {
    public var title: String
    public var reason: String
    /// `false` when a recorded decision excluded it (no review needed).
    public var needsReview: Bool

    /// Creates a skipped entry.
    public init(title: String, reason: String, needsReview: Bool = true) {
        self.title = title
        self.reason = reason
        self.needsReview = needsReview
    }
}

/// A non-contact note with invalid frontmatter, reported once per content hash.
public struct ProblemNotice: Hashable, Sendable {
    public var path: String
    public var problem: String
    public var sha256: String
}

/// A request to stamp an Apple card with its record id.
public struct StampRequest: Hashable, Sendable {
    public var cardID: String
    public var recordID: UUID
    public var title: String
}
