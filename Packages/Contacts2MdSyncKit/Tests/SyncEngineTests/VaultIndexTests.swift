import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("Vault index: incremental scan, dataless files, lookups")
struct VaultIndexTests {
    static let person = "---\ntype: person\ntitle: Ann One\naliases:\n  - Annie\n---\n"
    static let linked = "---\ntype: person\ntitle: Bo Two\nc2mdsync:\n  id: 6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13\n---\n"
    static let plain = "---\ntitle: Meeting notes\naliases: [Standup]\n---\nbody\n"
    static let broken = "---\ntitle: [unclosed\n---\n"
    static let brokenContact = "---\ntype: person\ntitle: [unclosed\n---\n"

    private func vault() -> InMemoryVault {
        InMemoryVault(files: [
            "People/Ann.md": Self.person, "People/Bo.md": Self.linked, "Journal/2026-10-01.md": Self.plain,
            "Journal/broken.md": Self.broken, "People/broken contact.md": Self.brokenContact,
            "Templates/Person.md": Self.person, "_images/readme.md": Self.plain, "notes.txt": "x",
        ])
    }

    @Test("a second scan re-reads only contact notes and changed files")
    func incremental() throws {
        let vault = vault()
        let first = try VaultIndex.scan(vault, excludedFolders: ["_images"])
        #expect(first.filesRead == 6)
        #expect(Set(vault.reads) == Set(first.entries.map(\.path)))
        vault.resetReads()
        let second = try VaultIndex.scan(vault, excludedFolders: ["_images"], cache: first.fileCache)
        #expect(Set(vault.reads) == ["People/Ann.md", "People/Bo.md", "Templates/Person.md"])
        #expect(second.filesFromCache == 3)
        // Cached entries keep what lookups need.
        #expect(second.resolve("Standup").map(\.path) == ["Journal/2026-10-01.md"])
        #expect(second.problems.map(\.path).sorted() == ["Journal/broken.md", "People/broken contact.md"])
        #expect(second.problems.first { $0.path == "People/broken contact.md" }?.problemIsContactRelated == true)
        #expect(second.problems.first { $0.path == "Journal/broken.md" }?.problemIsContactRelated == false)
        // A changed non-contact file is re-read.
        vault.resetReads()
        vault.seed("Journal/2026-10-01.md", Data("---\ntitle: Renamed\n---\n".utf8))
        let third = try VaultIndex.scan(vault, excludedFolders: ["_images"], cache: second.fileCache)
        #expect(vault.reads.contains("Journal/2026-10-01.md"))
        #expect(third.resolve("Renamed").count == 1)
        #expect(third.resolve("Standup").isEmpty)
    }

    @Test("scope exclude_paths globs are never scanned")
    func excludeGlobs() throws {
        let index = try VaultIndex.scan(vault(), excludedFolders: ["_images"], excludeGlobs: ["Templates/**"])
        #expect(!index.entries.contains { $0.path.hasPrefix("Templates/") })
        #expect(index.entries.contains { $0.path == "People/Ann.md" })
        #expect(PathGlob.matches("Templates/**", "Templates/a/b.md"))
        #expect(PathGlob.matches("**/Archive/*.md", "x/y/Archive/z.md"))
        #expect(PathGlob.matches("**/Archive/*.md", "Archive/z.md"))
        #expect(!PathGlob.matches("Archive/*.md", "Archive/deep/z.md"))
        #expect(PathGlob.matches("*.md", "a.md") && !PathGlob.matches("*.md", "a/b.md"))
        #expect(PathGlob.matches("Drafts/?.md", "Drafts/x.md"))
    }

    @Test("a dataless note counts as present: its cached id is kept, it is never read")
    func datalessKnown() throws {
        let vault = vault()
        let first = try VaultIndex.scan(vault, excludedFolders: ["_images"])
        vault.setDataless("People/Bo.md")
        vault.resetReads()
        let second = try VaultIndex.scan(vault, excludedFolders: ["_images"], cache: first.fileCache)
        #expect(!vault.reads.contains("People/Bo.md"))
        let id = try #require(UUID(uuidString: "6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13"))
        let entry = try #require(second.entries(withID: id).first)
        #expect(entry.isDataless && entry.isContactNote && entry.contact == nil)
        #expect(second.undownloaded.isEmpty)
        #expect(second.fileCache["People/Bo.md"] != nil)  // cache kept for the next scan
        #expect(vault.downloadRequests == ["People/Bo.md"])
    }

    @Test("an unknown dataless note is listed and asked to download")
    func datalessUnknown() throws {
        let vault = vault()
        vault.setDataless("People/Ann.md")
        let index = try VaultIndex.scan(vault, excludedFolders: ["_images"])
        #expect(index.undownloaded.map(\.path) == ["People/Ann.md"])
        #expect(vault.downloadRequests == ["People/Ann.md"])
        #expect(index.isStemTaken("ann"))
    }

    @Test("mbr link resolution: title, then alias, then stem; ambiguity and duplicate titles")
    func resolution() throws {
        let vault = InMemoryVault(files: [
            "a/Robert.md": "---\ntype: person\ntitle: Bob Smith\n---\n",
            "b/Bob Smith.md": "---\ntype: person\ntitle: Robert Smith\naliases:\n  - nickname: Bob Smith\n---\n",
            "c/Other.md": "---\ntype: person\ntitle: Bob Smith\n---\n",
            "d/Solo.md": "# no frontmatter\n",
        ])
        let index = try VaultIndex.scan(vault)
        #expect(index.resolve("bob smith").map(\.path) == ["a/Robert.md", "c/Other.md"])  // titles win
        #expect(index.resolve("Robert Smith").map(\.path) == ["b/Bob Smith.md"])
        #expect(index.resolve("solo").map(\.path) == ["d/Solo.md"])  // stem fallback
        #expect(index.resolve("nobody").isEmpty)
        #expect(index.duplicateContactTitles.values.map { $0.sorted() } == [["a/Robert.md", "c/Other.md"]])
    }

    @Test("local file system: dataless flag, legacy .icloud placeholders, list")
    func localPlaceholders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "c2m-icloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "People"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "People/.Jane Doe.md.icloud"))
        try Data("y".utf8).write(to: root.appending(path: "People/Real.md"))
        try FileManager.default.createDirectory(
            at: root.appending(path: ".c2mdsync/devices/a"), withIntermediateDirectories: true)
        let fs = LocalVaultFS(root: root)
        let entries = try fs.enumerate().sorted { $0.path < $1.path }
        #expect(entries.map(\.path) == ["People/Jane Doe.md", "People/Real.md"])
        #expect(entries.map(\.isDataless) == [true, false])
        #expect(try fs.list(".c2mdsync/devices") == ["a"])
        #expect(try fs.list("nope").isEmpty)
        let index = try VaultIndex.scan(fs)
        #expect(index.undownloaded.map(\.path) == ["People/Jane Doe.md"])
    }
}
