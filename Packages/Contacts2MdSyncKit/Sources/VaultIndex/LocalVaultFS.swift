public import Foundation

/// `VaultFS` over a real folder.
///
/// Writes are atomic (temp file in the same folder, then `replaceItemAt`)
/// and coordinated with `NSFileCoordinator`, so iCloud Drive and other file
/// presenters see one complete change. The compare-and-swap check re-hashes
/// the current file inside the coordinated block.
public struct LocalVaultFS: VaultFS {
    /// The vault root.
    public let root: URL

    /// Creates a file system rooted at `root`.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    private func url(_ path: String) throws -> URL {
        try VaultPath.validate(path)
        return root.appending(path: path, directoryHint: .notDirectory)
    }

    public func enumerate() throws -> [FileEntry] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemHasUnresolvedConflictsKey,
        ]
        // Hidden entries are filtered by hand: legacy iCloud placeholders are
        // hidden files (`.Jane Doe.md.icloud`) that stand for `Jane Doe.md`.
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
        else { return [] }
        let rootPath = root.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var entries: [FileEntry] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if name.hasPrefix(".") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                guard let placeholder = Self.placeholderTarget(name), values.isRegularFile == true else { continue }
                // Standardize the (existing) folder: `standardizedFileURL` only
                // strips `/private` from paths that exist.
                let folder = fileURL.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
                let full = (folder.hasSuffix("/") ? folder : folder + "/") + placeholder
                guard full.hasPrefix(prefix) else { continue }
                entries.append(
                    FileEntry(
                        path: String(full.dropFirst(prefix.count)),
                        modificationDate: values.contentModificationDate ?? .distantPast, size: 0, isDataless: true))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let full = fileURL.standardizedFileURL.path(percentEncoded: false)
            guard full.hasPrefix(prefix) else { continue }
            let status = values.ubiquitousItemDownloadingStatus
            let notDownloaded = status != nil && status != .current && status != .downloaded
            entries.append(
                FileEntry(
                    path: String(full.dropFirst(prefix.count)),
                    modificationDate: values.contentModificationDate ?? .distantPast,
                    size: values.fileSize ?? 0,
                    isDataless: notDownloaded || Self.isDataless(full),
                    hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts ?? false
                ))
        }
        return entries
    }

    /// `Jane Doe.md` for a legacy iCloud placeholder `.Jane Doe.md.icloud`.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".x.icloud".count - 1 else { return nil }
        let target = String(name.dropFirst().dropLast(".icloud".count))
        return target.isEmpty || target.hasPrefix(".") ? nil : target
    }

    /// The `SF_DATALESS` file flag: an APFS file whose bytes live in the cloud.
    static func isDataless(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    public func list(_ directory: String) throws -> [String] {
        let url = directory.isEmpty ? root : try self.url(directory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
    }

    public func requestDownload(_ path: String) {
        guard let fileURL = try? url(path) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
    }

    public func unresolvedConflictVersions(_ path: String) throws -> [FileConflictVersion] {
        let fileURL = try url(path)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        var result: Result<[FileConflictVersion], any Error> = .success([])
        try coordinate(reading: fileURL) { coordinated in
            result = Result {
                try (NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated) ?? []).map { version in
                    FileConflictVersion(
                        data: try Data(contentsOf: version.url), modificationDate: version.modificationDate,
                        deviceName: version.localizedNameOfSavingComputer)
                }
            }
        }
        return try result.get()
    }

    public func resolveConflictVersions(_ path: String, keeping chosen: FileConflictVersion?) throws {
        let fileURL = try url(path)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw VaultFSError.notFound(path: path)
        }
        var result: Result<Void, any Error> = .success(())
        try coordinate(writing: fileURL) { coordinated in
            result = Result {
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated) ?? []
                if let chosen {
                    let match = versions.first { version in
                        (try? Data(contentsOf: version.url)).map(FileStamp.hash) == chosen.sha256
                    }
                    guard let match else { throw VaultFSError.notFound(path: path) }
                    _ = try match.replaceItem(at: coordinated, options: [])
                }
                for version in versions { version.isResolved = true }
                try NSFileVersion.removeOtherVersionsOfItem(at: coordinated)
            }
        }
        try result.get()
    }

    public func read(_ path: String) throws -> (Data, FileStamp) {
        let fileURL = try url(path)
        var result: Result<(Data, FileStamp), any Error> = .failure(VaultFSError.notFound(path: path))
        try coordinate(reading: fileURL) { coordinated in
            result = Result { try Self.readNow(coordinated, path: path) }
        }
        return try result.get()
    }

    public func write(_ data: Data, to path: String, expecting: WriteExpectation) throws -> FileStamp {
        let fileURL = try url(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result<FileStamp, any Error> = .failure(VaultFSError.notFound(path: path))
        try coordinate(writing: fileURL) { coordinated in
            result = Result { try Self.writeNow(data, to: coordinated, path: path, expecting: expecting) }
        }
        return try result.get()
    }

    public func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: try url(path), resultingItemURL: nil)
    }

    public func exists(_ path: String) -> Bool {
        guard let fileURL = try? url(path) else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }

    // MARK: - Internals

    private static func readNow(_ url: URL, path: String) throws -> (Data, FileStamp) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw VaultFSError.notFound(path: path)
        }
        let data = try Data(contentsOf: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return (
            data,
            FileStamp(
                modificationDate: values.contentModificationDate ?? .distantPast, size: data.count,
                sha256: FileStamp.hash(data))
        )
    }

    private static func writeNow(
        _ data: Data, to url: URL, path: String, expecting: WriteExpectation
    ) throws
        -> FileStamp
    {
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        switch expecting {
        case .absent where exists:
            throw VaultFSError.conflict(path: path)
        case .unchanged(let stamp):
            guard exists, FileStamp.hash(try Data(contentsOf: url)) == stamp.sha256 else {
                throw VaultFSError.conflict(path: path)
            }
        default:
            break
        }
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).c2md-\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .withoutOverwriting)
        do {
            if exists {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return try readNow(url, path: path).1
    }

    private func coordinate(reading url: URL, _ body: (URL) -> Void) throws {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError, byAccessor: body)
        if let coordinationError { throw coordinationError }
    }

    private func coordinate(writing url: URL, _ body: (URL) -> Void) throws {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: body)
        if let coordinationError { throw coordinationError }
    }
}
