internal import Foundation

/// Where Contacts notes come from (architecture §8 "Notes").
public enum NotesSource: String, Hashable, Sendable, Codable {
    /// `CNContactNoteKey` (the `com.apple.developer.contacts.notes` entitlement).
    case entitlement
    /// Scripting Contacts.app with Apple Events (no entitlement; spike S12).
    case scripting

    /// Short text for output and Settings.
    public var displayName: String {
        switch self {
        case .entitlement: "Contacts entitlement"
        case .scripting: "Contacts.app scripting"
        }
    }
}

/// This Mac's Automation permission for controlling Contacts.app.
public enum NotesPermission: String, Hashable, Sendable, Codable {
    case granted
    /// Never asked: the first Apple Event would show the "control Contacts" prompt.
    case notDetermined = "not-determined"
    /// Refused (System Settings ▸ Privacy & Security ▸ Automation).
    case denied
    /// Contacts.app is not running, so macOS cannot say yet (checked at the next sync).
    case unknown
}

/// Whether notes can be read and written right now, and how.
public enum NotesAvailability: Hashable, Sendable {
    /// The notes entitlement is present: `CNContactNoteKey` works.
    case entitlement
    /// Contacts.app scripting, with this Automation permission state.
    case scripting(NotesPermission)
    /// Neither (reason for display).
    case unavailable(String)

    /// `true` when notes can be read and written without asking anything.
    public var isUsable: Bool {
        switch self {
        case .entitlement, .scripting(.granted): true
        case .scripting, .unavailable: false
        }
    }
}

/// The outcome of `NotesProvider.write`.
public struct NotesWriteResult: Hashable, Sendable {
    /// Cards whose note was set and saved.
    public var written: [String]
    /// Cards whose note could not be set (`-1728` no such person, a refused
    /// save, …): card id → message. Per card; other cards are unaffected.
    public var failed: [String: String]

    /// Creates a result.
    public init(written: [String] = [], failed: [String: String] = [:]) {
        self.written = written
        self.failed = failed
    }
}

/// A notes failure that concerns the whole session, not one card: no
/// permission, Contacts.app not reachable, a timeout. The caller skips
/// notes for the run (reads) or reports the writes as failed (retried).
public struct NotesUnavailableError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    /// `true` when Automation permission was refused (`-1743`).
    public var permissionDenied: Bool

    /// Creates an error.
    public init(_ message: String, permissionDenied: Bool = false) {
        self.message = message
        self.permissionDenied = permissionDenied
    }

    public var description: String { message }
}

/// Reads and writes Contacts notes **per underlying card** (architecture §8).
///
/// Two implementations live in ContactsAdapter: `EntitlementNotesProvider`
/// (`CNContactNoteKey`) and `ScriptingNotesProvider` (Apple Events to
/// Contacts.app; Contacts.app's `person` is the underlying card and its `id`
/// is the CNContact card identifier, spike S12). Tests use
/// `SyncTestSupport.FakeNotesProvider`.
///
/// Calls block and may launch Contacts.app; run them off the main actor.
/// Implementations never prompt for permission except in
/// `requestPermission()`, which only the app calls, from a user action.
public protocol NotesProvider: Sendable {
    /// The source behind this provider.
    var source: NotesSource { get }

    /// Whether notes are usable now. May launch Contacts.app (hidden) to
    /// ask macOS for the Automation state; never prompts.
    func availability() -> NotesAvailability

    /// The permission state without side effects (no launch, no prompt);
    /// `unknown` when it cannot be told that way.
    func currentPermission() -> NotesPermission

    /// Asks for permission when it was never decided (shows the macOS
    /// "control Contacts" prompt once). Only for an explicit user action in
    /// the app; never called by sync runs.
    func requestPermission() -> NotesAvailability

    /// The notes of `cardIDs` (`nil`: every card), card id → text (`nil` =
    /// no note). A card the provider could not see is **absent** (unknown),
    /// never reported as empty. Throws `NotesUnavailableError` when the
    /// whole read fails.
    func readAll(cardIDs: [String]?) throws -> [String: String?]

    /// Sets each card's note (`nil` or `""` clears it), card by card.
    /// Throws `NotesUnavailableError` when nothing can be written at all.
    func write(_ notes: [String: String?]) throws -> NotesWriteResult

    /// Called once after a sync run (and after a dry run): quits Contacts.app
    /// when this provider launched it and the user is not using it.
    func finishSession()
}

extension NotesProvider {
    /// Default: asking changes nothing.
    public func requestPermission() -> NotesAvailability { availability() }

    /// Default: nothing to clean up.
    public func finishSession() {}

    /// Default: unknown.
    public func currentPermission() -> NotesPermission { .unknown }
}

/// How a raw Contacts note becomes the canonical body (and back).
public enum AppleNoteText {
    /// The canonical body of a note: line endings normalized (`\r\n` and
    /// classic `\r` become `\n`, as Contacts may convert them), trailing
    /// whitespace dropped, one final newline; `nil` for an empty note.
    /// Leading text is kept as is.
    public static func body(fromNote note: String?) -> String? {
        guard let note else { return nil }
        var text = note.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text.contains(where: { !$0.isWhitespace }) ? text + "\n" : nil
    }

    /// The note text written for a body (`nil`/blank clears the note).
    public static func note(fromBody body: String?) -> String {
        ComparisonKeys.body(body)
    }
}
