import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

@Suite("Decision log across devices (architecture §4, §11, M6)")
struct DecisionLogRobustnessTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let macA = DeviceIdentity(id: "device-a", name: "Mac A")
    static let macB = DeviceIdentity(id: "device-b", name: "Mac B")
    static let record = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa") ?? UUID()

    func delete(_ choice: String, by device: DeviceIdentity, at offset: TimeInterval) -> Decision {
        Decision(
            kind: .appleDelete, createdAt: Self.start.addingTimeInterval(offset), device: device,
            path: "Inbox/Ann One.md", syncID: Self.record, itemID: "deleted-1", choice: choice)
    }

    @Test("union of every device's log, deduplicated, ordered by time then device")
    func unionAndOrder() throws {
        let vault = InMemoryVault()
        let shared = delete("keep", by: Self.macA, at: 0)
        let sameTimeB = Decision(kind: .ignoreCandidate, createdAt: Self.start, device: Self.macB, path: "x.md")
        let later = Decision(
            kind: .ignoreCandidate, createdAt: Self.start.addingTimeInterval(60), device: Self.macA,
            path: "y.md")
        try DecisionLog.append([later, shared], deviceID: Self.macA.id, fs: vault)
        try DecisionLog.append([sameTimeB, shared], deviceID: Self.macB.id, fs: vault)  // a copied line
        let log = try DecisionLog.read(vault)
        #expect(log.decisions.map(\.id) == [shared.id, sameTimeB.id, later.id])
        #expect(log.problems.isEmpty && log.conflicts.isEmpty)
    }

    @Test("an unterminated last line still arriving through iCloud is skipped silently, then read once complete")
    func partialLastLine() throws {
        let vault = InMemoryVault()
        let first = delete("keep", by: Self.macB, at: 0)
        try DecisionLog.append([first], deviceID: Self.macB.id, fs: vault)
        let path = DecisionLog.path(deviceID: Self.macB.id)
        let complete = try #require(vault.data(path))
        let second = Decision(kind: .ignoreCandidate, createdAt: Self.start, device: Self.macB, path: "x.md")
        var full = complete
        try DecisionLog.append([second], deviceID: Self.macB.id, fs: vault)
        full = try #require(vault.data(path))
        vault.seed(path, full.prefix(complete.count + 20))  // half of the second line delivered
        let partial = try DecisionLog.read(vault)
        #expect(partial.decisions.map(\.id) == [first.id])
        #expect(partial.problems.isEmpty && partial.partialLines == 1)
        #expect(try DecisionLog.readAll(vault).problems.isEmpty)
        vault.seed(path, full)
        #expect(try DecisionLog.read(vault).decisions.count == 2)
        // A broken line in the middle is still reported.
        vault.seed(path, Data("{not json\n".utf8) + full)
        #expect(try DecisionLog.read(vault).problems == ["\(path):1: unreadable decision"])
    }

    @Test("appending after a cut-off own line drops the fragment instead of burying it")
    func appendDropsPartialTail() throws {
        let vault = InMemoryVault()
        let first = delete("keep", by: Self.macA, at: 0)
        try DecisionLog.append([first], deviceID: Self.macA.id, fs: vault)
        let path = DecisionLog.path(deviceID: Self.macA.id)
        vault.seed(path, try #require(vault.data(path)) + Data("{\"id\":\"trunc".utf8))
        let next = Decision(
            kind: .ignoreCandidate, createdAt: Self.start.addingTimeInterval(60), device: Self.macA, path: "x.md")
        try DecisionLog.append([next], deviceID: Self.macA.id, fs: vault)
        let log = try DecisionLog.read(vault)
        #expect(log.decisions.map(\.id) == [first.id, next.id] && log.problems.isEmpty && log.partialLines == 0)
    }

    @Test("the same item decided differently on two devices: the latest wins, with a warning")
    func conflictingDecisions() throws {
        let vault = InMemoryVault()
        try DecisionLog.append([delete("trash", by: Self.macA, at: 0)], deviceID: Self.macA.id, fs: vault)
        try DecisionLog.append([delete("keep", by: Self.macB, at: 120)], deviceID: Self.macB.id, fs: vault)
        let log = try DecisionLog.read(vault)
        let conflict = try #require(log.conflicts.first)
        #expect(conflict.itemID == "deleted-1" && conflict.winner.choice == "keep")
        #expect(
            conflict.message
                == "item deleted-1 decided differently on Mac A (trash) and Mac B (keep); the latest (Mac B: keep) wins"
        )
        #expect(try DecisionLog.readAll(vault).problems == [conflict.message])
        let set = DecisionSet(log.decisions)
        #expect(set.appleDeleteChoice(for: Self.record) == "keep")
        #expect(set.all.count == 1)  // the overridden answer is not in effect at all

        // Re-deciding on one device, or overriding much later, is not a conflict.
        let quiet = InMemoryVault()
        try DecisionLog.append(
            [delete("trash", by: Self.macA, at: 0), delete("keep", by: Self.macA, at: 60)], deviceID: Self.macA.id,
            fs: quiet)
        try DecisionLog.append([delete("restore", by: Self.macB, at: 3 * 3600)], deviceID: Self.macB.id, fs: quiet)
        let later = try DecisionLog.read(quiet)
        #expect(later.conflicts.isEmpty)
        #expect(DecisionSet(later.decisions).appleDeleteChoice(for: Self.record) == "restore")
    }

    @Test("iCloud conflict versions of a log are read as a union and merged by the owning device")
    func logConflictVersions() throws {
        let vault = InMemoryVault()
        let kept = delete("keep", by: Self.macA, at: 0)
        let lost = Decision(
            kind: .ignoreCandidate, createdAt: Self.start.addingTimeInterval(5), device: Self.macA,
            path: "lost.md")
        try DecisionLog.append([kept], deviceID: Self.macA.id, fs: vault)
        let path = DecisionLog.path(deviceID: Self.macA.id)
        let current = try #require(vault.data(path))
        try DecisionLog.append([lost], deviceID: Self.macA.id, fs: vault)
        let other = try #require(vault.data(path))
        vault.seed(path, current)
        vault.addConflictVersion(path, other)
        #expect(try DecisionLog.read(vault).decisions.map(\.id) == [kept.id, lost.id])
        // Another device never rewrites A's log; A folds the version in.
        try DecisionLog.mergeConflictVersions(deviceID: Self.macA.id, fs: vault)
        #expect(vault.conflictVersions.paths.isEmpty)
        #expect(vault.text(path)?.contains("lost.md") == true)
        #expect(try DecisionLog.read(vault).decisions.map(\.id) == [kept.id, lost.id])
    }
}
