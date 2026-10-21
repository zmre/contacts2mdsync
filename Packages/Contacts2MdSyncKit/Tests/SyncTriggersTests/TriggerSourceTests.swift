import Foundation
import SyncTestSupport
import SyncTriggers
import Synchronization
import Testing
import VaultIndex

@testable import SyncEngine

/// Collects triggers a source emits.
final class TriggerLog: Sendable {
    private let triggers = Mutex<[SyncTrigger]>([])

    var emit: @Sendable (SyncTrigger) -> Void { { trigger in self.triggers.withLock { $0.append(trigger) } } }
    var all: [SyncTrigger] { triggers.withLock { $0 } }
}

@Suite("Vault events and own-write suppression")
struct VaultEventTests {
    let root = URL(filePath: "/vault-root-that-does-not-exist")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Files and their current hashes, as the filter would read them.
    func filter(_ registry: OwnWriteRegistry?, files: [String: String] = [:]) -> VaultEventFilter {
        VaultEventFilter(root: root, ownWrites: registry, hash: { files[$0] })
    }

    func event(_ relative: String, flags: UInt32 = 0) -> VaultFSEvent {
        VaultFSEvent(path: root.path(percentEncoded: false) + "/" + relative, flags: flags)
    }

    @Test("a note change is a live trigger; dot paths, .c2mdsync and paths outside the root are not")
    func relevance() {
        let filter = filter(nil)
        #expect(filter.decide([event("Inbox/Jane Doe.md")], at: now) == SyncTrigger(.live, reason: "Inbox/Jane Doe.md"))
        #expect(filter.decide([event(".c2mdsync/lease.json")], at: now) == nil)
        #expect(filter.decide([event(".c2mdsync/devices/x/decisions.jsonl")], at: now) == nil)
        #expect(filter.decide([event("Inbox/.Jane Doe.md.c2md-1234.tmp")], at: now) == nil)
        #expect(filter.decide([event(".DS_Store"), event(".obsidian/workspace.json")], at: now) == nil)
        #expect(filter.decide([VaultFSEvent(path: "/elsewhere/Jane.md")], at: now) == nil)
        #expect(filter.decide([VaultFSEvent(path: root.path(percentEncoded: false))], at: now) == nil)
        #expect(filter.decide([event("_images/x.jpg")], at: now)?.kind == .live)
    }

    @Test("FSEvents drop flags (MustScanSubDirs, UserDropped, KernelDropped, RootChanged) → full vault rescan")
    func dropFlags() {
        let filter = filter(nil)
        for flag: UInt32 in [0x1, 0x2, 0x4, 0x20] {
            let trigger = filter.decide([event(".c2mdsync/lease.json"), event("Inbox", flags: flag)], at: now)
            #expect(trigger?.kind == .rescanVault)
        }
        let request = SyncRunRequest(SyncTrigger(.rescanVault))
        #expect(request.vaultRescan && request.appleMode == .incremental)
    }

    @Test("own writes are ignored for 30 s while the file still has our bytes")
    func ownWrites() {
        let registry = OwnWriteRegistry()
        registry.record(path: "Inbox/Jane Doe.md", sha256: "ours", at: now)
        registry.record(path: "Inbox/Gone.md", sha256: nil, at: now)
        let unchanged = filter(registry, files: ["Inbox/Jane Doe.md": "ours"])
        #expect(unchanged.decide([event("Inbox/Jane Doe.md")], at: now.addingTimeInterval(5)) == nil)
        #expect(unchanged.decide([event("Inbox/Gone.md")], at: now.addingTimeInterval(5)) == nil)
        // Edited again by the user right after our write: a different hash triggers.
        let edited = filter(registry, files: ["Inbox/Jane Doe.md": "theirs"])
        #expect(edited.decide([event("Inbox/Jane Doe.md")], at: now.addingTimeInterval(5))?.kind == .live)
        // An own write among other changes still triggers for the others.
        #expect(unchanged.decide([event("Inbox/Jane Doe.md"), event("Work/Sam.md")], at: now)?.reason == "Work/Sam.md")
        // After the window the same bytes are no longer ours.
        #expect(unchanged.decide([event("Inbox/Jane Doe.md")], at: now.addingTimeInterval(31))?.kind == .live)
        #expect(registry.paths(at: now.addingTimeInterval(31)).isEmpty)
    }

    @Test("the registry learns every file a sync run wrote or trashed")
    func recordResult() {
        var result = SyncResult()
        result.markdown.writtenCache["Inbox/A.md"] = FileCacheEntry(
            path: "Inbox/A.md", modificationDate: now, size: 1, sha256: "aaa", kind: .contact, syncID: nil, title: nil,
            aliases: [], problem: nil)
        result.trashed = [NoteTrash(recordID: UUID(), path: "Inbox/B.md", title: "B")]
        let registry = OwnWriteRegistry()
        registry.record(result, at: now)
        #expect(registry.paths(at: now) == ["Inbox/A.md", "Inbox/B.md"])
        #expect(registry.isOwnWrite(path: "Inbox/A.md", currentSHA: "aaa", at: now))
        #expect(registry.isOwnWrite(path: "Inbox/B.md", currentSHA: nil, at: now))
        #expect(!registry.isOwnWrite(path: "Inbox/B.md", currentSHA: "back", at: now))
    }

    @Test("real FSEvents on a temporary folder: a write triggers, our own write does not")
    func realFSEvents() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "c2m-fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = OwnWriteRegistry()
        let source = VaultChangeSource(root: folder, ownWrites: registry, latency: 0.05)
        let log = TriggerLog()
        source.start(log.emit)
        defer { source.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let ours = Data("ours".utf8)
        registry.record(path: "Ours.md", sha256: FileStamp.hash(ours), at: Date())
        try ours.write(to: folder.appending(path: "Ours.md"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.all.isEmpty, "\(log.all)")
        try Data("theirs".utf8).write(to: folder.appending(path: "Theirs.md"))
        #expect(await eventually(timeout: 5) { log.all.contains { $0.kind == .live && $0.reason == "Theirs.md" } })
    }
}

@Suite("Notification sources")
struct NotificationSourceTests {
    @Test("wake: a .wake trigger 30 s after the notification; another wake restarts the delay")
    func wakeDelay() async {
        let clock = ManualTriggerClock()
        let center = NotificationCenter()
        let name = Notification.Name("TestWake")
        let source = WakeSource(center: center, name: name, delay: 30, clock: clock)
        let log = TriggerLog()
        source.start(log.emit)
        center.post(name: name, object: nil)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: 20)
        await settle()
        #expect(log.all.isEmpty)
        center.post(name: name, object: nil)  // woke again: 30 s from now
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: 15)
        await settle()
        #expect(log.all.isEmpty)
        clock.advance(by: 15)
        #expect(await eventually { log.all == [SyncTrigger(.wake, reason: "woke from sleep")] })
        source.stop()
        center.post(name: name, object: nil)
        clock.advance(by: 60)
        await settle()
        #expect(log.all.count == 1)
    }

    @Test("Contacts change notification → live trigger; none after stop")
    func contactsChange() {
        let center = NotificationCenter()
        let name = Notification.Name("TestContactsChanged")
        let source = ContactsChangeSource(center: center, name: name)
        let log = TriggerLog()
        source.start(log.emit)
        center.post(name: name, object: nil)
        #expect(log.all == [SyncTrigger(.live, reason: "Contacts changed")])
        source.stop()
        center.post(name: name, object: nil)
        #expect(log.all.count == 1)
    }
}
