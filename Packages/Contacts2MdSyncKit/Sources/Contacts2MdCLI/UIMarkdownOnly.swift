public import ContactModel
public import Foundation
public import SyncEngine
internal import VaultIndex

// MARK: - Markdown Only (docs/ui.md §5)

/// An Apple contact that may be the person in a markdown-only note.
public struct UIMatchCandidate: Identifiable, Hashable, Sendable {
    /// The possible-match review item id.
    public var id: String
    public var contact: ContactRef
    public var title: String
    public var confidence: Double
    public var reasons: [String]
    public var accounts: [AccountKind]

    /// Creates a candidate.
    public init(
        id: String, contact: ContactRef, title: String, confidence: Double, reasons: [String],
        accounts: [AccountKind]
    ) {
        self.id = id
        self.contact = contact
        self.title = title
        self.confidence = confidence
        self.reasons = reasons
        self.accounts = accounts
    }
}

/// What to do with a markdown-only note.
public enum UIMarkdownOnlyAction: Hashable, Sendable {
    /// Nothing for now.
    case leave
    /// Link the note to the matched contact (adopt).
    case link(itemID: String)
    /// The matched contact is someone else.
    case notThisPerson(itemID: String)
    /// Never match this note again (remembered).
    case ignore
    /// Create an Apple contact from the note (needs two-way sync).
    case addToContacts

    /// Decision-log answers for this action on `row` (empty for `leave` and
    /// for actions the log cannot record yet).
    public func decisions(for row: UIMarkdownOnlyRow) -> [UIReviewDecision] {
        switch self {
        case .leave, .addToContacts: []
        case .link(let itemID): [.choice(itemID: itemID, choice: "adopt")]
        case .notThisPerson(let itemID): [.choice(itemID: itemID, choice: "distinct")]
        case .ignore:
            row.matches.isEmpty
                ? [.ignoreNote(path: row.path)] : row.matches.map { .choice(itemID: $0.id, choice: "ignore") }
        }
    }
}

/// One row of the Markdown Only table.
public struct UIMarkdownOnlyRow: Identifiable, Hashable, Sendable {
    public var path: String
    public var title: String
    public var kind: ContactKind?
    public var note: UINoteSummary?
    /// The note has a sync id no Apple contact is bound to (e.g. state lost).
    public var isOrphaned: Bool
    /// Ignored by a decision (hidden unless Show Ignored).
    public var isIgnored: Bool
    /// A decision already answers this row; it applies on the next export.
    public var decidedNote: String?
    /// Possible matches, best first.
    public var matches: [UIMatchCandidate]
    public var firstSeen: Date?

    /// Creates a row.
    public init(
        path: String, title: String, kind: ContactKind?, note: UINoteSummary?, isOrphaned: Bool, isIgnored: Bool,
        decidedNote: String?, matches: [UIMatchCandidate], firstSeen: Date?
    ) {
        self.path = path
        self.title = title
        self.kind = kind
        self.note = note
        self.isOrphaned = isOrphaned
        self.isIgnored = isIgnored
        self.decidedNote = decidedNote
        self.matches = matches
        self.firstSeen = firstSeen
    }

    public var id: String { path }

    /// Folder part of the path (`""` at the root).
    public var folder: String { VaultPath.directory(of: path) }

    public var bestMatch: UIMatchCandidate? { matches.first }

    /// Link when a match ≥ 0.5 exists ("Add" is never the default then), else leave.
    public var defaultAction: UIMarkdownOnlyAction {
        if let best = bestMatch, best.confidence >= 0.5 { return .link(itemID: best.id) }
        return .leave
    }

    /// Counts toward the badge: not ignored and not already decided.
    public var needsReview: Bool { !isIgnored && decidedNote == nil }
}
