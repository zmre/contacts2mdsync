public import Foundation

/// Live-sync preferences of **this Mac** (Settings ▸ General).
///
/// Stored in the device state folder (`<state>/triggers.json`, next to
/// `device.json` and the folder bookmark), not in the vault's
/// `.c2mdsync/config.yaml`: the vault config is shared by every device
/// through iCloud, but whether a Mac watches for changes and how often it
/// sweeps is a property of that Mac (a laptop on battery, a follower device,
/// a desktop that leads). Vault-independent: the settings survive choosing
/// another notes folder.
public struct TriggerSettings: Codable, Hashable, Sendable {
    /// Allowed sweep intervals.
    public static let sweepRange: ClosedRange<TimeInterval> = 3600...(6 * 3600)
    /// Default sweep interval (2 h, architecture §10).
    public static let defaultSweepInterval: TimeInterval = 2 * 3600

    /// Watch Contacts and the notes folder and sync on changes. Also gates
    /// launch and wake catch-up runs. Sync Now always works.
    public var liveSync: Bool
    /// Seconds between safety sweeps (clamped to 1–6 h); `nil`: off.
    public var sweepInterval: TimeInterval?

    /// Creates settings (`sweepInterval` is clamped to `sweepRange`).
    public init(liveSync: Bool = true, sweepInterval: TimeInterval? = TriggerSettings.defaultSweepInterval) {
        self.liveSync = liveSync
        self.sweepInterval = sweepInterval.map { min(max($0, Self.sweepRange.lowerBound), Self.sweepRange.upperBound) }
    }

    enum CodingKeys: String, CodingKey {
        case liveSync = "live_sync"
        case sweepInterval = "sweep_interval_seconds"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            liveSync: try container.decodeIfPresent(Bool.self, forKey: .liveSync) ?? true,
            sweepInterval: container.contains(.sweepInterval)
                ? try container.decodeIfPresent(TimeInterval.self, forKey: .sweepInterval) : Self.defaultSweepInterval)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(liveSync, forKey: .liveSync)
        try container.encode(sweepInterval, forKey: .sweepInterval)  // explicit null = off
    }
}

/// Reads and writes `TriggerSettings` as `<directory>/triggers.json`.
public struct TriggerSettingsStore: Sendable {
    public let directory: URL

    /// Creates a store in the device state folder (`CLIEnvironment.stateDirectory`).
    public init(directory: URL) { self.directory = directory }

    var url: URL { directory.appending(path: "triggers.json") }

    /// The saved settings, or the defaults when none (or unreadable).
    public func load() -> TriggerSettings {
        guard let data = try? Data(contentsOf: url) else { return TriggerSettings() }
        return (try? JSONDecoder().decode(TriggerSettings.self, from: data)) ?? TriggerSettings()
    }

    /// Saves settings atomically.
    public func save(_ settings: TriggerSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
