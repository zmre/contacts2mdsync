internal import Foundation

/// Card writes through Contacts.app scripting (Apple Events), for the writes
/// CNSaveRequest cannot make without the notes entitlement (architecture §6
/// "Write routing", spike S15):
///
/// - every update of a card that **has a note** (fields, labeled values,
///   the stamp URL, group membership) fails with `NSCocoaErrorDomain`
///   134092 and changes nothing;
/// - `removeMember(_:from:)` saves without error but leaves the card in the
///   group (iCloud), with or without a note.
///
/// Contacts.app's `person id X` is the underlying card X, and the `id` of
/// its emails, phones and URLs is the `CNLabeledValue.identifier`, so edits
/// keep identifiers exactly like the Contacts.framework path.
///
/// ContactsAdapter's `ScriptingCardWriter` implements it; tests use
/// `SyncTestSupport.FakeCardScripting`. Calls block and may launch
/// Contacts.app (hidden); they never prompt for permission.
public protocol CardScripting: Sendable {
    /// Whether scripted writes can be sent now, without asking anything.
    /// May launch Contacts.app (hidden) to ask macOS; never prompts.
    func availability() -> NotesAvailability

    /// Applies `operations` (updates, stamps, unstamps and group changes of
    /// existing cards; never creates or deletes) card by card, one `save`
    /// per card. Edits that cannot be expressed are reported in `skipped`
    /// (the rest of the operation is applied); a card that fails is in
    /// `failed`, the others are unaffected. Throws `NotesUnavailableError`
    /// when nothing can be written (no permission: `permissionDenied`,
    /// Contacts.app not answering).
    func apply(_ operations: [AppleWriteOperation]) throws -> AppleWriteResult

    /// Called once after a sync run: quits Contacts.app when this session
    /// launched it and the user is not using it.
    func finishSession()
}

extension CardScripting {
    /// Default: nothing to clean up.
    public func finishSession() {}
}

/// What Contacts.app scripting can and cannot write (Contacts.sdef, spike S15).
public enum CardScriptingSupport {
    /// The reason recorded for edits scripting cannot express.
    public static let reason = "needs entitlement or not scriptable"

    /// Why `edit` cannot be written through Contacts.app scripting; `nil`
    /// when it can (element-level limits, such as an instant-message service
    /// Contacts.app has no `service type` for, are found by the writer).
    ///
    /// - The note goes through the notes path (`NotesBridgedStore`), never here.
    /// - `image` is a TIFF picture in scripting: Contacts would keep a TIFF
    ///   instead of our JPEG/PNG bytes, so the image never round-trips.
    /// - `birth date` and custom dates are AppleScript `date`s (local
    ///   date-times): no month-day-only birthdays, and the day can shift
    ///   with the time zone. Not written until verified on scratch cards.
    /// - There is no `phonetic organization` property.
    public static func unsupported(_ edit: CardEdit) -> String? {
        switch edit {
        case .note: "\(reason) (the note is written separately)"
        case .image: "\(reason) (image)"
        case .birthday: "\(reason) (birthday)"
        case .list(.dates, _): "\(reason) (dates)"
        case .scalar(.phoneticOrganizationName, _): "\(reason) (phonetic organization name)"
        case .scalar, .list: nil
        }
    }
}
