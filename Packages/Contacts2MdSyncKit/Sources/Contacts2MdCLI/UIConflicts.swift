public import Foundation
public import SyncEngine

// MARK: - Conflicts (docs/ui.md §4)

/// How the user resolves one conflicting field.
public enum UIConflictResolution: String, CaseIterable, Hashable, Sendable, Identifiable {
    case keepContacts
    case keepMarkdown
    case keepBoth

    public var id: Self { self }

    /// `Keep Contacts`.
    public var title: String {
        switch self {
        case .keepContacts: "Keep Contacts"
        case .keepMarkdown: "Keep Markdown"
        case .keepBoth: "Keep Both"
        }
    }

    /// Batch wording (`Resolve Selected` menu).
    public var preferenceTitle: String {
        switch self {
        case .keepContacts: "Prefer Contacts"
        case .keepMarkdown: "Prefer Markdown"
        case .keepBoth: "Keep Both Where Possible"
        }
    }

    /// The engine's resolution (`review decide` choice).
    public var engine: ConflictResolution {
        switch self {
        case .keepContacts: .keepApple
        case .keepMarkdown: .keepMarkdown
        case .keepBoth: .keepBoth
        }
    }

    /// The UI resolution for an engine option.
    public init(_ engine: ConflictResolution) {
        switch engine {
        case .keepApple: self = .keepContacts
        case .keepMarkdown: self = .keepMarkdown
        case .keepBoth: self = .keepBoth
        }
    }
}

/// One field (or list element) that changed differently on both sides.
/// Its `id` is the conflict's review item id.
public struct UIConflictField: Identifiable, Hashable, Sendable {
    public var id: String
    /// `Job`, `Phone`.
    public var name: String
    /// `mobile`, when the field is a list element.
    public var label: String?
    /// The last agreed value (`nil`: no base).
    public var previous: String?
    public var contacts: String
    public var markdown: String
    /// Keep Both only where the engine offers it (list elements, the body).
    public var options: [UIConflictResolution]
    /// `phones[mobile]`, for help text.
    public var fieldPath: String
    /// Whole texts of a note body conflict (`contacts`/`markdown` are then
    /// previews), for the line comparison; `nil` for other fields.
    public var contactsText: String?
    public var markdownText: String?

    /// Builds the row for `conflict`.
    public init(_ conflict: SyncConflict) {
        id = conflict.id
        name = Self.displayName(conflict.field)
        fieldPath = conflict.fieldPath
        // Show labels only when they are what differs (label conflicts).
        let labelsDiffer = conflict.apple.label != conflict.markdown.label
        label = labelsDiffer ? nil : (conflict.markdown.label ?? conflict.apple.label ?? conflict.element)
        previous = conflict.base.map { Self.text($0, withLabel: labelsDiffer) }
        contacts = Self.text(conflict.apple, withLabel: labelsDiffer)
        markdown = Self.text(conflict.markdown, withLabel: labelsDiffer)
        options = conflict.options.map(UIConflictResolution.init)
        contactsText = conflict.apple.text
        markdownText = conflict.markdown.text
    }

    /// Creates a field (previews and tests).
    public init(
        id: String, name: String, label: String? = nil, previous: String? = nil, contacts: String, markdown: String,
        options: [UIConflictResolution], fieldPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.previous = previous
        self.contacts = contacts
        self.markdown = markdown
        self.options = options
        self.fieldPath = fieldPath ?? name
    }

    /// `value`, `label: value`, or `(removed)` for an absent side.
    static func text(_ side: ConflictSide, withLabel: Bool) -> String {
        guard let value = side.value else { return "(removed)" }
        guard withLabel, let label = side.label, !label.isEmpty else { return value }
        return "\(label): \(value)"
    }

    /// Plain-English name for a markdown field (`job_title` → `Job`).
    public static func displayName(_ field: String) -> String {
        let key = field.split(separator: ".").last.map(String.init) ?? field
        if let name = names[key] { return name }
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static let names: [String: String] = [
        "prefix": "Prefix", "first_name": "First name", "middle_name": "Middle name", "last_name": "Last name",
        "suffix": "Suffix", "nickname": "Nickname", "maiden_name": "Maiden name", "company": "Company",
        "department": "Department", "job_title": "Job", "title": "Title", "image": "Photo", "emails": "Email",
        "phones": "Phone", "urls": "URL", "social": "Social profile", "im": "Messaging", "addresses": "Address",
        "dates": "Date", "birthday": "Birthday", "relationships": "Related", "tags": "Tags", "body": "Notes",
    ]
}

/// A record changed on both sides: one row in the Conflicts list.
public struct UIConflictRecord: Identifiable, Hashable, Sendable {
    /// The record id (`c2mdsync.id`) as text.
    public var id: String
    public var recordID: UUID
    public var title: String
    public var path: String
    /// When the oldest of its conflicts was first seen.
    public var since: Date?
    /// The Apple cards of the record (for Open in Contacts).
    public var cardIDs: [String]
    public var fields: [UIConflictField]

    /// Creates a record.
    public init(
        recordID: UUID, title: String, path: String, since: Date?, cardIDs: [String], fields: [UIConflictField]
    ) {
        self.id = recordID.uuidString.lowercased()
        self.recordID = recordID
        self.title = title
        self.path = path
        self.since = since
        self.cardIDs = cardIDs
        self.fields = fields
    }

    /// Folder of the note with a trailing slash (`Work/`), or `/` at the root.
    public var folderText: String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : parts.joined(separator: "/") + "/"
    }

    /// Open conflicts grouped per record (one field per conflict), sorted by
    /// title. Decided conflicts are already gone from `open`.
    public static func records(_ open: [PendingReview], records: RecordMap) -> [UIConflictRecord] {
        var order: [UUID] = []
        var byRecord: [UUID: [(SyncConflict, Date)]] = [:]
        for entry in open {
            guard case .conflict(let conflict) = entry.item else { continue }
            if byRecord[conflict.recordID] == nil { order.append(conflict.recordID) }
            byRecord[conflict.recordID, default: []].append((conflict, entry.firstSeen))
        }
        return order.compactMap { recordID -> UIConflictRecord? in
            guard let conflicts = byRecord[recordID], let first = conflicts.first?.0 else { return nil }
            return UIConflictRecord(
                recordID: recordID, title: first.title, path: first.path, since: conflicts.map(\.1).min(),
                cardIDs: records.records[recordID]?.cardIDs ?? [], fields: conflicts.map { UIConflictField($0.0) })
        }
        .sorted { ($0.title.localizedLowercase, $0.path) < ($1.title.localizedLowercase, $1.path) }
    }
}

/// A chosen resolution for one field.
public struct UIConflictChoice: Hashable, Sendable {
    public var recordID: String
    /// The conflict's review item id (`UIConflictField.id`).
    public var fieldID: String
    public var resolution: UIConflictResolution

    /// Creates a choice.
    public init(recordID: String, fieldID: String, resolution: UIConflictResolution) {
        self.recordID = recordID
        self.fieldID = fieldID
        self.resolution = resolution
    }

    /// The decision-log answer (`review decide <conflict-id> apple|markdown|both`).
    public var decision: UIReviewDecision {
        .choice(itemID: fieldID, choice: resolution.engine.rawValue)
    }
}

extension UIConflictRecord {
    /// Choices for a batch preference: `preferred` for every field that
    /// offers it. Fields without it (Keep Both on scalars and label
    /// conflicts) are left undecided rather than guessed.
    public func choices(preferring preferred: UIConflictResolution) -> [UIConflictChoice] {
        fields.filter { $0.options.contains(preferred) }.map {
            UIConflictChoice(recordID: id, fieldID: $0.id, resolution: preferred)
        }
    }
}

// MARK: - Line comparison (note bodies)

/// One line of a two-text comparison.
public struct UIDiffLine: Identifiable, Hashable, Sendable {
    public enum Side: Hashable, Sendable {
        /// In both texts.
        case both
        /// Only in the markdown body.
        case markdown
        /// Only in the Contacts note.
        case contacts
    }

    public var id: Int
    public var side: Side
    public var text: String
}

/// A line diff of a note body conflict (markdown first, then Contacts), for
/// the Conflicts view: common lines once, lines only on one side marked.
/// Longest-common-subsequence on lines; above `maxCells` (very long notes)
/// the texts are shown one after the other without alignment.
public enum UITextDiff {
    static let maxCells = 4_000_000

    public static func lines(markdown: String, contacts: String) -> [UIDiffLine] {
        let left = split(markdown)
        let right = split(contacts)
        var result: [(UIDiffLine.Side, String)] = []
        if left.count * right.count > maxCells {
            result = left.map { (.markdown, $0) } + right.map { (.contacts, $0) }
        } else {
            var table = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
            for row in stride(from: left.count - 1, through: 0, by: -1) {
                for column in stride(from: right.count - 1, through: 0, by: -1) {
                    table[row][column] =
                        left[row] == right[column]
                        ? table[row + 1][column + 1] + 1 : max(table[row + 1][column], table[row][column + 1])
                }
            }
            var (row, column) = (0, 0)
            while row < left.count || column < right.count {
                if row < left.count, column < right.count, left[row] == right[column] {
                    result.append((.both, left[row]))
                    row += 1
                    column += 1
                } else if column == right.count
                    || (row < left.count && table[row + 1][column] >= table[row][column + 1])
                {
                    result.append((.markdown, left[row]))
                    row += 1
                } else {
                    result.append((.contacts, right[column]))
                    column += 1
                }
            }
        }
        return result.enumerated().map { UIDiffLine(id: $0.offset, side: $0.element.0, text: $0.element.1) }
    }

    private static func split(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.isEmpty
            ? [] : normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
