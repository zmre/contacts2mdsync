import ContactModel
import Foundation
import SyncTestSupport
import Testing
import VaultIndex

@testable import SyncEngine

@Suite("Diff3 (note bodies)")
struct Diff3Tests {
    @Test("non-overlapping edits merge; overlapping edits conflict; one-sided edits win")
    func merge() {
        let base = "a\nb\nc\nd"
        #expect(Diff3.merge(base: base, apple: "a\nB\nc\nd", markdown: "a\nb\nc\nD") == "a\nB\nc\nD")
        #expect(Diff3.merge(base: base, apple: "a\nX\nc\nd", markdown: "a\nY\nc\nd") == nil)
        #expect(Diff3.merge(base: base, apple: base, markdown: "z") == "z")
        #expect(Diff3.merge(base: base, apple: "a\nb\nc\nd\ne", markdown: "0\na\nb\nc\nd") == "0\na\nb\nc\nd\ne")
        #expect(Diff3.merge(base: base, apple: "same", markdown: "same") == "same")
    }
}

@Suite("Scope (architecture §12)")
struct ScopeTests {
    static func scope(_ yaml: String) throws -> SyncScope {
        let vault = InMemoryVault(files: [VaultConfig.path: "vault_id: \(UUID().uuidString)\n" + yaml])
        return try #require(try VaultConfig.load(from: vault)?.config.scope)
    }

    @Test("contact rules beat group rules; exclude beats include; containers, paths, require_tag")
    func rules() throws {
        let id = UUID()
        let contact = Fixtures.contact("x", accounts: [.google]) { _ in }
        let scope = try Self.scope(
            """
            scope:
              containers: [icloud]
              include_groups: [Family]
              exclude_groups: [Work]
              include_contacts: [\(id.uuidString.lowercased())]
              markdown:
                include_paths: ["People/**"]
              require_tag: family
            on_leave_scope: detach
            """)
        #expect(scope.onLeaveScope == "detach")
        // Contact include beats groups and containers.
        #expect(scope.contains(id: id, contact: contact, groupNames: ["Work"], path: "People/a.md", tags: []))
        // …but not a path outside include_paths.
        #expect(!scope.contains(id: id, contact: contact, groupNames: [], path: "Other/a.md", tags: []))
        // Not in an included group / in an excluded group / wrong container / missing tag.
        let icloud = Fixtures.contact("y") { _ in }
        #expect(!scope.contains(id: nil, contact: icloud, groupNames: [], path: nil, tags: ["family"]))
        #expect(!scope.contains(id: nil, contact: icloud, groupNames: ["Family", "Work"], path: nil, tags: ["family"]))
        #expect(!scope.contains(id: nil, contact: contact, groupNames: ["Family"], path: nil, tags: ["family"]))
        #expect(!scope.contains(id: nil, contact: icloud, groupNames: ["Family"], path: nil, tags: []))
        #expect(scope.contains(id: nil, contact: icloud, groupNames: ["Family"], path: nil, tags: ["Family"]))
        #expect(try Self.scope("").isUnrestricted)
    }
}

@Suite("Config: sync switches and limits")
struct SyncConfigTests {
    @Test("apple_writes and stamp_contacts default off, parse common spellings, and patch in place")
    func switches() throws {
        let text =
            "vault_id: \(UUID().uuidString.lowercased())\napple_writes: yes  # mine\nlimits:\n  mass_vanish_count: 3\n"
        let vault = InMemoryVault(files: [VaultConfig.path: text])
        let (config, original) = try #require(try VaultConfig.load(from: vault))
        #expect(config.appleWrites && !config.stampContacts)
        #expect(config.limits.massVanishCount == 3 && config.limits.maxAppleChanges == 25)
        // Unchanged semantics keep the user's spelling and comment.
        #expect(config.render(patching: original) == original)
        var changed = config
        changed.appleWrites = false
        changed.stampContacts = true
        let rendered = changed.render(patching: original)
        #expect(rendered.contains("apple_writes: disabled\n") && rendered.contains("stamp_contacts: true\n"))
        #expect(rendered.contains("limits:\n  mass_vanish_count: 3\n"))
        let fresh = VaultConfig(vaultID: UUID())
        #expect(!fresh.appleWrites && !fresh.stampContacts)
    }
}

@Suite("Lease and local lock (architecture §11, §15)")
struct LeaseTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("write-wait-reread: a device that loses the race during the settle wait does not lead")
    func contention() throws {
        let vault = InMemoryVault()
        let clock = TestClock(start: Self.start)
        let deviceB = LeaseManager(fs: vault, device: DeviceIdentity(id: "b", name: "Mac B"), clock: clock, settle: 0)
        let deviceA = LeaseManager(
            fs: vault, device: DeviceIdentity(id: "a", name: "Mac A"), clock: clock, settle: 60,
            sleep: { _ in _ = try? deviceB.acquire(takeOver: true, otherDevicesKnown: true) })
        guard case .heldElsewhere(let lease) = try deviceA.acquire(otherDevicesKnown: true) else {
            Issue.record("A should have lost the race")
            return
        }
        #expect(lease.deviceID == "b")
        // B holds an unexpired lease: A backs off without writing.
        guard case .heldElsewhere = try deviceA.acquire(otherDevicesKnown: true) else {
            Issue.record("B's lease is valid")
            return
        }
        // After the TTL, A takes it; renewing its own lease needs no wait.
        clock.advance(21 * 60)
        let quickA = LeaseManager(fs: vault, device: DeviceIdentity(id: "a", name: "Mac A"), clock: clock, settle: 0)
        guard case .acquired = try quickA.acquire(otherDevicesKnown: true) else {
            Issue.record("expired lease should be taken")
            return
        }
        let waits = Counter()
        let renewing = LeaseManager(
            fs: vault, device: DeviceIdentity(id: "a", name: "Mac A"), clock: clock, settle: 60,
            sleep: { _ in waits.increment() })
        _ = try renewing.acquire(otherDevicesKnown: true)
        #expect(waits.value == 0)
    }

    @Test("a single-device vault never waits for the settle delay")
    func singleDevice() throws {
        let waits = Counter()
        let manager = LeaseManager(
            fs: InMemoryVault(), device: DeviceIdentity(id: "a", name: "Mac A"), clock: TestClock(start: Self.start),
            sleep: { _ in waits.increment() })
        guard case .acquired = try manager.acquire(otherDevicesKnown: false) else {
            Issue.record("should lead")
            return
        }
        #expect(waits.value == 0)
    }

    @Test("the local lock is exclusive until released")
    func localLock() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "c2m-lock-\(UUID().uuidString)/sync.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(try LocalLock.acquire(at: url, wait: 0))
        #expect(try LocalLock.acquire(at: url, wait: 0.4, poll: 0.2, sleep: { _ in }) == nil)
        first.release()
        #expect(try LocalLock.acquire(at: url, wait: 0) != nil)
    }
}

/// Thread-safe counter for callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }

    var value: Int { lock.withLock { count } }
}
