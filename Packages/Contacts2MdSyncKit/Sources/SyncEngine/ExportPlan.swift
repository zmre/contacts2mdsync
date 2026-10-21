public import ContactModel
public import Foundation
public import VaultIndex

/// When existing notes are adopted without asking.
public enum AutoAdopt: String, Hashable, Sendable, CaseIterable {
    /// Only on this device's first import for the vault (no records yet),
    /// as architecture §6 prescribes.
    case firstImport = "first-import"
    /// On every run.
    case always
    /// Never: every match is proposed for review.
    case never
}

/// Options for a one-way Apple → markdown export.
public struct ExportOptions: Hashable, Sendable {
    /// Re-create notes whose file was deleted (otherwise they are reported and skipped).
    public var restoreMissing: Bool
    /// When to adopt existing notes that match a contact with confidence
    /// ≥ 0.9 and no ambiguity, without asking.
    public var autoAdopt: AutoAdopt
    /// Create new notes even though some notes are iCloud placeholders whose
    /// content is unknown (they might be hand-written notes for the same people).
    public var allowUndownloaded: Bool

    /// Creates options.
    public init(restoreMissing: Bool = false, autoAdopt: AutoAdopt = .firstImport, allowUndownloaded: Bool = false) {
        self.restoreMissing = restoreMissing
        self.autoAdopt = autoAdopt
        self.allowUndownloaded = allowUndownloaded
    }
}

/// Why a note is written.
public enum FileChangeKind: String, Hashable, Sendable {
    /// A new note.
    case create
    /// Apple data changed.
    case update
    /// An existing hand-written note gains a `c2mdsync.id` (and Apple data).
    case adopt
    /// Only the relative `image:` path changed because the note moved.
    case pathFixup
    /// `c2mdsync.status: detached` is set: the note is no longer synced.
    case detach
    /// The note gains its `c2mdsync.id` after its Apple contact is created.
    case link
}

/// One markdown file to create or update. The bytes are final: already
/// emitted and validated by re-parsing.
public struct FileChange: Hashable, Sendable {
    public var path: String
    public var recordID: UUID
    /// Contact title, for output.
    public var title: String
    public var data: Data
    /// Compare-and-swap precondition for the write.
    public var expecting: WriteExpectation
    /// Frontmatter keys that changed (updates only).
    public var changedFields: [String]
    public var kind: FileChangeKind
    /// Why (adoptions: the match reasons).
    public var detail: String?
    /// Written only if the Apple contact for `recordID` was created (opt-ins).
    public var requiresCreatedContact = false
}

/// A contact photo sidecar to write.
public struct ImageWrite: Hashable, Sendable {
    public var path: String
    public var recordID: UUID
    public var data: Data
}

/// A note that moved since the last export (updated in place, never moved back).
public struct NoteMove: Hashable, Sendable {
    public var recordID: UUID
    public var oldPath: String
    public var newPath: String
}

/// One member of a duplicate cluster, for display.
public struct ClusterMember: Codable, Hashable, Sendable {
    public var unifiedID: String
    public var title: String
    public var accounts: [AccountKind]
    /// Path of the note this member is (or will be) exported to, if any.
    public var path: String?
    /// Underlying card ids (stable identity for decisions).
    public var cardIDs: [String]

    /// Creates a member.
    public init(unifiedID: String, title: String, accounts: [AccountKind], path: String?, cardIDs: [String]) {
        self.unifiedID = unifiedID
        self.title = title
        self.accounts = accounts
        self.path = path
        self.cardIDs = cardIDs
    }

    /// The member as a decision reference.
    public var ref: ContactRef { ContactRef(cardIDs: cardIDs, title: title) }
}

/// Something that needs a human (Review in the app; WARNING in the CLI).
///
/// Every item has a stable `id` (derived from card ids, paths and record ids,
/// never from volatile unified ids), so `contacts2md review decide <id> …`
/// works across runs.
public enum ReviewItem: Codable, Hashable, Sendable {
    /// Unified contacts that look like the same person.
    case duplicateCluster(members: [ClusterMember], reasons: [String])
    /// An Apple contact without a note matches an existing note it is not
    /// bound to (adoption proposal / create gate): not created.
    case possibleMatch(contact: ContactRef, path: String, confidence: Double, reasons: [String])
    /// Several notes carry the same `c2mdsync.id` (a copied file): record paused.
    case duplicateSyncID(id: UUID, paths: [String])
    /// One unified contact carries several different stamps (cards stamped
    /// separately, then linked): both notes left alone.
    case mergeRecords(contact: ContactRef, ids: [UUID], paths: [String])
    /// A previously exported note is gone (deleted?): not re-created.
    case missingFile(title: String, id: UUID, lastPath: String?)
    /// A contact note could not be parsed; never written to.
    case unreadableFile(path: String, problem: String)
    /// iCloud placeholders with unknown content: new notes held back.
    case undownloaded(paths: [String])
    /// A field changed differently on both sides (sync): both keep their value.
    case conflict(SyncConflict)
    /// The contact of a synced note is gone from Contacts (two snapshots at
    /// least 10 minutes apart, no re-match). The note is kept until decided.
    case appleDeleted(id: UUID, title: String, path: String)
    /// A synced note was deleted (sync): the contact is kept until decided.
    /// Same id as `missingFile` for the same record.
    case markdownDeleted(contact: ContactRef, id: UUID, title: String, lastPath: String?)
    /// A contact note without `c2mdsync.id` that matches no contact. Never
    /// acted on unless the user opts it in (`add`); informational only.
    case markdownOnly(path: String, title: String)

    /// Stable id: `<kind>-<10 hex>`.
    public var id: String {
        if case .conflict(let conflict) = self { return conflict.id }
        let (prefix, basis): (String, String) =
            switch self {
            case .duplicateCluster(let members, _):
                ("dup", members.flatMap(\.cardIDs).sorted().joined(separator: ","))
            case .possibleMatch(let contact, let path, _, _):
                ("match", contact.cardIDs.joined(separator: ",") + "|" + path)
            case .duplicateSyncID(let id, _): ("copy", id.uuidString.lowercased())
            case .mergeRecords(_, let ids, _): ("merge", ids.map { $0.uuidString.lowercased() }.sorted().joined())
            case .missingFile(_, let id, _): ("missing", id.uuidString.lowercased())
            case .unreadableFile(let path, _): ("invalid", path)
            case .undownloaded: ("icloud", "undownloaded")
            case .conflict(let conflict): ("conflict", conflict.id)
            case .appleDeleted(let id, _, _): ("deleted", id.uuidString.lowercased())
            case .markdownDeleted(_, let id, _, _): ("missing", id.uuidString.lowercased())
            case .markdownOnly(let path, _): ("mdonly", path)
            }
        return prefix + "-" + String(hexSHA256(Data(basis.utf8)).prefix(10))
    }

    /// Choices `review decide` accepts (empty: resolve outside the CLI).
    public var choices: [String] {
        switch self {
        case .duplicateCluster(let members, _): ["distinct"] + members.indices.map { "only:\($0 + 1)" }
        case .possibleMatch: ["adopt", "distinct", "ignore"]
        case .duplicateSyncID(_, let paths): paths.indices.map { "keep:\($0 + 1)" }
        case .mergeRecords(_, _, let paths): paths.indices.map { "keep:\($0 + 1)" }
        case .missingFile, .unreadableFile, .undownloaded: []
        case .conflict(let conflict): conflict.options.map(\.rawValue)
        case .appleDeleted: ["trash", "keep", "restore"]
        case .markdownDeleted: ["restore", "unlink", "delete-contact"]
        case .markdownOnly: ["add", "ignore"]
        }
    }

    /// `false` for informational items (markdown-only notes) that never make
    /// a run "need review" (exit code 1).
    public var needsDecision: Bool {
        if case .markdownOnly = self { return false }
        return true
    }

    /// Errors turning a choice into decisions.
    public enum ChoiceError: Error, Hashable, Sendable, CustomStringConvertible {
        case notDecidable(String)
        case invalidChoice(String, valid: [String])

        public var description: String {
            switch self {
            case .notDecidable(let id): "\(id) cannot be decided from the command line"
            case .invalidChoice(let choice, let valid):
                "invalid choice \"\(choice)\"; expected one of: \(valid.joined(separator: ", "))"
            }
        }
    }

    /// The decisions recording `choice` (validated against `choices`).
    public func decisions(for choice: String, device: DeviceIdentity, at date: Date) throws -> [Decision] {
        guard !choices.isEmpty else { throw ChoiceError.notDecidable(id) }
        guard choices.contains(choice) else { throw ChoiceError.invalidChoice(choice, valid: choices) }
        let number = choice.split(separator: ":").last.flatMap { Int($0) }.map { $0 - 1 }
        func make(
            _ kind: Decision.Kind, contacts: [ContactRef] = [], path: String? = nil, syncID: UUID? = nil
        )
            -> [Decision]
        {
            [
                Decision(
                    kind: kind, createdAt: date, device: device, contacts: contacts, path: path, syncID: syncID,
                    itemID: id)
            ]
        }
        switch self {
        case .duplicateCluster(let members, _):
            guard let number else { return make(.distinctPeople, contacts: members.map(\.ref)) }
            let keep = members[number].ref
            return make(
                .syncOnly, contacts: [keep] + members.enumerated().filter { $0.offset != number }.map(\.element.ref))
        case .possibleMatch(let contact, let path, _, _):
            let kind: Decision.Kind =
                choice == "adopt" ? .adopt : choice == "distinct" ? .distinctPeople : .ignoreCandidate
            return make(kind, contacts: kind == .ignoreCandidate ? [] : [contact], path: path)
        case .duplicateSyncID(let id, let paths):
            return make(.duplicateIDKeep, path: paths[number ?? 0], syncID: id)
        case .mergeRecords(let contact, _, let paths):
            return make(.mergeKeep, contacts: [contact], path: paths[number ?? 0])
        default:
            // Undecidable items have no choices and were rejected above.
            return syncDecisions(for: choice, device: device, at: date)
        }
    }

    /// Decisions for the two-way sync items (conflicts, delete queues, opt-ins).
    private func syncDecisions(for choice: String, device: DeviceIdentity, at date: Date) -> [Decision] {
        let decision: Decision
        switch self {
        case .conflict(let conflict):
            decision = Decision(
                kind: .resolveConflict, createdAt: date, device: device, syncID: conflict.recordID, itemID: id,
                choice: choice, appleHash: conflict.appleHash, markdownHash: conflict.markdownHash)
        case .appleDeleted(let recordID, _, let path):
            decision = Decision(
                kind: .appleDelete, createdAt: date, device: device, path: path, syncID: recordID, itemID: id,
                choice: choice)
        case .markdownDeleted(let contact, let recordID, _, let path):
            decision = Decision(
                kind: .markdownDelete, createdAt: date, device: device, contacts: [contact], path: path,
                syncID: recordID, itemID: id, choice: choice)
        case .markdownOnly(let path, _):
            decision = Decision(
                kind: choice == "add" ? .createContact : .ignoreCandidate, createdAt: date, device: device,
                path: path, itemID: id)
        default:
            return []
        }
        return [decision]
    }

    /// One-line description for lists.
    public var summary: String {
        switch self {
        case .duplicateCluster(let members, let reasons):
            let names = members.map { "\"\($0.title)\" (\($0.accounts.map(\.displayName).joined(separator: "+")))" }
            return "\(names.joined(separator: ", ")) look like one person (\(reasons.joined(separator: ", ")))"
        case .possibleMatch(let contact, let path, let confidence, let reasons):
            return "\"\(contact.title)\" may be \(path) (\(reasons.joined(separator: ", ")); "
                + "confidence \(String(format: "%.2f", confidence)))"
        case .duplicateSyncID(let id, let paths):
            return
                "\(paths.count) notes share c2mdsync id \(id.uuidString.lowercased()): \(paths.joined(separator: ", "))"
        case .mergeRecords(let contact, let ids, let paths):
            let notes = paths.isEmpty ? "" : ": \(paths.joined(separator: ", "))"
            return "\"\(contact.title)\" carries \(ids.count) sync stamps (cards linked after export)\(notes)"
        case .missingFile(let title, _, let lastPath):
            return "\"\(title)\": note \(lastPath ?? "") was deleted"
        case .unreadableFile(let path, let problem):
            return "\(path): \(problem)"
        case .undownloaded(let paths):
            return "\(paths.count) notes are iCloud placeholders not downloaded yet"
        case .conflict(let conflict):
            return conflict.summary
        case .appleDeleted(_, let title, let path):
            return "\"\(title)\" was deleted in Contacts; \(path) kept"
        case .markdownDeleted(_, _, let title, let lastPath):
            return "\"\(title)\": note \(lastPath ?? "") was deleted; the contact is kept"
        case .markdownOnly(let path, let title):
            return "\(path) (\"\(title)\") is not in Contacts"
        }
    }
}

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

/// The dry-run result of planning an export: exactly what `ExportExecutor`
/// would write, plus everything that needs review.
public struct ExportPlan: Sendable {
    /// New notes.
    public var creates: [FileChange] = []
    /// Existing notes to rewrite (updates, adoptions, image path fix-ups).
    public var updates: [FileChange] = []
    /// Exported contacts whose note is already byte-identical.
    public var unchanged: Int = 0
    public var images: [ImageWrite] = []
    public var reviews: [ReviewItem] = []
    public var skipped: [SkippedContact] = []
    /// Non-blocking observations (duplicate titles, …).
    public var warnings: [String] = []
    /// Informational lines (moves, decisions applied, …).
    public var notes: [String] = []
    /// Non-contact notes with invalid frontmatter not reported before.
    public var newProblems: [ProblemNotice] = []
    /// Non-contact notes with invalid frontmatter already reported.
    public var knownProblemCount: Int = 0
    /// Notes that moved since the last export.
    public var moves: [NoteMove] = []
    /// Cards to stamp (only applied with an explicit opt-in and a backup).
    public var stamps: [StampRequest] = []
    /// Bindings to persist after a successful run.
    public var bindings: [UUID: RecordBinding] = [:]
    /// The vault configuration after this export.
    public var config: VaultConfig
    /// The config file text to write, when it changed.
    public var configText: String?
    /// Number of Apple contacts considered.
    public var appleContactCount: Int = 0
    /// Contact notes without an `c2mdsync.id` that remain unlinked.
    public var markdownOnly: Int = 0
    /// Markdown-only notes the user chose to ignore.
    public var ignoredCandidates: Int = 0
    /// Contacts excluded by a sync-only decision.
    public var excludedByDecision: Int = 0
    /// Whether auto-adoption was on for this plan.
    public var autoAdopt = false

    /// Creates an empty plan.
    public init(config: VaultConfig) { self.config = config }

    /// `true` when nothing would be written.
    public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && images.isEmpty && configText == nil }

    /// Adoptions among `updates`.
    public var adoptions: [FileChange] { updates.filter { $0.kind == .adopt } }

    /// Whether anything contact-related was skipped or needs a decision
    /// (exit code 1). Invalid non-contact notes never count.
    public var needsReview: Bool {
        reviews.contains(where: \.needsDecision) || skipped.contains(where: \.needsReview)
    }
}
