internal import Foundation
public import SyncEngine
internal import VaultIndex

// MARK: - Links to renamed contacts (architecture §8)

/// Notes outside the contact notes that still link to a renamed contact's
/// old title (`[[Ann One]]` after Ann One became Ann Smith). They keep
/// resolving through the old title, which the contact note keeps as an
/// alias; Update Links rewrites them only when the user asks.
public struct UIRenamedLinks: Identifiable, Hashable, Sendable {
    public var id: String { rename.oldTitle }
    public var rename: TitleRename
    /// Non-contact notes (root-relative) with at least one such link.
    public var paths: [String]

    /// `3 notes outside contacts link to [[Ann One]]`.
    public var summary: String {
        "\(paths.count) \(paths.count == 1 ? "note" : "notes") outside contacts "
            + "\(paths.count == 1 ? "links" : "link") to [[\(rename.oldTitle)]]"
    }
}

/// Finds and rewrites wikilinks to an old title: `[[Old]]`, `[[Old|text]]`,
/// `[[Old#heading]]` and embeds, matched case-insensitively like mbr.
enum WikilinkRewriter {
    static func pattern(_ title: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: title)
        return try? NSRegularExpression(pattern: "\\[\\[\\s*\(escaped)\\s*(?=[|#\\]])", options: [.caseInsensitive])
    }

    static func links(in text: String, to title: String) -> Bool {
        guard let regex = pattern(title) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func rewrite(_ text: String, from old: String, to new: String) -> String {
        guard let regex = pattern(old) else { return text }
        let template = NSRegularExpression.escapedTemplate(for: "[[\(new)")
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

extension UIVaultReader {
    /// Renamed contacts whose old title is still linked from notes outside
    /// the contact notes (under the root only). Reads those notes; writes
    /// nothing. Renames without such links are left out.
    public func renamedLinks() throws -> [UIRenamedLinks] {
        guard let (state, config) = try openState() else { return [] }
        let renames = try state.recentRenames()
        guard !renames.isEmpty else { return [] }
        let fs = environment.makeVault(root)
        let index = try VaultIndex.scan(
            fs, excludedFolders: [config.imagesFolder], excludeGlobs: config.excludePaths,
            cache: try state.loadFileCache())
        let notes = index.entries.filter { !$0.isContactNote && !$0.isDataless && Self.isMarkdown($0.path) }
        var texts: [String: String] = [:]
        for note in notes {
            guard let (data, _) = try? fs.read(note.path), let text = String(bytes: data, encoding: .utf8) else {
                continue
            }
            texts[note.path] = text
        }
        return renames.reversed().compactMap { rename in
            let paths = texts.filter { WikilinkRewriter.links(in: $0.value, to: rename.oldTitle) }.keys.sorted()
            return paths.isEmpty ? nil : UIRenamedLinks(rename: rename, paths: paths)
        }
    }

    /// Update Links (an explicit user action): rewrites `[[Old…]]` to
    /// `[[New…]]` in those notes. Each note is backed up first and written
    /// compare-and-swap, so a note edited meanwhile is left alone. Returns
    /// the notes rewritten.
    @discardableResult
    public func updateLinks(_ links: UIRenamedLinks) throws -> [String] {
        guard let (_, config) = try openState() else { return [] }
        let fs = environment.makeVault(root)
        let directory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        _ = try NoteBackup(directory: directory.appending(path: "backups"), clock: environment.clock)
            .backup(links.paths.filter(fs.exists), from: fs)
        var written: [String] = []
        for path in links.paths {
            guard let (data, stamp) = try? fs.read(path), let text = String(bytes: data, encoding: .utf8) else {
                continue
            }
            let updated = WikilinkRewriter.rewrite(text, from: links.rename.oldTitle, to: links.rename.newTitle)
            guard updated != text else { continue }
            _ = try fs.write(Data(updated.utf8), to: path, expecting: .unchanged(stamp))
            written.append(path)
        }
        return written
    }

    /// Dismiss: forgets the rename (its links are no longer reported).
    public func dismissRename(_ rename: TitleRename) throws {
        guard let (state, _) = try openState() else { return }
        try state.saveRecentRenames(try state.recentRenames().filter { $0 != rename })
    }

    private func openState() throws -> (any SyncStateStore, VaultConfig)? {
        let fs = environment.makeVault(root)
        guard let config = try VaultConfig.load(from: fs)?.config else { return nil }
        let directory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return nil }
        return (try environment.makeStateStore(directory), config)
    }

    private static func isMarkdown(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }
}
