public import Foundation

/// One change an executed run made, for Activity's per-change list and
/// Export Log (compact: no values, only what changed where).
public struct SessionChange: Codable, Hashable, Sendable {
    public enum Side: String, Codable, Hashable, Sendable {
        case apple
        case markdown
    }

    public var side: Side
    /// `created`, `updated`, `adopted`, `linked`, `detached`, `fixed`,
    /// `trashed` (markdown); `created`, `updated`, `deleted`, `stamped`,
    /// `unstamped` (Apple).
    public var verb: String
    /// Contact or note title.
    public var title: String
    /// Root-relative note path (markdown changes).
    public var path: String?
    /// Changed fields (`job_title`, `phones`, `tags`, …).
    public var fields: [String]
    public var recordID: UUID?

    /// At most this many changes are kept per run.
    public static let perSessionLimit = 500
    /// Change logs are kept for this many runs (the most recent ones that changed something).
    public static let sessionLimit = 100

    /// Creates a change.
    public init(
        side: Side, verb: String, title: String, path: String? = nil, fields: [String] = [], recordID: UUID? = nil
    ) {
        self.side = side
        self.verb = verb
        self.title = title
        self.path = path
        self.fields = fields
        self.recordID = recordID
    }
}

/// The change log of an executed run (Activity's per-change list, Export Log).
extension SessionChange {
    /// What an executed sync changed: notes written, notes moved to the
    /// Trash, and Apple changes saved completely.
    public static func log(_ result: SyncResult) -> [SessionChange] {
        log(result.markdown)
            + result.trashed.map {
                SessionChange(side: .markdown, verb: "trashed", title: $0.title, path: $0.path, recordID: $0.recordID)
            }
            + result.apple.map { change in
                SessionChange(
                    side: .apple, verb: verb(change.kind), title: change.title,
                    fields: change.fields.filter { $0 != "stamp" || change.kind == .stamp }, recordID: change.recordID)
            }
    }

    /// What an executed export (or the markdown side of a sync) wrote.
    public static func log(_ result: ExportResult) -> [SessionChange] {
        result.created.map {
            SessionChange(side: .markdown, verb: "created", title: $0.title, path: $0.path, recordID: $0.recordID)
        }
            + result.updated.map {
                SessionChange(
                    side: .markdown, verb: verb($0.kind), title: $0.title, path: $0.path, fields: $0.changedFields,
                    recordID: $0.recordID)
            }
    }

    private static func verb(_ kind: FileChangeKind) -> String {
        switch kind {
        case .create: "created"
        case .update: "updated"
        case .adopt: "adopted"
        case .pathFixup: "fixed"
        case .detach: "detached"
        case .link: "linked"
        }
    }

    private static func verb(_ kind: AppleChangeKind) -> String {
        switch kind {
        case .update: "updated"
        case .create: "created"
        case .delete: "deleted"
        case .stamp: "stamped"
        case .unstamp: "unstamped"
        }
    }

    /// One line: `markdown updated  Ann One  Inbox/Ann One.md  (job_title, phones)`.
    public var line: String {
        var text = "\(side.rawValue) \(verb)  \(title)"
        if let path { text += "  \(path)" }
        if !fields.isEmpty { text += "  (\(fields.joined(separator: ", ")))" }
        return text
    }
}
