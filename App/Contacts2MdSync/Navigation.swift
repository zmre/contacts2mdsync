import ContactModel
import Contacts2MdCLI
import Foundation

/// Top-level sections of the main window (docs/ui.md §1).
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview
    case conflicts
    case markdownOnly
    case deletions
    case duplicates
    case allContacts
    case activity

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .conflicts: "Conflicts"
        case .markdownOnly: "Markdown Only"
        case .deletions: "Deletions"
        case .duplicates: "Duplicates"
        case .allContacts: "All Contacts"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .conflicts: "exclamationmark.triangle"
        case .markdownOnly: "doc.text"
        case .deletions: "trash"
        case .duplicates: "person.2"
        case .allContacts: "person.crop.rectangle.stack"
        case .activity: "clock.arrow.circlepath"
        }
    }

    /// The review queue behind a Review item.
    var queue: UIReviewQueue? {
        switch self {
        case .conflicts: .conflicts
        case .markdownOnly: .markdownOnly
        case .deletions: .deletions
        case .duplicates: .duplicates
        case .overview, .allContacts, .activity: nil
        }
    }

    init(_ queue: UIReviewQueue) {
        switch queue {
        case .conflicts: self = .conflicts
        case .markdownOnly: self = .markdownOnly
        case .deletions: self = .deletions
        case .duplicates: self = .duplicates
        }
    }

    static let review: [SidebarItem] = [.conflicts, .markdownOnly, .deletions, .duplicates]
}

/// What the inspector shows (docs/ui.md §1: card summary, file, sync id, accounts).
struct InspectorItem: Equatable {
    struct Detail: Hashable {
        var label: String
        var value: String
    }

    var title: String
    var subtitle: String?
    var path: String?
    var syncID: UUID?
    var accounts: String?
    var cardIDs: [String] = []
    var details: [Detail] = []
}

// MARK: - Inspector items

extension InspectorItem {
    init(_ row: UILibraryRow) {
        self.init(
            title: row.title, subtitle: row.folder.isEmpty ? nil : row.folder + "/", path: row.path, syncID: row.id,
            accounts: row.accountsText, cardIDs: row.cardIDs)
    }

    init(_ card: UIDuplicateCard, group: UIDuplicateGroup) {
        self.init(
            title: card.title, subtitle: card.heading, path: card.path, syncID: card.syncID,
            accounts: card.path == nil ? card.heading : nil, cardIDs: card.cardIDs,
            details: [Detail(label: "Why", value: group.reasons.joined(separator: " · "))]
                + card.lines.map { Detail(label: "", value: $0) })
    }

    init(_ row: UIMarkdownOnlyRow) {
        var details: [Detail] = []
        if let note = row.note {
            details += [note.jobTitle, note.organization].compactMap { $0 }.map { Detail(label: "", value: $0) }
            details += (note.emails + note.phones).map { Detail(label: "", value: $0) }
            if !note.tags.isEmpty { details.append(Detail(label: "Tags", value: note.tags.joined(separator: ", "))) }
        }
        for match in row.matches {
            details.append(
                Detail(
                    label: "Possible match",
                    value: "\(match.title) (\(match.confidence.formatted(.number.precision(.fractionLength(1))))): "
                        + match.reasons.joined(separator: ", ")))
        }
        if row.isOrphaned { details.append(Detail(label: "Note", value: "Has a sync id no contact is linked to")) }
        self.init(
            title: row.title, subtitle: row.kind == .organization ? "Organization" : "Person", path: row.path,
            syncID: row.note?.syncID, accounts: nil, cardIDs: row.bestMatch?.contact.cardIDs ?? [], details: details)
    }

    init(_ row: DeletionRow) {
        self.init(
            title: row.title, subtitle: row.side.title, path: row.side == .contacts ? row.path : nil, syncID: nil,
            accounts: nil, cardIDs: row.side == .markdown ? row.cardIDs : [],
            details: row.path.map { [Detail(label: row.side == .contacts ? "File" : "Was at", value: $0)] } ?? [])
    }

    init(_ record: ConflictRecord) {
        self.init(
            title: record.title, subtitle: "Changed on both sides", path: record.path, syncID: nil, accounts: nil,
            cardIDs: record.cardIDs,
            details: record.fields.map { Detail(label: $0.name, value: "\($0.contacts) ↔ \($0.markdown)") })
    }
}
