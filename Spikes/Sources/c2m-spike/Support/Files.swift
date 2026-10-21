import CryptoKit
import Foundation

enum Paths {
    /// Spikes/results, derived from this source file's location at build time.
    /// Override with C2M_SPIKE_RESULTS (e.g. when running a copied binary).
    static var results: URL {
        if let env = ProcessInfo.processInfo.environment["C2M_SPIKE_RESULTS"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        // .../Spikes/Sources/c2m-spike/Support/Files.swift -> .../Spikes/results
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // c2m-spike
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // Spikes
            .appendingPathComponent("results", isDirectory: true)
    }

    static func result(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        return results.appendingPathComponent(name)
    }
}

enum Stamp {
    static func iso(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Filesystem-friendly local timestamp, e.g. 2026-10-20T1530.
    static func file(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmm"
        return formatter.string(from: date)
    }

    static func short() -> String {
        String(UUID().uuidString.prefix(4))
    }
}

func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum JSONFile {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

/// Local record of cards this machine's harness created. Convenience only:
/// it is never used to authorise a write (SafeWriter re-checks markers).
struct LedgerEntry: Codable {
    var spike: String
    var kind: String
    var identifier: String
    var marker: String
    var containerID: String
    var createdAt: String
}

enum Ledger {
    static var url: URL { get throws { try Paths.result("ledger.json") } }

    static func load() -> [LedgerEntry] {
        guard let url = try? url, let entries = try? JSONFile.read([LedgerEntry].self, from: url) else { return [] }
        return entries
    }

    static func append(_ entry: LedgerEntry) throws {
        try JSONFile.write(load() + [entry], to: url)
    }

    static func remove(identifiers: Set<String>) throws {
        try JSONFile.write(load().filter { !identifiers.contains($0.identifier) }, to: url)
    }
}

/// Minimal markdown table rendering with pipe escaping.
struct MarkdownTable {
    var headers: [String]
    var rows: [[String]] = []

    func render() -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "⏎")
        }
        var lines = ["| " + headers.map(cell).joined(separator: " | ") + " |"]
        lines.append("|" + headers.map { _ in "---" }.joined(separator: "|") + "|")
        for row in rows { lines.append("| " + row.map(cell).joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n")
    }
}
