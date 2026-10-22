public import ContactModel
public import Foundation
public import SyncEngine
internal import Synchronization

/// Contacts notes preferences of **this Mac** (Settings ▸ Advanced ▸
/// Contact notes, `contacts2md config --notes on|off`).
///
/// Stored in the device state folder (`<state>/notes.json`, next to
/// `triggers.json`), not in the vault's `config.yaml`: notes through
/// Contacts.app scripting need this Mac's Automation permission, which is
/// granted per machine. Vault-independent.
public struct NotesSettings: Codable, Hashable, Sendable {
    /// Sync Contacts notes through Contacts.app scripting when the notes
    /// entitlement is missing (`notes_sync: on`). Default off. With the
    /// entitlement, notes are always synced.
    public var notesSync: Bool
    /// Quit Contacts.app after a sync when the sync launched it and it is
    /// still hidden (the user is not using it). Default on.
    public var quitContactsAfterSync: Bool

    /// Creates settings.
    public init(notesSync: Bool = false, quitContactsAfterSync: Bool = true) {
        self.notesSync = notesSync
        self.quitContactsAfterSync = quitContactsAfterSync
    }

    enum CodingKeys: String, CodingKey {
        case notesSync = "notes_sync"
        case quitContactsAfterSync = "quit_contacts_after_sync"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .notesSync)
        self.init(
            notesSync: text == "on",
            quitContactsAfterSync: try container.decodeIfPresent(Bool.self, forKey: .quitContactsAfterSync) ?? true)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notesSync ? "on" : "off", forKey: .notesSync)
        try container.encode(quitContactsAfterSync, forKey: .quitContactsAfterSync)
    }
}

/// Reads and writes `NotesSettings` as `<directory>/notes.json`.
public struct NotesSettingsStore: Sendable {
    public let directory: URL

    /// Creates a store in the device state folder (`CLIEnvironment.stateDirectory`).
    public init(directory: URL) { self.directory = directory }

    var url: URL { directory.appending(path: "notes.json") }

    /// The saved settings, or the defaults (notes off) when none or unreadable.
    public func load() -> NotesSettings {
        guard let data = try? Data(contentsOf: url) else { return NotesSettings() }
        return (try? JSONDecoder().decode(NotesSettings.self, from: data)) ?? NotesSettings()
    }

    /// Saves settings atomically.
    public func save(_ settings: NotesSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// Copies the Contacts notes about to be overwritten to
/// `<backups>/apple-notes-<time>.json` (card id → old text; last 10 kept).
/// The vCard backup taken before Apple writes cannot hold them: without the
/// notes entitlement Contacts.framework never sees notes.
public struct AppleNotesBackup: Sendable {
    public let directory: URL
    public let keep: Int
    let now: @Sendable () -> Date

    /// Creates a backup writer.
    public init(directory: URL, keep: Int = 10, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.keep = keep
        self.now = now
    }

    /// Writes one backup file; returns its URL.
    @discardableResult
    public func save(_ notes: [String: String?]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now())
        var url = directory.appending(path: "apple-notes-\(stamp).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = directory.appending(path: "apple-notes-\(stamp)-\(suffix).json")
            suffix += 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let plain = notes.mapValues { $0 ?? "" }
        try encoder.encode(plain).write(to: url, options: .withoutOverwriting)
        let old = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("apple-notes-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in old.dropFirst(keep) { try FileManager.default.removeItem(at: stale) }
        return url
    }
}

/// The notes side of one prepared run: the provider (so the run can quit
/// Contacts.app when done) and the bridge's log. `finish()` runs once, at
/// the latest when the last copy of the prepared run goes away.
public final class NotesRunHandle: Sendable {
    /// The provider used or asked this run (`nil`: notes off or entitled).
    public let provider: (any NotesProvider)?
    /// The bridge reading and writing notes (`nil` unless scripting is active).
    public let bridge: NotesBridgedStore?
    private let finished = Mutex(false)

    init(provider: (any NotesProvider)?, bridge: NotesBridgedStore?) {
        self.provider = provider
        self.bridge = bridge
    }

    /// Ends the provider's session (quits Contacts.app if this run launched it).
    public func finish() {
        let first = finished.withLock { done in
            defer { done = true }
            return !done
        }
        if first { provider?.finishSession() }
    }

    deinit { finish() }
}
