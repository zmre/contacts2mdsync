public import Foundation

extension AppleWriteOperation {
    /// `update (job title, emails)`, `add to group`, … for messages.
    public var summary: String {
        switch self {
        case .stamp: "stamp"
        case .removeStamp: "unstamp"
        case .update(_, let edits): "update (\(edits.map(\.fieldName).joined(separator: ", ")))"
        case .create: "create"
        case .delete: "delete"
        case .addMember: "add to group"
        case .removeMember: "remove from group"
        }
    }
}

extension CardEdit {
    /// `job title`, `emails`, `birthday`, … for messages.
    public var fieldName: String {
        switch self {
        case .scalar(let field, _):
            field.rawValue.replacing(/([a-z])([A-Z])/) { "\($0.output.1) \($0.output.2.lowercased())" }
        case .birthday: "birthday"
        case .list(let field, _): field.rawValue
        case .note: "note"
        case .image: "image"
        }
    }
}

/// A batch of Apple writes saved together.
public struct AppleWriteBatch: Hashable, Sendable {
    public var operations: [AppleWriteOperation]
    /// What the run knows about each target card's Contacts note: card id →
    /// `true` (has a note) / `false` (none). Absent: unknown (notes not read).
    /// Without the notes entitlement, CNSaveRequest fails every update of a
    /// card that has a note (spike S15, error 134092), so the store routes
    /// those writes through Contacts.app scripting (architecture §6).
    public var cardNotes: [String: Bool]

    /// Creates a batch.
    public init(operations: [AppleWriteOperation], cardNotes: [String: Bool] = [:]) {
        self.operations = operations
        self.cardNotes = cardNotes
    }
}

/// Outcome of `ContactStore.apply`.
public struct AppleWriteResult: Hashable, Sendable {
    /// Operations that were saved.
    public var applied: [AppleWriteOperation]
    /// Operations that failed, with a message each.
    public var failed: [AppleWriteFailure]
    /// Card ids of created contacts, by `NewAppleContact.recordID`.
    public var createdCardIDs: [UUID: String]
    /// Operations not attempted and not failed: they wait for something the
    /// user must allow (Automation permission for Contacts). Retried next run.
    public var held: [AppleWriteHold]
    /// Edits of applied operations that could not be expressed on their
    /// route (e.g. an image through Contacts.app scripting). The rest of the
    /// operation was applied; the executor marks these unapplyable.
    public var skipped: [AppleWriteSkip]
    /// Applied operations that went through Contacts.app scripting (no
    /// `transactionAuthor`: their history events are not excluded by author).
    public var scripted: [AppleWriteOperation]

    /// Creates a result.
    public init(
        applied: [AppleWriteOperation], failed: [AppleWriteFailure] = [], createdCardIDs: [UUID: String] = [:],
        held: [AppleWriteHold] = [], skipped: [AppleWriteSkip] = [], scripted: [AppleWriteOperation] = []
    ) {
        self.applied = applied
        self.failed = failed
        self.createdCardIDs = createdCardIDs
        self.held = held
        self.skipped = skipped
        self.scripted = scripted
    }
}

/// One failed Apple write.
public struct AppleWriteFailure: Hashable, Sendable {
    public var operation: AppleWriteOperation
    public var message: String
    /// The Contacts framework refused the save because the card has a note
    /// and the notes entitlement is missing (`NSCocoaErrorDomain` 134092,
    /// spike S15). Nothing of the save was kept; Contacts.app scripting can
    /// make the same change.
    public var rejectedForNote: Bool

    /// Creates a failure.
    public init(operation: AppleWriteOperation, message: String, rejectedForNote: Bool = false) {
        self.operation = operation
        self.message = message
        self.rejectedForNote = rejectedForNote
    }
}

/// An Apple write that waits for the user (not a failure, not unapplyable).
public struct AppleWriteHold: Hashable, Sendable {
    public var operation: AppleWriteOperation
    /// Why it waits, for `held apple …` lines and banners.
    public var reason: String

    /// Creates a hold.
    public init(operation: AppleWriteOperation, reason: String) {
        self.operation = operation
        self.reason = reason
    }
}

/// One edit of an applied operation that its route could not express.
public struct AppleWriteSkip: Hashable, Sendable {
    public var operation: AppleWriteOperation
    public var edit: CardEdit
    public var reason: String

    /// Creates a skip.
    public init(operation: AppleWriteOperation, edit: CardEdit, reason: String) {
        self.operation = operation
        self.edit = edit
        self.reason = reason
    }
}
