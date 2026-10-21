public import ContactModel
public import Foundation
public import SyncEngine

// MARK: - Deletions (docs/ui.md §6)

/// Which side lost the record.
public enum UIDeletionSide: String, CaseIterable, Hashable, Sendable, Identifiable {
    case contacts
    case markdown

    public var id: Self { self }

    public var title: String {
        switch self {
        case .contacts: "Deleted in Contacts"
        case .markdown: "Deleted in Markdown"
        }
    }
}

/// What to do about a deletion. The first option per side is the
/// non-destructive default.
public enum UIDeletionOption: String, CaseIterable, Hashable, Sendable, Identifiable {
    case keepFileUnlink
    case deleteFile
    case restoreContact
    case restoreFile
    case unlinkKeepContact
    case deleteAppleContact

    public var id: Self { self }

    public var title: String {
        switch self {
        case .keepFileUnlink: "Keep File, Unlink"
        case .deleteFile: "Delete File"
        case .restoreContact: "Restore Contact"
        case .restoreFile: "Restore File"
        case .unlinkKeepContact: "Unlink, Keep Contact"
        case .deleteAppleContact: "Delete Apple Contact…"
        }
    }

    /// Moves a file to the Trash or deletes Apple cards.
    public var isDestructive: Bool { self == .deleteFile || self == .deleteAppleContact }

    /// Needs Apple writes (`apple_writes: enabled`) to take effect.
    public var writesToContacts: Bool { self == .restoreContact || self == .deleteAppleContact }

    /// The engine's choice (`review decide`): `keep | trash | restore` for
    /// Deleted in Contacts, `restore | unlink | delete-contact` for Deleted in Markdown.
    public var choice: String {
        switch self {
        case .keepFileUnlink: "keep"
        case .deleteFile: "trash"
        case .restoreContact: "restore"
        case .restoreFile: "restore"
        case .unlinkKeepContact: "unlink"
        case .deleteAppleContact: "delete-contact"
        }
    }

    /// Options for `side`, default first.
    public static func options(for side: UIDeletionSide) -> [UIDeletionOption] {
        switch side {
        case .contacts: [.keepFileUnlink, .deleteFile, .restoreContact]
        case .markdown: [.restoreFile, .unlinkKeepContact, .deleteAppleContact]
        }
    }
}

/// A queued deletion.
public struct UIDeletionRow: Identifiable, Hashable, Sendable {
    /// The review item id.
    public var id: String
    public var side: UIDeletionSide
    public var title: String
    /// The file (Deleted in Contacts) or where it was (Deleted in Markdown).
    public var path: String?
    public var noticed: Date?
    public var recordID: UUID
    /// Apple cards (Deleted in Markdown: the contact that is kept until decided).
    public var cardIDs: [String]
    public var accounts: [AccountKind]
    /// `false` for notes found missing by a one-way export (no decision kind;
    /// the next sync turns them into actionable Deleted in Markdown items).
    public var isActionable: Bool

    /// Creates a row.
    public init(
        id: String, side: UIDeletionSide, title: String, path: String?, noticed: Date?, recordID: UUID,
        cardIDs: [String] = [], accounts: [AccountKind] = [], isActionable: Bool = true
    ) {
        self.id = id
        self.side = side
        self.title = title
        self.path = path
        self.noticed = noticed
        self.recordID = recordID
        self.cardIDs = cardIDs
        self.accounts = accounts
        self.isActionable = isActionable
    }

    public var options: [UIDeletionOption] { UIDeletionOption.options(for: side) }

    /// `iCloud + Google`.
    public var accountsText: String {
        var names: [String] = []
        for name in accounts.map(\.displayName) where !names.contains(name) { names.append(name) }
        return names.joined(separator: " + ")
    }

    /// Rows for the open delete items: Deleted in Contacts (`appleDeleted`),
    /// Deleted in Markdown (`markdownDeleted`), and notes a one-way export
    /// found missing (`missingFile`, not actionable until a sync).
    public static func rows(_ open: [PendingReview], records: RecordMap) -> [UIDeletionRow] {
        open.compactMap { entry -> UIDeletionRow? in
            switch entry.item {
            case .appleDeleted(let recordID, let title, let path):
                return UIDeletionRow(
                    id: entry.id, side: .contacts, title: title, path: path, noticed: entry.firstSeen,
                    recordID: recordID)
            case .markdownDeleted(let contact, let recordID, let title, let lastPath):
                let binding = records.records[recordID]
                return UIDeletionRow(
                    id: entry.id, side: .markdown, title: title, path: lastPath, noticed: entry.firstSeen,
                    recordID: recordID, cardIDs: contact.cardIDs, accounts: binding?.cards.map(\.accountKind) ?? [])
            case .missingFile(let title, let recordID, let lastPath):
                let binding = records.records[recordID]
                return UIDeletionRow(
                    id: entry.id, side: .markdown, title: title, path: lastPath, noticed: entry.firstSeen,
                    recordID: recordID, cardIDs: binding?.cardIDs ?? [],
                    accounts: binding?.cards.map(\.accountKind) ?? [], isActionable: false)
            default:
                return nil
            }
        }
        .sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }
    }
}

/// A chosen deletion action.
public struct UIDeletionChoice: Hashable, Sendable {
    /// The review item id.
    public var id: String
    public var option: UIDeletionOption

    /// Creates a choice.
    public init(id: String, option: UIDeletionOption) {
        self.id = id
        self.option = option
    }

    /// The decision-log answer (`review decide <id> <choice>`).
    public var decision: UIReviewDecision { .choice(itemID: id, choice: option.choice) }
}
