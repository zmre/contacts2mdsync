public import Foundation
internal import SyncEngine

// MARK: - Activity details

/// Per-side counts of a sync started from the app before M5. `SessionRecord`
/// stored Apple and markdown changes combined then, so the app kept this
/// split (and the held count) in the device state's metadata, keyed by
/// start time. M5 sessions carry `SessionRecord.sides` instead; these are
/// still read for older sessions and never written any more.
public struct UISessionDetail: Codable, Hashable, Sendable {
    public var startedAt: Date
    /// The session's trigger (`GUI`, …), so a detail never attaches to a
    /// CLI run that started in the same instant.
    public var trigger: String
    public var apple: UIChangeCounts
    public var markdown: UIChangeCounts
    public var held: Int
    /// `apple writes disabled`, `blast radius`, or `nil`.
    public var holdReason: String?

    /// Creates a detail.
    public init(
        startedAt: Date, trigger: String, apple: UIChangeCounts, markdown: UIChangeCounts, held: Int,
        holdReason: String?
    ) {
        self.startedAt = startedAt
        self.trigger = trigger
        self.apple = apple
        self.markdown = markdown
        self.held = held
        self.holdReason = holdReason
    }

    /// Metadata key in the device state.
    static let metadataKey = "ui_sync_sessions"

    /// Whether this detail belongs to `session`.
    func matches(_ session: SessionRecord) -> Bool {
        session.trigger == trigger && abs(session.startedAt.timeIntervalSince(startedAt)) < 0.001
    }

    static func load(_ state: any SyncStateStore) -> [UISessionDetail] {
        guard let data = try? state.metadata(metadataKey) else { return [] }
        return (try? decoder.decode([UISessionDetail].self, from: data)) ?? []
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
