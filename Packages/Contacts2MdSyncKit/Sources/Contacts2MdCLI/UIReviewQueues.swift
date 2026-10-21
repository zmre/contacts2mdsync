internal import Foundation
internal import SyncEngine
internal import VaultIndex

/// The review screens of docs/ui.md.
public enum UIReviewQueue: String, CaseIterable, Hashable, Sendable {
    case conflicts
    case markdownOnly
    case deletions
    case duplicates
}

/// Badge counts per review screen.
public struct UIReviewCounts: Hashable, Sendable {
    public var conflicts: Int
    public var markdownOnly: Int
    public var deletions: Int
    public var duplicates: Int

    /// Creates counts.
    public init(conflicts: Int = 0, markdownOnly: Int = 0, deletions: Int = 0, duplicates: Int = 0) {
        self.conflicts = conflicts
        self.markdownOnly = markdownOnly
        self.deletions = deletions
        self.duplicates = duplicates
    }

    /// The count for `queue`.
    public subscript(queue: UIReviewQueue) -> Int {
        switch queue {
        case .conflicts: conflicts
        case .markdownOnly: markdownOnly
        case .deletions: deletions
        case .duplicates: duplicates
        }
    }

    public var total: Int { conflicts + markdownOnly + deletions + duplicates }
}

// MARK: - All queues

/// Every review queue the stored state (plus an optional plan) can fill.
public struct UIReviewQueues: Sendable {
    /// Records with field conflicts (one field per open conflict).
    public var conflicts: [UIConflictRecord]
    public var duplicates: [UIDuplicateGroup]
    /// All markdown-only rows, ignored ones included.
    public var markdownOnly: [UIMarkdownOnlyRow]
    /// Both deletion queues (and notes a one-way export found missing).
    public var deletions: [UIDeletionRow]
    public var invalidNotes: [UIProblemNote]
    /// Pending items about undownloaded iCloud files.
    public var undownloadedNotes: Int
    /// Groups hidden by Ignore for Now.
    public var snoozedCount: Int

    /// Builds the queues. `snoozed` holds item ids hidden by Ignore for Now.
    public init(data: UIVaultData, plan: UIPlanSummary? = nil, snoozed: Set<String> = []) {
        let open = data.openItems
        let notes = Dictionary(data.notes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let allGroups = open.compactMap { UIDuplicateGroup($0, plan: plan, notes: notes) }
        duplicates = allGroups.filter { !snoozed.contains($0.id) }
        snoozedCount = allGroups.count - duplicates.count
        markdownOnly = Self.markdownOnlyRows(data: data, open: open, notes: notes, plan: plan)
        conflicts = UIConflictRecord.records(open, records: data.records)
        deletions = UIDeletionRow.rows(open, records: data.records)
        invalidNotes = data.invalidContactNotes
        undownloadedNotes = open.reduce(0) { total, entry in
            if case .undownloaded(let paths) = entry.item { return total + paths.count }
            return total
        }
    }

    /// Badge counts: conflicting records, open markdown-only notes,
    /// deletions, duplicate groups.
    public var counts: UIReviewCounts {
        UIReviewCounts(
            conflicts: conflicts.count, markdownOnly: markdownOnly.filter(\.needsReview).count,
            deletions: deletions.count, duplicates: duplicates.count)
    }

    private static func markdownOnlyRows(
        data: UIVaultData, open: [PendingReview], notes: [String: UINoteSummary], plan: UIPlanSummary?
    ) -> [UIMarkdownOnlyRow] {
        var matchesByPath: [String: [UIMatchCandidate]] = [:]
        var firstSeen: [String: Date] = [:]
        for entry in open {
            guard case .possibleMatch(let contact, let path, let confidence, let reasons) = entry.item else {
                continue
            }
            let details = plan?.contact(for: contact.cardIDs)
            matchesByPath[path, default: []].append(
                UIMatchCandidate(
                    id: entry.id, contact: contact, title: details?.title ?? contact.title, confidence: confidence,
                    reasons: reasons, accounts: details?.accounts ?? []))
            firstSeen[path] = min(firstSeen[path] ?? entry.firstSeen, entry.firstSeen)
        }
        let decisions = DecisionSet(data.decisions)
        let decided = data.decidedItemIDs
        let decidedPaths = Set(
            data.pending.items.filter { decided.contains($0.id) }.compactMap { entry -> String? in
                guard case .possibleMatch(_, let path, _, _) = entry.item else { return nil }
                return path
            })
        let boundIDs = Set(data.records.records.keys)
        var paths = Set(data.notes.filter { $0.syncID == nil }.map(\.path))
        paths.formUnion(matchesByPath.keys)
        return paths.map { path in
            let note = notes[path]
            let ignored = note.map(data.isIgnored) ?? decisions.isIgnored(path: path, syncID: nil)
            var decidedNote: String?
            if decisions.adoption(ofNoteAt: path) != nil {
                decidedNote = "Will be linked on the next sync"
            } else if decisions.wantsContact(forNoteAt: path) {
                decidedNote = "Will be added to Contacts on the next sync"
            } else if decidedPaths.contains(path) && matchesByPath[path] == nil {
                decidedNote = "Decided; applies on the next sync"
            }
            return UIMarkdownOnlyRow(
                path: path, title: note?.title ?? VaultPath.stem(of: path), kind: note?.kind, note: note,
                isOrphaned: note?.syncID.map { !boundIDs.contains($0) } ?? false, isIgnored: ignored,
                decidedNote: decidedNote,
                matches: (matchesByPath[path] ?? []).sorted { ($1.confidence, $0.title) < ($0.confidence, $1.title) },
                firstSeen: firstSeen[path])
        }
        .sorted { ($0.title.localizedLowercase, $0.path) < ($1.title.localizedLowercase, $1.path) }
    }
}
