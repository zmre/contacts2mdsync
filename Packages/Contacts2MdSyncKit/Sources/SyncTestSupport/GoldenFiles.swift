public import Foundation

/// Golden-file comparison.
///
/// Goldens live in the source tree (`Tests/<Target>/Fixtures/…`), located via
/// `#filePath`. Run with `UPDATE_GOLDENS=1` (`just update-goldens`) to rewrite
/// them from the current output; review the diff before committing.
public enum GoldenFiles {
    /// `true` when goldens should be rewritten instead of compared.
    public static var updating: Bool { ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" }

    /// `Fixtures/<name>` next to the calling test file.
    public static func directory(_ name: String, testFile: String = #filePath) -> URL {
        URL(filePath: testFile).deletingLastPathComponent().appending(path: "Fixtures").appending(path: name)
    }

    /// Compares `files` (root-relative path → bytes) with the tree at
    /// `directory`. Returns human-readable differences (empty = match). In
    /// update mode, replaces the tree and returns no differences.
    public static func compare(_ files: [String: Data], with directory: URL) throws -> [String] {
        if updating {
            try? FileManager.default.removeItem(at: directory)
            for (path, data) in files {
                let url = directory.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            return []
        }
        let existing = try tree(at: directory)
        var differences: [String] = []
        for path in Set(files.keys).union(existing.keys).sorted() {
            switch (files[path], existing[path]) {
            case (nil, _?): differences.append("missing from output: \(path)")
            case (_?, nil): differences.append("not in goldens: \(path)")
            case (let produced?, let golden?) where produced != golden:
                let goldenText = String(data: golden, encoding: .utf8) ?? "<binary>"
                let producedText = String(data: produced, encoding: .utf8) ?? "<binary>"
                differences.append("differs: \(path)\n--- golden\n\(goldenText)\n+++ output\n\(producedText)")
            default: break
            }
        }
        return differences
    }

    /// All files under `directory` (including dot-folders), path → bytes.
    public static func tree(at directory: URL) throws -> [String: Data] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else {
            return [:]
        }
        let base = directory.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var files: [String: Data] = [:]
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            files[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return files
    }
}
