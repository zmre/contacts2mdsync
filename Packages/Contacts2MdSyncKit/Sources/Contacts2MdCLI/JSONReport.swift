internal import Foundation
internal import SyncEngine
internal import Synchronization

/// `--json`: everything a run would print, as one JSON document on stdout
/// (architecture §15). Errors still also go to stderr.
final class JSONReport: Sendable {
    private let document: Mutex<JSONDocument>

    init(command: String, startedAt: Date) {
        document = Mutex(JSONDocument(command: command, startedAt: startedAt))
    }

    func header(device: String, root: String) {
        document.withLock {
            $0.device = device
            $0.root = root
        }
    }

    func item(verb: String, side: String, text: String) {
        document.withLock { $0.items.append(JSONItem(verb: verb, side: side, text: text)) }
    }

    func warning(kind: String, text: String) {
        document.withLock { $0.warnings.append(JSONWarning(kind: kind, text: text)) }
    }

    func note(_ text: String) { document.withLock { $0.notes.append(text) } }
    func error(_ text: String) { document.withLock { $0.errors.append(text) } }
    func summary(_ text: String) { document.withLock { $0.summary = text } }
    func setting(_ key: String, _ value: String) { document.withLock { $0.settings[key] = value } }

    func reviews(_ items: [ReviewItem]) {
        document.withLock { document in
            document.reviews = items.map {
                JSONReview(id: $0.id, summary: $0.summary, choices: $0.choices, needsDecision: $0.needsDecision)
            }
            document.conflicts = items.compactMap { item in
                if case .conflict(let conflict) = item { return conflict }
                return nil
            }
        }
    }

    /// The document, pretty-printed with sorted keys.
    func render(exitCode: Int32) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var document = self.document.withLock { $0 }
        document.exitCode = exitCode
        guard let data = try? encoder.encode(document) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}

struct JSONItem: Codable, Hashable, Sendable {
    var verb: String
    var side: String
    var text: String
}

struct JSONWarning: Codable, Hashable, Sendable {
    var kind: String
    var text: String
}

struct JSONReview: Codable, Hashable, Sendable {
    var id: String
    var summary: String
    var choices: [String]
    var needsDecision: Bool

    enum CodingKeys: String, CodingKey {
        case id, summary, choices
        case needsDecision = "needs_decision"
    }
}

struct JSONDocument: Encodable {
    var command: String
    var startedAt: Date
    var device: String?
    var root: String?
    var exitCode: Int32 = 0
    var items: [JSONItem] = []
    var warnings: [JSONWarning] = []
    var notes: [String] = []
    var errors: [String] = []
    var summary: String?
    var reviews: [JSONReview] = []
    var conflicts: [SyncConflict] = []
    var settings: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case command, device, root, items, warnings, notes, errors, summary, reviews, conflicts, settings
        case startedAt = "started_at"
        case exitCode = "exit_code"
    }
}
