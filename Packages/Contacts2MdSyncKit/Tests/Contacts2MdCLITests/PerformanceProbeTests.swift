import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// Timings on data sized like a real address book (about 3.8k cards in
/// 2.4k contacts, 2.4k notes). Opt-in: `C2M_PERF=1 swift test --filter Performance`.
@Suite("Performance probe", .enabled(if: ProcessInfo.processInfo.environment["C2M_PERF"] != nil))
struct PerformanceProbeTests {
    static func addressBook() -> FakeContactStore {
        let contacts = (1...2_400).map { number -> AppleContact in
            var values = CanonicalContact(kind: .person, title: "")
            values.name = PersonName(given: "Person\(number)", family: "Family\(number % 300)")
            values.emails = [Labeled("home", "p\(number)@example.com")]
            values.phones = [Labeled("mobile", "+1 415 555 \(String(format: "%04d", number))")]
            values.jobTitle = "Job \(number % 50)"
            values.body = number % 3 == 0 ? "A note about person \(number)." : nil
            let accounts: [(AccountKind, CanonicalContact)] =
                number <= 1_400 ? [(.iCloud, values), (.google, values)] : [(.iCloud, values)]
            return Fixtures.linked("p\(number)", accounts)
        }
        return FakeContactStore(contacts: contacts, containers: Fixtures.containers)
    }

    static func time<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try work()
        print("PERF \(label): \(clock.now - start)")
        return value
    }

    @Test("phases of read, plan and sync on a 3.8k-card / 2.4k-note vault")
    func probe() throws {
        let harness = CLIHarness(store: Self.addressBook())
        let export = Self.time("export") { harness.run(["export", "--root", "/vault", "--yes"]) }
        #expect(export.code == 0, "\(export.err)")
        var environment = harness.environment()
        environment.trigger = "GUI"
        let reader = UIVaultReader(root: URL(filePath: "/vault"), environment: environment)
        _ = try Self.time("first sync") { try reader.sync() }
        _ = try Self.time("read") { try reader.read() }
        _ = try Self.time("plan") { try reader.plan() }
        _ = try Self.time("sync (nothing to do)") { try reader.sync() }
        let verbose = Self.time("cli sync --verbose") { harness.run(["sync", "--root", "/vault", "--verbose"]) }
        print(
            verbose.out.split(separator: "\n").filter { $0.hasPrefix("timing") || $0.hasPrefix("summary") }
                .joined(separator: "\n"))
        let session = try #require(try harness.stateStore().recentSessions(limit: 1).first)
        print("PERF session timings: \(session.timings?.line ?? "none")")
        let writesOn = UIVaultOptions(appleWrites: true, stampContacts: false)
        _ = try Self.time("setOptions") { try reader.setOptions(writesOn) }
        let notesOn = harness.run(["config", "--root", "/vault", "--notes", "on"])
        print("PERF notes on: \(notesOn.code) \(notesOn.err)")
        for number in 1...5 {
            let path = "Inbox/Person\(number) Family\(number % 300).md"
            harness.vault.seed(
                path,
                Data((harness.vault.text(path) ?? "").replacingOccurrences(of: "Job \(number % 50)", with: "CTO").utf8)
            )
        }
        for label in ["writes + notes", "after writes"] {
            let run = Self.time("cli sync --verbose (\(label))") {
                harness.run(["sync", "--root", "/vault", "--verbose", "--max-apple-changes", "100"])
            }
            print(
                run.out.split(separator: "\n").filter {
                    $0.hasPrefix("timing") || $0.hasPrefix("summary") || $0.hasPrefix("notes") || $0.hasPrefix("apple ")
                }.joined(separator: "\n"))
            print(run.err)
        }
    }
}
