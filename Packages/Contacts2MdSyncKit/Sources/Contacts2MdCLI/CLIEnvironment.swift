public import ContactModel
internal import ContactsAdapter
public import Foundation
internal import PhoneNumberKeys
public import SyncEngine
internal import SyncStateDB
internal import Synchronization
public import VaultIndex

/// Everything the CLI touches outside itself, injectable for tests.
///
/// `live()` wires the real Contacts store, the real file system and
/// `~/Library/Application Support/Contacts2MdSync`; tests pass a
/// `FakeContactStore`, an `InMemoryVault` and a temp directory.
public struct CLIEnvironment: Sendable {
    /// Opens the Apple contact store. Throws `ContactStoreError.accessDenied`
    /// when access is not granted (the CLI never prompts).
    public var makeStore: @Sendable () throws -> any ContactStore
    /// The vault file system for a root folder.
    public var makeVault: @Sendable (URL) -> any VaultFS
    /// `true` when `url` is an existing directory.
    public var isDirectory: @Sendable (URL) -> Bool
    /// Per-device state lives under here: `<vault_id>/state.sqlite`,
    /// `backups/`, `device.json`, the folder bookmark and app settings.
    public var stateDirectory: URL
    /// Phone comparison keys for a region.
    public var makeKeyer: @Sendable (String) -> any PhoneKeyer
    public var ids: any IDGenerator
    public var clock: any SyncClock
    public var timeZone: TimeZone
    /// Region used when neither `--region` nor the config sets one.
    public var fallbackRegion: String
    public var output: CLIOutput
    /// Opens the per-device state store in a vault's state folder.
    public var makeStateStore: @Sendable (URL) throws -> any SyncStateStore
    /// This device (stable id + name).
    public var device: @Sendable () throws -> DeviceIdentity
    /// Turns `--root` (or the saved folder bookmark when omitted) into a folder.
    public var rootAccess: RootAccess
    /// `CLI` or `GUI`, recorded with each session.
    public var trigger: String

    /// Creates an environment.
    public init(
        makeStore: @escaping @Sendable () throws -> any ContactStore,
        makeVault: @escaping @Sendable (URL) -> any VaultFS,
        isDirectory: @escaping @Sendable (URL) -> Bool,
        stateDirectory: URL,
        makeKeyer: @escaping @Sendable (String) -> any PhoneKeyer,
        ids: any IDGenerator,
        clock: any SyncClock,
        timeZone: TimeZone,
        fallbackRegion: String,
        output: CLIOutput,
        makeStateStore: @escaping @Sendable (URL) throws -> any SyncStateStore = CLIEnvironment.openStateStore,
        device: @escaping @Sendable () throws -> DeviceIdentity = {
            DeviceIdentity(id: "00000000-0000-4000-8000-00000000d001", name: "Test Mac")
        },
        rootAccess: RootAccess = .explicitOnly,
        trigger: String = "CLI"
    ) {
        self.makeStore = makeStore
        self.makeVault = makeVault
        self.isDirectory = isDirectory
        self.stateDirectory = stateDirectory
        self.makeKeyer = makeKeyer
        self.ids = ids
        self.clock = clock
        self.timeZone = timeZone
        self.fallbackRegion = fallbackRegion
        self.output = output
        self.makeStateStore = makeStateStore
        self.device = device
        self.rootAccess = rootAccess
        self.trigger = trigger
    }

    /// Opens the SQLite device state in a vault's state folder (importing an
    /// M1 `records.json` there once).
    @Sendable
    public static func openStateStore(_ directory: URL) throws -> any SyncStateStore {
        try GRDBSyncStateStore.open(directory: directory)
    }

    /// The production environment.
    public static func live() -> CLIEnvironment {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let state = support.appending(path: "Contacts2MdSync")
        return CLIEnvironment(
            makeStore: {
                guard CNContactStoreAdapter.isAuthorized else { throw ContactStoreError.accessDenied }
                return CNContactStoreAdapter()
            },
            makeVault: { LocalVaultFS(root: $0) },
            isDirectory: { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
                    && isDirectory.boolValue
            },
            stateDirectory: state,
            makeKeyer: { PhoneNumberKitKeyer(defaultRegion: $0) },
            ids: RandomIDGenerator(),
            clock: SystemClock(),
            timeZone: .current,
            fallbackRegion: Locale.current.region?.identifier ?? "US",
            output: .standard,
            makeStateStore: openStateStore,
            device: { try DeviceIdentityFile(directory: state).loadOrCreate() },
            rootAccess: .bookmark(RootBookmark(directory: state)),
            trigger: "CLI"
        )
    }
}

/// Where CLI text goes: warnings and results to stdout, errors to stderr
/// (architecture §15). `capturing()` collects both for tests.
public final class CLIOutput: Sendable {
    private let writeOut: @Sendable (String) -> Void
    private let writeErr: @Sendable (String) -> Void
    private let captures: Bool
    private let buffer = Mutex<(out: String, err: String)>(("", ""))

    private init(captures: Bool, out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.captures = captures
        self.writeOut = out
        self.writeErr = err
    }

    /// The process's stdout / stderr.
    public static var standard: CLIOutput {
        CLIOutput(
            captures: false,
            out: { FileHandle.standardOutput.write(Data($0.utf8)) },
            err: { FileHandle.standardError.write(Data($0.utf8)) })
    }

    /// An output that records everything (read back with `stdout`/`stderr`).
    public static func capturing() -> CLIOutput {
        CLIOutput(captures: true, out: { _ in }, err: { _ in })
    }

    /// Writes one line to stdout.
    public func line(_ text: String) {
        writeOut(text + "\n")
        if captures { buffer.withLock { $0.out += text + "\n" } }
    }

    /// Writes one line to stderr.
    public func error(_ text: String) {
        writeErr(text + "\n")
        if captures { buffer.withLock { $0.err += text + "\n" } }
    }

    /// Everything written to stdout (capturing outputs only).
    public var stdout: String { buffer.withLock { $0.out } }
    /// Everything written to stderr (capturing outputs only).
    public var stderr: String { buffer.withLock { $0.err } }
}
