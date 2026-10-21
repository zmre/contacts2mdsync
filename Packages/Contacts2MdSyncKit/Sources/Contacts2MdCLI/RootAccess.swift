public import Foundation
public import SyncEngine

/// A notes root opened for this run. For a security-scoped bookmark,
/// `close()` ends access (call it when the run is over).
public final class ResolvedRoot: Sendable {
    public let url: URL
    private let stop: @Sendable () -> Void

    /// Wraps `url`; `stop` runs once on `close()`.
    public init(url: URL, stop: @escaping @Sendable () -> Void = {}) {
        self.url = url
        self.stop = stop
    }

    /// The folder path, for output.
    public var path: String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Ends security-scoped access, if any.
    public func close() { stop() }
}

/// Why a root could not be opened (CLI exit 3).
public struct RootAccessError: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String

    /// Creates an error.
    public init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// How the CLI finds the notes folder: `--root`, or the folder chosen in the
/// app (a security-scoped, app-scope bookmark). A sandboxed binary can only
/// reach the folder through that bookmark, so even with `--root` the bookmark
/// is used when it covers the path.
public struct RootAccess: Sendable {
    /// Resolves `explicitRoot` (already `~`-expanded), or the saved folder when `nil`.
    public var resolve: @Sendable (_ explicitRoot: String?) throws -> ResolvedRoot

    /// Creates a resolver.
    public init(resolve: @escaping @Sendable (_ explicitRoot: String?) throws -> ResolvedRoot) {
        self.resolve = resolve
    }

    /// `--root` only (tests, dev builds).
    public static let explicitOnly = RootAccess { root in
        guard let root else {
            throw RootAccessError("no notes folder: pass --root, or choose a folder in Contacts2MdSync first")
        }
        return ResolvedRoot(url: URL(filePath: root, directoryHint: .isDirectory))
    }

    /// `--root`, else (and for access) the bookmark saved by the app.
    public static func bookmark(_ bookmark: RootBookmark) -> RootAccess {
        RootAccess { root in
            let saved = try? bookmark.open()
            guard let root else {
                guard let saved else {
                    throw RootAccessError(
                        "not configured: no notes folder chosen. Open Contacts2MdSync and choose one, or pass --root")
                }
                return saved
            }
            let wanted = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL.path(
                percentEncoded: false)
            if let saved {
                let base = saved.url.standardizedFileURL.path(percentEncoded: false)
                let prefix = base.hasSuffix("/") ? base : base + "/"
                if wanted == base || wanted + "/" == prefix || wanted.hasPrefix(prefix) {
                    return ResolvedRoot(url: URL(filePath: root, directoryHint: .isDirectory)) { saved.close() }
                }
                saved.close()
            }
            return ResolvedRoot(url: URL(filePath: root, directoryHint: .isDirectory))
        }
    }
}

/// The notes-folder bookmark the app saves after the user picks a folder
/// (`<state>/root.bookmark`), plus small app settings (`<state>/settings.json`).
///
/// The app binary and its CLI share one sandbox container, so the CLI reads
/// the same files and gets the same folder access.
public struct RootBookmark: Sendable {
    public let directory: URL

    /// Settings saved next to the bookmark.
    public struct Settings: Codable, Hashable, Sendable {
        /// Folder for new notes, applied on the first export (then config.yaml rules).
        public var defaultFolder: String?
        /// Path of the chosen root when it was saved, for display.
        public var rootPath: String?

        /// Creates settings.
        public init(defaultFolder: String? = nil, rootPath: String? = nil) {
            self.defaultFolder = defaultFolder
            self.rootPath = rootPath
        }
    }

    /// Creates a store in `directory`.
    public init(directory: URL) { self.directory = directory }

    private var bookmarkURL: URL { directory.appending(path: "root.bookmark") }
    private var settingsURL: URL { directory.appending(path: "settings.json") }

    /// `true` when a folder was saved.
    public var exists: Bool { FileManager.default.fileExists(atPath: bookmarkURL.path(percentEncoded: false)) }

    /// Saves a security-scoped bookmark for `url` (which must be accessible
    /// now, e.g. just chosen in an open panel).
    public func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: bookmarkURL, options: .atomic)
        var settings = loadSettings()
        settings.rootPath = url.path(percentEncoded: false)
        try saveSettings(settings)
    }

    /// Resolves the bookmark and starts security-scoped access. A stale
    /// bookmark is refreshed. Throws `RootAccessError` when unusable.
    public func open() throws -> ResolvedRoot {
        guard let data = try? Data(contentsOf: bookmarkURL) else {
            throw RootAccessError("not configured: no notes folder chosen in Contacts2MdSync")
        }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &stale)
        } catch {
            throw RootAccessError(
                "the saved notes folder can no longer be opened (\(error.localizedDescription)); "
                    + "open Contacts2MdSync and choose it again")
        }
        let started = url.startAccessingSecurityScopedResource()
        if stale { try? save(url) }
        return ResolvedRoot(url: url) { if started { url.stopAccessingSecurityScopedResource() } }
    }

    /// Settings (empty when none saved).
    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    /// Saves settings.
    public func saveSettings(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }
}

/// `<state>/device.json`: this device's stable id and current name.
public struct DeviceIdentityFile: Sendable {
    public let directory: URL

    /// Creates the file accessor.
    public init(directory: URL) { self.directory = directory }

    /// The saved identity (name refreshed from the computer name), created once.
    public func loadOrCreate(name: String = DeviceIdentityFile.computerName) throws -> DeviceIdentity {
        let url = directory.appending(path: "device.json")
        if let data = try? Data(contentsOf: url),
            var identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data), !identity.id.isEmpty
        {
            if identity.name != name {
                identity.name = name
                try? write(identity, to: url)
            }
            return identity
        }
        let identity = DeviceIdentity(id: UUID().uuidString.lowercased(), name: name)
        try write(identity, to: url)
        return identity
    }

    private func write(_ identity: DeviceIdentity, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(identity).write(to: url, options: .atomic)
    }

    /// The computer name (System Settings ▸ General ▸ Sharing).
    public static var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
