import ArgumentParser
import Contacts
import Foundation

/// Deletes harness cards only: name prefix AND marker URL must both match,
/// re-verified on a fresh fetch immediately before each delete.
struct Cleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete scratch cards created by this harness (name prefix AND marker URL both required).")

    @Option(help: "Only delete cards of this spike tag (s1, s3, s4, s5).")
    var spike: String?

    @Flag(help: "Actually delete.")
    var yes = false

    func run() throws {
        try runReporting {
            let store = try Access.authorizedStore()
            let scan = try HarnessScan.run(store)
            let targets = spike.map { scan.harness(spike: $0) } ?? scan.harness

            let plan = targets.map { "delete \"\(Harness.displayName($0))\" identifier=\($0.identifier)" }
            if !scan.nameOnly.isEmpty || !scan.markerOnly.isEmpty {
                print(
                    "NOT deleted (only one of the two markers matches; delete by hand in Contacts.app if they are ours):"
                )
                for card in scan.nameOnly {
                    print("  name prefix only: \"\(Harness.displayName(card))\" identifier=\(card.identifier)")
                }
                for card in scan.markerOnly { print("  marker only: identifier=\(card.identifier) (name not printed)") }
            }
            if targets.isEmpty {
                print("No harness cards to delete.")
                return
            }
            guard confirmPlan("cleanup (\(targets.count) cards)", plan, yes: yes) else { return }
            let writer = SafeWriter(store: store)
            var deleted = Set<String>()
            for card in targets {
                do {
                    try writer.delete(card.identifier)
                    deleted.insert(card.identifier)
                    print("deleted \(card.identifier)")
                } catch {
                    print("FAILED \(card.identifier): \(describe(error))")
                }
            }
            try Ledger.remove(identifiers: deleted)
        }
    }
}
