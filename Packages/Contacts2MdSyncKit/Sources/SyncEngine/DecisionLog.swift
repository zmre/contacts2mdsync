public import Foundation
public import VaultIndex

/// Reading and appending `decisions.jsonl` files in the vault.
public enum DecisionLog {
    /// Folder holding one subfolder per device.
    public static let devicesFolder = ".c2mdsync/devices"

    /// The log of `deviceID`.
    public static func path(deviceID: String) -> String { "\(devicesFolder)/\(deviceID)/decisions.jsonl" }

    /// Errors writing the log.
    public enum LogError: Error, Hashable, Sendable, CustomStringConvertible {
        case invalidDeviceID(String)

        public var description: String {
            switch self {
            case .invalidDeviceID(let id): "invalid device id for the decision log: \(id)"
            }
        }
    }

    /// The union of every device's decisions, oldest first, plus warnings:
    /// lines that could not be read (`path:line: message`) and items decided
    /// differently on two devices (`DecisionConflict.message`). Never throws
    /// for bad lines.
    public static func readAll(_ fs: any VaultFS) throws -> (decisions: [Decision], problems: [String]) {
        let log = try read(fs)
        return (log.decisions, log.problems + log.conflicts.map(\.message))
    }

    /// Reads every device's log (architecture §4, §11):
    ///
    /// - **Union**: every `devices/<id>/decisions.jsonl`, plus the lines of
    ///   its unresolved iCloud conflict versions (an append-only log loses
    ///   nothing by merging); duplicates (same id) are read once.
    /// - **Order**: by time, then device id, then the order lines were
    ///   appended (one writer per log), so every device sees the same order
    ///   and "latest wins" means the same thing.
    /// - **Partial lines**: an unterminated last line that does not parse is
    ///   a line iCloud has not finished delivering; it is skipped silently
    ///   (`partialLines`) and read on a later run.
    /// - **Conflicts**: one review item decided differently on two devices
    ///   within `conflictWindow` (before either could see the other's
    ///   decision): the latest wins (`DecisionSet`), and a warning says so.
    public static func read(
        _ fs: any VaultFS, conflictWindow: TimeInterval = DecisionLog.conflictWindow
    ) throws
        -> DecisionLogContents
    {
        var contents = DecisionLogContents()
        var seen = Set<UUID>()
        var order: [UUID: Int] = [:]
        for device in try fs.list(devicesFolder) where !device.hasPrefix(".") {
            let logPath = "\(devicesFolder)/\(device)/decisions.jsonl"
            guard fs.exists(logPath) else { continue }
            let (data, _) = try fs.read(logPath)
            let versions = (try? fs.unresolvedConflictVersions(logPath)) ?? []
            for (copy, bytes) in ([data] + versions.map(\.data)).enumerated() {
                let parsed = parse(bytes, path: logPath)
                contents.partialLines += parsed.partial
                if copy == 0 { contents.problems += parsed.problems }
                for decision in parsed.decisions where seen.insert(decision.id).inserted {
                    order[decision.id] = order.count
                    contents.decisions.append(decision)
                }
            }
        }
        // Ties (same second, same device) keep the order they were appended in.
        contents.decisions.sort { lhs, rhs in
            (lhs.createdAt, lhs.deviceID, order[lhs.id] ?? 0) < (rhs.createdAt, rhs.deviceID, order[rhs.id] ?? 0)
        }
        contents.conflicts = conflicts(in: contents.decisions, window: conflictWindow)
        return contents
    }

    /// Decisions on one item from two devices this close together are
    /// treated as made without seeing each other (iCloud delay): 1 hour.
    public static let conflictWindow: TimeInterval = 60 * 60

    /// The log order: time, then device id, then decision id.
    static func precedes(_ lhs: Decision, _ rhs: Decision) -> Bool {
        (lhs.createdAt, lhs.deviceID, lhs.id.uuidString) < (rhs.createdAt, rhs.deviceID, rhs.id.uuidString)
    }

    /// Items whose latest decisions from different devices disagree and
    /// were made within `window` of each other.
    static func conflicts(in decisions: [Decision], window: TimeInterval) -> [DecisionConflict] {
        var byItem: [String: [Decision]] = [:]
        for decision in decisions where decision.kind != nil {
            guard let item = decision.itemID else { continue }
            byItem[item, default: []].append(decision)
        }
        var found: [DecisionConflict] = []
        for (item, list) in byItem.sorted(by: { $0.key < $1.key }) {
            guard let winner = list.last else { continue }
            // Each device's latest word on the item.
            var latest: [String: Decision] = [:]
            for decision in list { latest[decision.deviceID] = decision }
            let rivals = latest.values.filter { other in
                other.deviceID != winner.deviceID && other.outcome != winner.outcome
                    && winner.createdAt.timeIntervalSince(other.createdAt) <= window
            }
            guard !rivals.isEmpty else { continue }
            found.append(DecisionConflict(itemID: item, winner: winner, overridden: rivals.sorted(by: precedes)))
        }
        return found
    }

    /// The lines of one log copy.
    private struct ParsedLog {
        var decisions: [Decision] = []
        /// Unreadable complete lines.
        var problems: [String] = []
        /// An unterminated unreadable tail (0 or 1).
        var partial = 0
    }

    private static func parse(_ data: Data, path: String) -> ParsedLog {
        var parsed = ParsedLog()
        let lines = text(data).split(separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let decision = try? decoder.decode(Decision.self, from: Data(trimmed.utf8)) {
                parsed.decisions.append(decision)
            } else if number == lines.count - 1 {
                parsed.partial += 1  // no newline yet: still arriving through iCloud
            } else {
                parsed.problems.append("\(path):\(number + 1): unreadable decision")
            }
        }
        return parsed
    }

    /// Lossy UTF-8: a line cut mid-character by an incomplete iCloud
    /// download must not make the whole log unreadable.
    private static func text(_ data: some Collection<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }

    /// Appends `decisions` to this device's log (compare-and-swap on the
    /// current bytes, so a concurrent writer on this device is not lost).
    /// Conflict versions of the log are merged in first, and an unreadable
    /// unterminated tail (a write cut short) is dropped instead of being
    /// buried under new lines.
    public static func append(_ decisions: [Decision], deviceID: String, fs: any VaultFS) throws {
        guard !decisions.isEmpty else { return }
        guard !deviceID.isEmpty, !deviceID.contains("/"), !deviceID.hasPrefix(".") else {
            throw LogError.invalidDeviceID(deviceID)
        }
        try mergeConflictVersions(deviceID: deviceID, fs: fs)
        let logPath = path(deviceID: deviceID)
        var expectation = WriteExpectation.absent
        var data = Data()
        if fs.exists(logPath) {
            let (current, stamp) = try fs.read(logPath)
            data = Self.droppingPartialTail(current)
            expectation = .unchanged(stamp)
            if let last = data.last, last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
        }
        for decision in decisions {
            data.append(try encoder.encode(decision))
            data.append(UInt8(ascii: "\n"))
        }
        _ = try fs.write(data, to: logPath, expecting: expectation)
    }

    /// Merges the iCloud conflict versions of this device's own log into it
    /// (union of lines, by decision id, in log order) and resolves them.
    /// Only the owning device rewrites its log, so it stays single-writer.
    public static func mergeConflictVersions(deviceID: String, fs: any VaultFS) throws {
        let logPath = path(deviceID: deviceID)
        guard fs.exists(logPath), let versions = try? fs.unresolvedConflictVersions(logPath), !versions.isEmpty
        else { return }
        let (current, stamp) = try fs.read(logPath)
        var seen = Set<UUID>()
        var merged: [Decision] = []
        for bytes in [current] + versions.map(\.data) {
            for decision in parse(bytes, path: logPath).decisions where seen.insert(decision.id).inserted {
                merged.append(decision)
            }
        }
        let currentIDs = Set(parse(current, path: logPath).decisions.map(\.id))
        if merged.contains(where: { !currentIDs.contains($0.id) }) {
            var data = droppingPartialTail(current)
            if let last = data.last, last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
            for decision in merged.sorted(by: precedes) where !currentIDs.contains(decision.id) {
                data.append(try encoder.encode(decision))
                data.append(UInt8(ascii: "\n"))
            }
            _ = try fs.write(data, to: logPath, expecting: .unchanged(stamp))
        }
        try fs.resolveConflictVersions(logPath, keeping: nil)
    }

    /// `data` without an unterminated last line that does not parse.
    private static func droppingPartialTail(_ data: Data) -> Data {
        guard let last = data.last, last != UInt8(ascii: "\n") else { return data }
        let newline = data.lastIndex(of: UInt8(ascii: "\n"))
        let tailStart = newline.map { data.index(after: $0) } ?? data.startIndex
        let tail = data[tailStart...]
        let trimmed = text(tail).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, (try? decoder.decode(Decision.self, from: Data(trimmed.utf8))) == nil else {
            return data
        }
        return Data(data[..<tailStart])
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// What `DecisionLog.read` found.
public struct DecisionLogContents: Sendable {
    /// Every device's decisions, deduplicated, in log order.
    public var decisions: [Decision] = []
    /// Unreadable complete lines (`path:line: unreadable decision`).
    public var problems: [String] = []
    /// Items decided differently on two devices (the latest wins).
    public var conflicts: [DecisionConflict] = []
    /// Unterminated, unreadable last lines (still arriving through iCloud).
    public var partialLines = 0

    /// Creates empty contents.
    public init() {}
}

/// One review item decided differently on two devices, close together.
public struct DecisionConflict: Hashable, Sendable {
    public var itemID: String
    /// The decision in effect (the latest).
    public var winner: Decision
    /// The other devices' latest decisions that lost.
    public var overridden: [Decision]

    /// `item … decided differently on Mac A (keep) and Mac B (trash); the latest (Mac B: trash) wins`.
    public var message: String {
        let others = overridden.map { "\(Self.name($0)) (\($0.outcome))" }.joined(separator: ", ")
        return "item \(itemID) decided differently on \(others) and \(Self.name(winner)) (\(winner.outcome)); "
            + "the latest (\(Self.name(winner)): \(winner.outcome)) wins"
    }

    private static func name(_ decision: Decision) -> String {
        decision.deviceName.isEmpty ? decision.deviceID : decision.deviceName
    }
}

extension Decision {
    /// What was decided, for comparing two decisions on one item: the
    /// choice, else the kind (and path for adoptions).
    var outcome: String {
        if let choice { return choice }
        return kindName + (path.map { ":\($0)" } ?? "")
    }
}
