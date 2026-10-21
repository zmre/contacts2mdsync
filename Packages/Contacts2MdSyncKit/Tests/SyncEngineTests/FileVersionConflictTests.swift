import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("iCloud conflict versions (NSFileVersion, architecture §11, M6)")
struct FileVersionConflictTests {
    static let path = "Inbox/Ann One.md"

    func world() throws -> SyncHarness {
        try World.exported(
            [World.ann(), World.person("bob", "Bob", "Two") { $0.emails = [Labeled(nil, "bob@two.example")] }],
            stamps: .never)
    }

    func versionItem(_ plan: SyncPlan) -> FileVersionConflict? {
        for case .fileVersionConflict(let conflict) in plan.markdown.reviews { return conflict }
        return nil
    }

    @Test("versions that say the same thing are resolved by keeping the current note, without asking")
    func identicalVersions() throws {
        let world = try world()
        let text = try #require(world.vault.text(Self.path))
        #expect(text.contains("title: Ann One"))
        world.vault.addConflictVersion(Self.path, Data(text.utf8))  // two devices wrote the same bytes
        world.vault.addConflictVersion(
            Self.path, Data(text.replacingOccurrences(of: "title: Ann One", with: "title: \"Ann One\"").utf8))
        let run = try world.sync()
        #expect(
            run.plan.markdown.versionResolutions == [
                FileVersionResolution(path: Self.path, keep: nil, reason: "identical")
            ])
        #expect(versionItem(run.plan) == nil && run.plan.markdown.skipped.isEmpty)
        #expect(run.result?.markdown.versionsResolved.count == 1)
        #expect(world.vault.conflictVersions.paths.isEmpty && world.vault.text(Self.path) == text)
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("a differing version pauses the record and asks; keep-other replaces the note, then it syncs")
    func keepOther() throws {
        let world = try world()
        let text = try #require(world.vault.text(Self.path))
        let other = text.replacingOccurrences(of: "Engineer", with: "Manager")
        world.vault.addConflictVersion(Self.path, Data(other.utf8), deviceName: "Mac B")
        world.store.editCard("ann:icloud") { $0.emails.append(Labeled("work", "ann@work.example")) }

        let paused = try world.sync()
        let conflict = try #require(versionItem(paused.plan))
        #expect(
            conflict.versions.map(\.deviceName) == ["Mac B"] && conflict.versions.first?.differences == ["job_title"])
        #expect(conflict.recordID != nil && conflict.title == "Ann One")
        let item = ReviewItem.fileVersionConflict(conflict)
        #expect(item.choices == ["keep-current", "keep-other:1"] && item.id.hasPrefix("version-"))
        #expect(item.summary.contains("iCloud kept 1 conflicting version (from Mac B: job_title)"))
        #expect(paused.plan.markdown.skipped.contains { $0.reason.contains("conflicting versions") })
        #expect(world.vault.text(Self.path) == text)  // the paused note is not touched
        #expect(paused.plan.needsReview)

        try world.decide(item.id, "keep-other:1")
        let kept = try world.sync()
        #expect(kept.result?.markdown.versionsResolved.first?.keep?.sha256 == conflict.versions.first?.sha256)
        #expect(world.vault.text(Self.path) == other && world.vault.conflictVersions.paths.isEmpty)

        let synced = try world.sync()
        #expect(synced.plan.conflicts.isEmpty)
        #expect(World.apple(world, "ann:icloud")?.jobTitle == "Manager")
        #expect(try world.note(Self.path)?.emails.map(\.value) == ["ann@home.example", "ann@work.example"])
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("keep-current resolves the versions; a new version or a later edit asks again")
    func keepCurrent() throws {
        let world = try world()
        let text = try #require(world.vault.text(Self.path))
        world.vault.addConflictVersion(Self.path, Data(text.replacingOccurrences(of: "Engineer", with: "CTO").utf8))
        let item = ReviewItem.fileVersionConflict(try #require(versionItem(try world.sync().plan)))
        try world.decide(item.id, "keep-current")
        // A further version arrived before the leader ran: the decision does not cover it.
        world.vault.addConflictVersion(Self.path, Data(text.replacingOccurrences(of: "Engineer", with: "CEO").utf8))
        let again = try world.sync()
        let both = try #require(versionItem(again.plan))
        #expect(both.versions.count == 2 && again.plan.markdown.versionResolutions.isEmpty)
        #expect(ReviewItem.fileVersionConflict(both).id == item.id)  // same item, asked again
        try world.decide(item.id, "keep-current")
        let resolved = try world.sync()
        #expect(resolved.plan.markdown.versionResolutions.map(\.reason) == ["decision"])
        #expect(world.vault.conflictVersions.paths.isEmpty && world.vault.text(Self.path) == text)
        #expect(World.apple(world, "ann:icloud")?.jobTitle == "Engineer")
        #expect(try world.sync().plan.isEmpty)
    }

    @Test("config.yaml versions: equal settings resolve silently; different settings ask, no record paused")
    func configVersions() throws {
        let world = try world()
        let config = try #require(world.vault.text(VaultConfig.path))
        world.vault.addConflictVersion(VaultConfig.path, Data((config + "\n").utf8))
        let quiet = try world.sync()
        #expect(quiet.plan.markdown.versionResolutions.map(\.path) == [VaultConfig.path])
        #expect(world.vault.conflictVersions.paths.isEmpty)

        let changed = config.replacingOccurrences(of: "apple_writes: enabled", with: "apple_writes: disabled")
        #expect(changed != config)
        world.vault.addConflictVersion(VaultConfig.path, Data(changed.utf8))
        world.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        let asked = try world.sync()
        let conflict = try #require(versionItem(asked.plan))
        #expect(
            conflict.path == VaultConfig.path && conflict.recordID == nil
                && conflict.versions.first?.differences == ["text"])
        #expect(try world.note("Inbox/Bob Two.md")?.jobTitle == "Chef")  // records keep syncing
    }

    @Test("an iCloud conflicted copy (`Ann One 2.md`) is a copied note: paused and named as such")
    func conflictedCopy() throws {
        let world = try world()
        let text = try #require(world.vault.text(Self.path))
        world.vault.seed("Inbox/Ann One 2.md", Data(text.replacingOccurrences(of: "Engineer", with: "Lead").utf8))
        let run = try world.sync()
        let item = try #require(run.plan.markdown.reviews.first { $0.id.hasPrefix("copy-") })
        #expect(item.conflictedCopyPaths == ["Inbox/Ann One 2.md"])
        #expect(item.summary.hasSuffix("(iCloud conflicted copy: Inbox/Ann One 2.md)"))
        #expect(world.vault.text(Self.path) == text)
        #expect(
            FileVersionConflict.conflictedCopies(among: ["a/Jane.md", "a/Jane 2.md", "b/Jane 3.md", "a/Jane x.md"])
                == ["a/Jane 2.md"])
    }

    @Test("LocalVaultFS outside iCloud: no versions, no conflict flag, resolving is harmless")
    func localFileSystem() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "c2m-versions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fs = LocalVaultFS(root: folder)
        _ = try fs.write(Data("hello".utf8), to: "Inbox/a.md", expecting: .absent)
        #expect(try fs.unresolvedConflictVersions("Inbox/a.md").isEmpty)
        #expect(try fs.unresolvedConflictVersions("Inbox/missing.md").isEmpty)
        #expect(try fs.enumerate().map(\.hasUnresolvedConflicts) == [false])
        try fs.resolveConflictVersions("Inbox/a.md", keeping: nil)
        #expect(throws: VaultFSError.self) {
            try fs.resolveConflictVersions("Inbox/a.md", keeping: FileConflictVersion(data: Data("x".utf8)))
        }
        #expect(try fs.read("Inbox/a.md").0 == Data("hello".utf8))
    }
}
