internal import ContactModel
public import Foundation
public import SyncEngine
internal import VaultIndex

// MARK: - Duplicates (docs/ui.md §7)

/// What the user can do with a duplicate group.
public enum UIDuplicateAction: Hashable, Sendable {
    /// The contacts are different people (remembered forever).
    case notDuplicates
    /// Keep cluster member `member` (0-based) synced; exclude the others.
    case syncOnly(member: Int)
    /// Of the notes sharing a sync id, the one at index `path` keeps it.
    case keepSyncID(path: Int)
    /// Snooze until the next export (not recorded).
    case ignoreForNow
    /// Merge records: the note at `index` (of the item's paths, 0-based)
    /// stays synced with the linked contact; the others are detached and
    /// their sync ids removed from the contact's cards (`merge-keep`).
    case pickSurvivingFile(index: Int, path: String)
    /// iCloud versions: keep the file's current contents (`keep-current`).
    case keepCurrentVersion
    /// iCloud versions: make version `index` (0-based) the current
    /// contents (`keep-other:N`).
    case keepOtherVersion(index: Int)

    /// The decision-log answer, or `nil` for actions the log cannot record.
    public func decision(itemID: String) -> UIReviewDecision? {
        switch self {
        case .notDuplicates: .choice(itemID: itemID, choice: "distinct")
        case .syncOnly(let member): .choice(itemID: itemID, choice: "only:\(member + 1)")
        case .keepSyncID(let path): .choice(itemID: itemID, choice: "keep:\(path + 1)")
        case .pickSurvivingFile(let index, _): .choice(itemID: itemID, choice: "keep:\(index + 1)")
        case .keepCurrentVersion: .choice(itemID: itemID, choice: "keep-current")
        case .keepOtherVersion(let index): .choice(itemID: itemID, choice: "keep-other:\(index + 1)")
        case .ignoreForNow: nil
        }
    }
}

/// One side-by-side card in a duplicate group.
public struct UIDuplicateCard: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// An Apple contact (cluster member index when it is one).
        case contact(member: Int?)
        /// A markdown note.
        case note
        /// One version of a file iCloud kept several of (`nil`: the current contents).
        case fileVersion(index: Int?)
    }

    public var id: String
    public var source: Source
    /// `iCloud + Google`, `Markdown`.
    public var heading: String
    public var title: String
    /// Detail lines (organization, emails, phones; folder, id, tags).
    public var lines: [String]
    /// Underlying card ids (contacts) for `addressbook://` links.
    public var cardIDs: [String]
    /// Note path (notes).
    public var path: String?
    public var syncID: UUID?
    /// The per-card action (`Sync Only iCloud`, `Keep This One`, `Keep This File`).
    public var action: UIDuplicateAction?
}

/// A possible duplicate: unlinked contacts (cluster), copied notes (same sync
/// id), one linked contact carrying several stamps (merge records), or a
/// file iCloud kept several differing versions of (M6).
public struct UIDuplicateGroup: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case contacts
        case sameSyncID
        case mergeRecords
        /// iCloud conflict versions of one file: keep the current contents or one version.
        case fileVersions
    }

    /// The review item id.
    public var id: String
    public var kind: Kind
    public var title: String
    /// `2 contacts, 1 file`.
    public var counts: String
    /// `iCloud+Google+md`, `2 files · same sync id`.
    public var sources: String
    public var reasons: [String]
    public var cards: [UIDuplicateCard]
    public var firstSeen: Date

    /// Builds the group for a pending item, or `nil` when it is not a duplicate.
    public init?(_ entry: PendingReview, plan: UIPlanSummary?, notes: [String: UINoteSummary]) {
        let context = Context(id: entry.id, plan: plan, notes: notes)
        if case .duplicateCluster(let members, let reasons) = entry.item {
            self = Self.cluster(members, reasons: reasons, context)
        } else if case .duplicateSyncID(let syncID, let paths) = entry.item {
            self = Self.sameSyncID(syncID, paths: paths, context)
        } else if case .mergeRecords(let contact, let ids, let paths) = entry.item {
            self = Self.mergeRecords(contact, ids: ids, paths: paths, context)
        } else if case .fileVersionConflict(let conflict) = entry.item {
            self = Self.fileVersions(conflict, context)
        } else {
            return nil
        }
        firstSeen = entry.firstSeen
    }

    private init(id: String, kind: Kind, title: String, counts: String, sources: String, reasons: [String]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.counts = counts
        self.sources = sources
        self.reasons = reasons
        self.cards = []
        self.firstSeen = .distantPast
    }

    /// What the builders look things up in.
    private struct Context {
        let id: String
        let plan: UIPlanSummary?
        let notes: [String: UINoteSummary]

        func contactCard(
            _ index: Int, member: Int?, ref: ContactRef, accounts: [AccountKind]
        ) -> UIDuplicateCard {
            let details = plan?.contact(for: ref.cardIDs)
            let names = unique((accounts.isEmpty ? details?.accounts ?? [] : accounts).map(\.displayName))
            var lines: [String] = []
            if let details {
                lines += [details.jobTitle, details.organization].compactMap { $0 }.filter { !$0.isEmpty }
                lines += details.emails + details.phones
            }
            return UIDuplicateCard(
                id: "\(id)-c\(index)", source: .contact(member: member),
                heading: names.isEmpty ? "Contacts" : names.joined(separator: " + "),
                title: details?.title ?? ref.title,
                lines: lines, cardIDs: details?.cardIDs ?? ref.cardIDs, path: nil, syncID: nil,
                action: member.map { .syncOnly(member: $0) })
        }

        func noteCard(_ index: Int, path: String, action: UIDuplicateAction?) -> UIDuplicateCard {
            let note = notes[path]
            let folder = VaultPath.directory(of: path)
            var lines = [folder.isEmpty ? "/" : folder + "/"]
            if let syncID = note?.syncID { lines.append("id \(shortID(syncID))…") }
            if let note {
                lines += note.emails + note.phones
                if !note.tags.isEmpty { lines.append("tags: " + note.tags.joined(separator: ", ")) }
            }
            return UIDuplicateCard(
                id: "\(id)-n\(index)", source: .note, heading: "Markdown",
                title: note?.title ?? VaultPath.stem(of: path),
                lines: lines, cardIDs: [], path: path, syncID: note?.syncID, action: action)
        }
    }

    private static func cluster(_ members: [ClusterMember], reasons: [String], _ context: Context) -> Self {
        let paths = unique(members.compactMap(\.path))
        let accounts = unique(members.flatMap(\.accounts).map(\.displayName))
        var group = Self(
            id: context.id, kind: .contacts, title: members.first?.title ?? "Contact",
            counts: counts(contacts: members.count, files: paths.count),
            sources: (accounts + (paths.isEmpty ? [] : ["md"])).joined(separator: "+"), reasons: reasons)
        group.cards =
            members.enumerated().map { offset, member in
                context.contactCard(offset, member: offset, ref: member.ref, accounts: member.accounts)
            }
            + paths.enumerated().map { context.noteCard($0.offset, path: $0.element, action: nil) }
        return group
    }

    private static func sameSyncID(_ syncID: UUID, paths: [String], _ context: Context) -> Self {
        let title = paths.compactMap { context.notes[$0]?.title }.first ?? paths.first.map { VaultPath.stem(of: $0) }
        var group = Self(
            id: context.id, kind: .sameSyncID, title: title ?? "Note", counts: counts(contacts: 0, files: paths.count),
            sources: "\(paths.count) files · same sync id",
            reasons: ["same sync id \(shortID(syncID))", "a copied file?"])
        group.cards = paths.enumerated().map {
            context.noteCard($0.offset, path: $0.element, action: .keepSyncID(path: $0.offset))
        }
        return group
    }

    private static func mergeRecords(_ contact: ContactRef, ids: [UUID], paths: [String], _ context: Context) -> Self {
        var group = Self(
            id: context.id, kind: .mergeRecords, title: contact.title, counts: counts(contacts: 1, files: paths.count),
            sources: "\(paths.count) files · linked contact",
            reasons: ["\(ids.count) sync ids on one contact", "cards were linked after export"])
        group.cards =
            [context.contactCard(0, member: nil, ref: contact, accounts: [])]
            + paths.enumerated().map {
                context.noteCard(
                    $0.offset, path: $0.element, action: .pickSurvivingFile(index: $0.offset, path: $0.element))
            }
        return group
    }

    /// iCloud kept other versions of a file (`version-…` items): the
    /// current contents first, then one card per version with the device
    /// that saved it, when, and what differs.
    private static func fileVersions(_ conflict: FileVersionConflict, _ context: Context) -> Self {
        let count = conflict.versions.count
        var group = Self(
            id: context.id, kind: .fileVersions, title: conflict.title,
            counts: count == 1 ? "1 other version" : "\(count) other versions",
            sources: "iCloud versions · \(conflict.path)",
            reasons: [
                "iCloud kept \(count) conflicting \(count == 1 ? "version" : "versions") of \(conflict.path)",
                conflict.recordID != nil
                    ? "the note is not synced until you keep one" : "nothing is lost until you keep one",
            ])
        let current = context.notes[conflict.path]
        var currentLines = [conflict.path, "on this Mac now"]
        if let current {
            currentLines += current.emails + current.phones
        }
        group.cards = [
            UIDuplicateCard(
                id: "\(context.id)-current", source: .fileVersion(index: nil), heading: "Current",
                title: current?.title ?? conflict.title, lines: currentLines, cardIDs: [], path: conflict.path,
                syncID: current?.syncID, action: .keepCurrentVersion)
        ]
        group.cards += conflict.versions.enumerated().map { offset, version in
            var lines = ["From \(version.deviceName ?? "another device")"]
            if let modified = version.modifiedAt { lines.append("Modified \(UIFormat.relativeDay(modified))") }
            lines.append(
                version.differences.isEmpty
                    ? "Differs in formatting only"
                    : "Differs: " + version.differences.joined(separator: ", "))
            return UIDuplicateCard(
                id: "\(context.id)-v\(offset)", source: .fileVersion(index: offset),
                heading: "Version \(offset + 1)" + (version.deviceName.map { " · \($0)" } ?? ""),
                title: conflict.title, lines: lines, cardIDs: [],
                path: nil, syncID: nil, action: .keepOtherVersion(index: offset))
        }
        return group
    }

    /// Group-level actions, in display order.
    public var actions: [UIDuplicateAction] {
        switch kind {
        case .contacts: [.notDuplicates, .ignoreForNow]
        case .sameSyncID, .mergeRecords, .fileVersions: [.ignoreForNow]
        }
    }

    /// The confirmation for Keep Current / Keep This Version (iCloud
    /// versions): what happens to the file and to the other versions.
    public func keepVersionMessage(_ action: UIDuplicateAction) -> String {
        let path = cards.first?.path ?? title
        switch action {
        case .keepCurrentVersion:
            return "\(path) stays as it is on this Mac. The other "
                + "\(cards.count - 1 == 1 ? "version is" : "versions are") discarded on the next sync."
        case .keepOtherVersion(let index):
            let card = cards.first { $0.source == .fileVersion(index: index) }
            let from = card?.heading ?? "Version \(index + 1)"
            return "\(path) is replaced with \(from) on the next sync; the current contents and any other "
                + "versions are discarded. The next sync after that treats the result as an edit of the note."
        default:
            return ""
        }
    }

    /// The confirmation for Keep This File (merge records): what happens to
    /// the other notes and to the stamps on the contact's cards. With Apple
    /// writes off the stamp removal is held until they are turned on.
    public func keepFileMessage(keeping path: String, appleWrites: Bool) -> String {
        let others = cards.compactMap(\.path).filter { $0 != path }
        let noun = others.count == 1 ? "note" : "notes"
        let possessive = others.count == 1 ? "note's" : "notes'"
        var message =
            "\(path) stays synced with \(title). The other \(noun) (\(others.joined(separator: ", "))) "
            + "\(others.count == 1 ? "is" : "are") detached on the next sync: marked as no longer synced, "
            + "left in place, nothing is deleted. "
        message +=
            appleWrites
            ? "The \(possessive) sync IDs are removed from \(title)'s cards."
            : "Removing the \(possessive) sync IDs from \(title)'s cards is held until "
                + "“Write changes back to Apple Contacts” is on."
        return message
    }

    /// Every underlying card id (Open in Contacts to Link opens each).
    public var allCardIDs: [String] { cards.flatMap(\.cardIDs) }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(4)) }

    private static func counts(contacts: Int, files: Int) -> String {
        var parts: [String] = []
        if contacts > 0 { parts.append(contacts == 1 ? "1 contact" : "\(contacts) contacts") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        return parts.joined(separator: ", ")
    }
}

/// `values` without repeats, in first-seen order.
private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}
