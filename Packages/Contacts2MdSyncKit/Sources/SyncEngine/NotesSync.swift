public import ContactModel
public import Foundation

/// How a run handles Contacts notes (architecture §8 "Notes"), decided
/// before planning.
public struct NotesStatus: Hashable, Sendable {
    /// Where notes come from this run; `nil`: the body is markdown-only.
    public var source: NotesSource?
    /// Notes were wanted (`notes_sync: on`) but skipped this run, with the
    /// warning to print (`Automation permission … not granted`, a failed
    /// read). A skipped run is not "notes off": the notes base is kept.
    public var skipped: String?
    /// No notes base on this Mac for this vault: the first sync with notes,
    /// or the first after notes were turned off. Every record's body is then
    /// merged without a base (the enablement migration).
    public var freshStart: Bool

    /// Notes off (the default before scripting existed).
    public static let off = NotesStatus(source: nil, skipped: nil, freshStart: false)

    /// Creates a status.
    public init(source: NotesSource?, skipped: String? = nil, freshStart: Bool = false) {
        self.source = source
        self.skipped = skipped
        self.freshStart = freshStart
    }

    /// `true` when notes are read and written this run.
    public var isActive: Bool { source != nil }
}

/// One record in the notes baseline summary.
public struct NotesBaselineItem: Hashable, Sendable {
    public var recordID: UUID
    public var title: String
    public var path: String
    /// Characters and lines of the text that moves (or of the markdown side
    /// for conflicts).
    public var characters: Int
    public var lines: Int

    /// Creates an item for `text`.
    public init(recordID: UUID, title: String, path: String, text: String) {
        self.recordID = recordID
        self.title = title
        self.path = path
        characters = text.count
        lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// What happens to bodies of records that have no notes base yet — every
/// record on the first sync with notes (the enablement migration, §8), and
/// later records bound for the first time (adopted notes).
///
/// Rules per record: markdown empty, Contacts note non-empty → the note goes
/// into markdown; Contacts empty, markdown non-empty → the markdown body is
/// written to Contacts (an Apple change: blast radius, held while
/// `apple_writes` is disabled); both equal → adopted; both non-empty and
/// different → a conflict (Keep Contacts / Keep Markdown / Keep Both).
public struct NotesBaseline: Hashable, Sendable {
    /// Markdown bodies that will be written into Contacts notes.
    public var toContacts: [NotesBaselineItem] = []
    /// Contacts notes that will be written into markdown.
    public var toMarkdown: [NotesBaselineItem] = []
    /// Conflicts resolved as Keep Both (written to both sides).
    public var keptBoth: [NotesBaselineItem] = []
    /// Open conflicts (nothing written for these bodies).
    public var conflicts: [NotesBaselineItem] = []
    /// Records whose note and body already agree (adopted as the base).
    public var adopted = 0

    /// Creates an empty summary.
    public init() {}

    /// `true` when no record lacked a notes base.
    public var isEmpty: Bool {
        toContacts.isEmpty && toMarkdown.isEmpty && keptBoth.isEmpty && conflicts.isEmpty && adopted == 0
    }

    /// `true` when a body moves or conflicts.
    public var hasChanges: Bool {
        !toContacts.isEmpty || !toMarkdown.isEmpty || !keptBoth.isEmpty || !conflicts.isEmpty
    }

    /// The largest markdown body going into Contacts.
    public var largestToContacts: NotesBaselineItem? { toContacts.max { $0.characters < $1.characters } }

    /// `12 into markdown, 3 into Contacts (largest 4,812 chars), 140 already equal, 2 conflicts`.
    public var summary: String {
        var parts = ["\(toMarkdown.count) into markdown"]
        var toApple = "\(toContacts.count) into Contacts"
        if let largest = largestToContacts {
            toApple += " (largest \(NotesBaseline.format(largest.characters)) chars: \(largest.title))"
        }
        parts.append(toApple)
        if !keptBoth.isEmpty { parts.append("\(keptBoth.count) kept both") }
        parts.append("\(adopted) already equal")
        parts.append("\(conflicts.count) conflicts")
        return parts.joined(separator: ", ")
    }

    /// `4,812`.
    public static func format(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

/// The per-device memory of whether notes were synced (`meta.notes_source`).
public enum NotesSyncState {
    /// `meta` key: the notes source of the last executed sync that synced
    /// notes; removed by a sync with notes off.
    public static let metaKey = "notes_source"

    /// The source recorded by the last executed sync with notes, if any.
    public static func lastSource(in state: any SyncStateStore) -> NotesSource? {
        guard let data = try? state.metadata(metaKey), let text = String(bytes: data, encoding: .utf8) else {
            return nil
        }
        return NotesSource(rawValue: text)
    }

    /// The status a run plans with: a run whose notes read failed is turned
    /// into a skipped one, and `freshStart` comes from this device's state.
    static func status(_ wanted: NotesStatus, read snapshot: AppleSnapshot, state: any SyncStateStore) -> NotesStatus {
        var notes = wanted
        if notes.isActive, !snapshot.notesAvailable {
            notes = NotesStatus(source: nil, skipped: "Contacts notes could not be read; notes skipped")
        }
        notes.freshStart = isFreshStart(notes.source, state: state)
        return notes
    }

    /// Whether a run with `source` starts without a notes base.
    public static func isFreshStart(_ source: NotesSource?, state: any SyncStateStore) -> Bool {
        source != nil && lastSource(in: state) == nil
    }

    /// Records an executed sync: notes synced → remember the source; notes
    /// deliberately off → forget it (the next run with notes starts fresh);
    /// notes skipped (no permission, a failed read) → unchanged.
    static func record(_ status: NotesStatus, notesSynced: Bool, in state: any SyncStateStore) throws {
        if let source = status.source, notesSynced {
            try state.setMetadata(metaKey, Data(source.rawValue.utf8))
        } else if status.source == nil, status.skipped == nil {
            try state.setMetadata(metaKey, nil)
        }
    }
}

extension RecordBase {
    /// This base with no body base (the body merges by the first-bind rule).
    func withoutBody() -> RecordBase {
        guard isMergeBase else { return self }
        var copy = self
        copy.body = nil
        copy.fields["body"] = nil
        copy.unknown = Array(Set((unknown ?? []) + ["body"])).sorted()
        return copy
    }
}
