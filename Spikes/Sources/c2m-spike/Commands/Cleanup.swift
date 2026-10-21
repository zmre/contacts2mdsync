import ArgumentParser
import Contacts
import Foundation

/// Deletes harness cards only: name prefix AND marker URL must both match,
/// re-verified on a fresh fetch immediately before each delete. With no
/// `--spike` or `--spike s13`, also deletes the S13 scratch group, but only a
/// group named exactly "ZZ Spike S13 Group" whose members are all harness
/// cards (or none), re-checked right before the delete.
struct Cleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete scratch cards created by this harness (name prefix AND marker URL both required).")

    @Option(help: "Only delete cards of this spike tag (s1, s3, s4, s5, s12, s13).")
    var spike: String?

    @Flag(help: "Actually delete.")
    var yes = false

    func run() throws {
        try runReporting {
            let store = try Access.authorizedStore()
            let scan = try HarnessScan.run(store)
            let targets = spike.map { scan.harness(spike: $0) } ?? scan.harness

            let writer = SafeWriter(store: store)
            let groups = spike == nil || spike == S13Writes.spike ? try scratchGroups(writer) : []
            var plan = targets.map { "delete \"\(Harness.displayName($0))\" identifier=\($0.identifier)" }
            for (group, members) in groups {
                plan.append(
                    members.other.isEmpty
                        ? "delete group \"\(group.name)\" identifier=\(group.identifier) (\(members.harness.count) harness member(s))"
                        : "KEEP group \"\(group.name)\" identifier=\(group.identifier): \(members.other.count) non-harness member(s); remove them by hand first"
                )
            }
            if !scan.nameOnly.isEmpty || !scan.markerOnly.isEmpty {
                print(
                    "NOT deleted (only one of the two markers matches; delete by hand in Contacts.app if they are ours):"
                )
                for card in scan.nameOnly {
                    print("  name prefix only: \"\(Harness.displayName(card))\" identifier=\(card.identifier)")
                }
                for card in scan.markerOnly { print("  marker only: identifier=\(card.identifier) (name not printed)") }
            }
            if targets.isEmpty && groups.isEmpty {
                print("No harness cards or scratch groups to delete.")
                return
            }
            guard confirmPlan("cleanup (\(targets.count) cards, \(groups.count) scratch groups)", plan, yes: yes) else {
                return
            }
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
            for (group, _) in groups {
                do {
                    try writer.deleteGroup(group.identifier)  // re-checks name + members on a fresh fetch
                    print("deleted group \(group.identifier)")
                } catch {
                    print("NOT deleted group \(group.identifier): \(describe(error))")
                }
            }
        }
    }

    /// Groups named exactly like a harness scratch group, with their members.
    private func scratchGroups(_ writer: SafeWriter) throws -> [(CNGroup, (harness: [String], other: [String]))] {
        try Harness.scratchGroupNames.sorted().flatMap { name in
            try writer.scratchGroups(named: name).map { ($0, try writer.groupMembers($0.identifier)) }
        }
    }
}
