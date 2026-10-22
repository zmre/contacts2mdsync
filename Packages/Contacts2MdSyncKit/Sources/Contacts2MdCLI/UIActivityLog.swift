public import Foundation
public import SyncEngine

// MARK: - Activity: per-change list and Export Log (docs/ui.md §8)

/// One change of a run, as the Activity inspector lists it
/// ("Updated Jane Doe.md — job_title, phones") with Reveal / Open.
public struct UIActivityChange: Identifiable, Hashable, Sendable {
    public var id: Int
    /// `Contacts` or `Markdown`.
    public var side: String
    /// `Updated Jane Doe.md — job_title, phones`, `Created Bob Two in Contacts`.
    public var text: String
    /// The note (markdown changes) for Reveal in Finder.
    public var path: String?
    /// The record's cards as bound now, for Open in Contacts.
    public var cardIDs: [String]

    /// The rows for a run's change log; card ids come from this Mac's records.
    public static func rows(_ changes: [SessionChange], records: RecordMap) -> [UIActivityChange] {
        changes.enumerated().map { offset, change in
            let cards = change.recordID.flatMap { records[$0]?.cardIDs } ?? []
            return UIActivityChange(
                id: offset, side: change.side == .apple ? "Contacts" : "Markdown", text: text(change),
                path: change.side == .markdown ? change.path : nil, cardIDs: cards)
        }
    }

    static func text(_ change: SessionChange) -> String {
        let verb = change.verb.prefix(1).uppercased() + change.verb.dropFirst()
        let subject: String
        switch change.side {
        case .markdown:
            subject = change.path.map { String($0.split(separator: "/").last ?? Substring($0)) } ?? change.title
        case .apple: subject = "\(change.title) in Contacts"
        }
        let fields = change.fields.filter { $0 != "c2mdsync" }
        return fields.isEmpty ? "\(verb) \(subject)" : "\(verb) \(subject) — \(fields.joined(separator: ", "))"
    }
}

/// File ▸ Export Log… formats.
public enum UIActivityLogFormat: String, Hashable, Sendable, CaseIterable {
    case text
    case json

    /// The file extension the save panel suggests.
    public var fileExtension: String { self == .json ? "json" : "txt" }
}

/// Renders this Mac's runs with their change logs for File ▸ Export Log….
public enum UIActivityLog {
    /// One run and what it changed.
    public struct Entry: Hashable, Sendable {
        public var session: SessionRecord
        public var changes: [SessionChange]

        /// Creates an entry.
        public init(session: SessionRecord, changes: [SessionChange]) {
            self.session = session
            self.changes = changes
        }
    }

    /// The log as text (one line per run, indented changes) or JSON
    /// (`exported_at`, `device`, `sessions` with `changes`). Runs newest first.
    public static func render(
        _ entries: [Entry], device: DeviceIdentity, exportedAt: Date, format: UIActivityLogFormat,
        timeZone: TimeZone = .current
    ) throws -> String {
        switch format {
        case .text: text(entries, device: device, exportedAt: exportedAt, timeZone: timeZone)
        case .json: try json(entries, device: device, exportedAt: exportedAt)
        }
    }

    private static func text(
        _ entries: [Entry], device: DeviceIdentity, exportedAt: Date, timeZone: TimeZone
    )
        -> String
    {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        var lines = [
            "Contacts2MdSync activity log  exported \(formatter.string(from: exportedAt))  device=\(device.name)"
        ]
        for entry in entries {
            let session = entry.session
            let started = formatter.string(from: session.startedAt)
            var line = "\(started)  \(session.command)  \(UIActivityRow.trigger(session.trigger))"
            if let sides = session.sides {
                line +=
                    "  apple c/u/d \(sides.appleCreated)/\(sides.appleUpdated)/\(sides.appleDeleted)"
                    + "  md c/u/d \(sides.markdownCreated)/\(sides.markdownUpdated)/\(sides.markdownDeleted)"
                    + "  held \(sides.held)"
            } else {
                line += "  created \(session.created)  updated \(session.updated)"
            }
            line +=
                "  review \(session.pendingReview)  failures \(session.failures)"
                + String(format: "  %.1fs", session.finishedAt.timeIntervalSince(session.startedAt))
            lines.append(line)
            lines += entry.changes.map { "    " + $0.line }
            if let count = session.changeCount, count > entry.changes.count {
                lines.append("    … \(count - entry.changes.count) more changes not kept")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Run: Encodable {
        var session: SessionRecord
        var changes: [SessionChange]
    }

    private struct Document: Encodable {
        var exportedAt: Date
        var device: String
        var deviceID: String
        var sessions: [Run]
    }

    private static func json(_ entries: [Entry], device: DeviceIdentity, exportedAt: Date) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let document = Document(
            exportedAt: exportedAt, device: device.name, deviceID: device.id,
            sessions: entries.map { Run(session: $0.session, changes: $0.changes) })
        return (String(bytes: try encoder.encode(document), encoding: .utf8) ?? "") + "\n"
    }
}

extension UIVaultReader {
    /// The change log of `session` (empty when it kept none, or this Mac has
    /// no state for the vault). Reads only.
    public func sessionChanges(of session: SessionRecord) throws -> [SessionChange] {
        guard session.changeLogID != nil, let state = try existingState() else { return [] }
        return try state.sessionChanges(of: session)
    }

    /// File ▸ Export Log…: this Mac's last `limit` runs (previews included)
    /// with their change logs. Reads only.
    public func activityLog(format: UIActivityLogFormat, limit: Int = 500) throws -> String {
        let entries = try existingState().map { state in
            try state.recentSessions(limit: limit).map {
                UIActivityLog.Entry(session: $0, changes: try state.sessionChanges(of: $0))
            }
        }
        return try UIActivityLog.render(
            entries ?? [], device: try environment.device(), exportedAt: environment.clock.now, format: format,
            timeZone: environment.timeZone)
    }

    /// This Mac's state for the vault, when it exists (nothing is created).
    private func existingState() throws -> (any SyncStateStore)? {
        let fs = environment.makeVault(root)
        guard let config = try VaultConfig.load(from: fs)?.config else { return nil }
        let directory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return nil }
        return try environment.makeStateStore(directory)
    }
}
