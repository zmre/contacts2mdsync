public import Foundation

/// What the tracker needs to know about the vault side of a run.
public struct AppleReadContext: Sendable {
    public var records: RecordMap
    /// Records whose note changed since the last run (their contacts are re-read).
    public var vaultTouchedRecords: Set<UUID>
    /// `AppleChangeTracker.settingsKey(configText:decisions:)`.
    public var settingsKey: String
    public var vanished: [UUID: Date]
    public var now: Date
    public var deleteConfirmInterval: TimeInterval
    /// Whether this run reads notes; a cached snapshot made the other way
    /// cannot be patched (`nil`: either is fine).
    public var notesExpected: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    /// Records whose every card is in an unavailable account: having no
    /// card in the mirror is expected, not an inconsistency.
    public var exemptRecords: Set<UUID> = []

    /// Creates a context.
    public init(
        records: RecordMap, vaultTouchedRecords: Set<UUID>, settingsKey: String, vanished: [UUID: Date], now: Date,
        deleteConfirmInterval: TimeInterval = SyncOptions().deleteConfirmInterval,
        notesExpected: Bool? = nil  // swiftlint:disable:this discouraged_optional_boolean
    ) {
        self.notesExpected = notesExpected
        self.records = records
        self.vaultTouchedRecords = vaultTouchedRecords
        self.settingsKey = settingsKey
        self.vanished = vanished
        self.now = now
        self.deleteConfirmInterval = deleteConfirmInterval
    }
}
