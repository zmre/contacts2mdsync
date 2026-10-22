public import ContactModel
internal import Foundation
public import SyncEngine

/// How a run reads Contacts notes, decided before the Apple read.
struct NotesSetup {
    /// The store the run reads and writes (bridged when scripting is active).
    var store: any ContactStore
    var status: NotesStatus
    var handle: NotesRunHandle
}

/// What the app shows in Settings ▸ Advanced ▸ Contact notes.
public struct NotesSourceStatus: Hashable, Sendable {
    /// The entitlement is present (notes always synced, no setting).
    public var entitled: Bool
    /// `notes_sync` on this Mac.
    public var settings: NotesSettings
    /// The Automation permission (`unknown` while Contacts.app is not running).
    public var permission: NotesPermission

    /// The source in effect: Entitlement, Contacts.app scripting, or off.
    public var source: NotesSource? {
        if entitled { return .entitlement }
        return settings.notesSync && permission != .denied ? .scripting : nil
    }
}

extension VaultSession {
    /// This Mac's notes settings.
    public var notesSettingsStore: NotesSettingsStore { NotesSettingsStore(directory: environment.stateDirectory) }

    /// Chooses the notes source for a run (architecture §8): the entitlement
    /// when present; else Contacts.app scripting when `notes_sync` is on;
    /// else none (bodies markdown-only). The Automation permission is
    /// checked when notes are first read, so a run that reads no notes (an
    /// incremental run with nothing touched) never launches Contacts.app.
    /// Never prompts: without permission the read fails and the run skips
    /// notes with a warning — not "off": the notes base is kept for the
    /// next run with permission.
    func notesSetup(for base: any ContactStore, backups: URL) -> NotesSetup {
        if (try? base.capabilities.notesAvailable) == true {
            return NotesSetup(
                store: base, status: NotesStatus(source: .entitlement),
                handle: NotesRunHandle(provider: nil, bridge: nil))
        }
        let settings = notesSettingsStore.load()
        guard settings.notesSync, let provider = environment.makeNotesProvider(settings) else {
            return NotesSetup(store: base, status: .off, handle: NotesRunHandle(provider: nil, bridge: nil))
        }
        let clock = environment.clock
        let backup = AppleNotesBackup(directory: backups, now: { clock.now })
        let bridge = NotesBridgedStore(
            inner: base, provider: provider, ownWrites: environment.notesOwnWrites,
            backup: { notes in try backup.save(notes) }, now: { clock.now })
        return NotesSetup(
            store: bridge, status: NotesStatus(source: provider.source),
            handle: NotesRunHandle(provider: provider, bridge: bridge))
    }

    /// The warning of a run whose notes read failed.
    static func skipWarning(_ log: NotesRunLog) -> String? {
        guard let failure = log.readFailure else { return nil }
        return log.readFailureIsPermission
            ? permissionWarning : "Contacts notes could not be read (\(failure)); notes skipped"
    }

    /// The headless warning when notes are on but not permitted.
    public static let permissionWarning = "Automation permission for Contacts not granted; notes skipped"

    /// The notes source, settings and permission for Settings and `status`
    /// (no prompt; Contacts.app is not launched, so the permission may be
    /// `unknown`).
    public func notesSourceStatus() -> NotesSourceStatus {
        let settings = notesSettingsStore.load()
        let entitled = (try? environment.makeStore().capabilities.notesAvailable) == true
        let permission =
            entitled ? .granted : environment.makeNotesProvider(settings)?.currentPermission() ?? .unknown
        return NotesSourceStatus(entitled: entitled, settings: settings, permission: permission)
    }
}
