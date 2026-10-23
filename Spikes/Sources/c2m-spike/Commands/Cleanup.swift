import ArgumentParser
import Contacts
import Foundation

/// Deletes harness cards only: name prefix AND marker URL must both match,
/// re-verified on a fresh fetch immediately before each delete. With no
/// `--spike`, `--spike s13` or `--spike s15`, also deletes that spike's scratch
/// group ("ZZ Spike S13 Group" / "ZZ Spike S15 Group"), but only a group with
/// exactly that name whose members are all harness cards (or none), re-checked
/// right before the delete.
///
/// A card that has a note cannot be deleted through CNSaveRequest without the
/// notes entitlement (NSCocoaErrorDomain 134092, spike S15). When the
/// CNSaveRequest delete fails, the card is deleted through Contacts.app
/// scripting instead (`delete person id X` + `save`), after both CNContactStore
/// and Contacts.app confirm it is the same harness card. `--no-scripting`
/// turns that fallback off.
struct Cleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete scratch cards created by this harness (name prefix AND marker URL both required).")

    @Option(help: "Only delete cards of this spike tag (s1, s3, s4, s5, s12, s13, s14, s15).")
    var spike: String?

    @Flag(help: "Do not fall back to Contacts.app scripting when a CNSaveRequest delete fails (noted cards).")
    var noScripting = false

    @Flag(help: "Actually delete.")
    var yes = false

    func run() throws {
        try runReporting {
            let store = try Access.authorizedStore()
            let scan = try HarnessScan.run(store)
            let targets = spike.map { scan.harness(spike: $0) } ?? scan.harness

            let writer = SafeWriter(store: store)
            let groupNames = spike.map { Harness.scratchGroupsBySpike[$0].map { [$0] } ?? [] }
                ?? Harness.scratchGroupNames.sorted()
            let groups = try scratchGroups(writer, names: groupNames)
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
            if !noScripting {
                plan.append(
                    "if a CNSaveRequest delete fails (a card with a note, S15): delete it through Contacts.app "
                        + "scripting after CNContactStore and Contacts.app both confirm the harness card")
            }
            guard confirmPlan("cleanup (\(targets.count) cards, \(groups.count) scratch groups)", plan, yes: yes) else {
                return
            }
            var deleted = Set<String>()
            var fallback = ScriptingDelete(store: store)
            for card in targets {
                do {
                    try writer.delete(card.identifier)
                    deleted.insert(card.identifier)
                    print("deleted \(card.identifier)")
                } catch {
                    let cnError = describe(error)
                    guard !noScripting else {
                        print("FAILED \(card.identifier): \(cnError)")
                        continue
                    }
                    print("CNSaveRequest delete failed for \(card.identifier) (\(cnError)); trying Contacts.app scripting")
                    do {
                        try fallback.delete(card.identifier)
                        deleted.insert(card.identifier)
                        print("deleted \(card.identifier) via Contacts.app scripting")
                    } catch {
                        print("FAILED \(card.identifier) via scripting too: \(describe(error))")
                    }
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

    /// Groups named exactly like one of `names` (harness scratch group names), with their members.
    private func scratchGroups(_ writer: SafeWriter, names: [String]) throws
        -> [(CNGroup, (harness: [String], other: [String]))]
    {
        try names.flatMap { name in
            try writer.scratchGroups(named: name).map { ($0, try writer.groupMembers($0.identifier)) }
        }
    }
}

/// Deletes one harness card through Contacts.app scripting (the fallback for
/// cards with a note, spike S15). Both sides are checked right before the
/// delete: the card must still pass `Harness.isHarness` on a fresh
/// CNContactStore fetch, and Contacts.app must show the same id, the
/// `ZZ Spike ` prefix and the same marker URL (`S14NotesGuard`).
struct ScriptingDelete {
    let store: CNContactStore
    private var handlers: (guardCheck: S14NotesGuard, script: S15Scripting)?

    init(store: CNContactStore) {
        self.store = store
    }

    mutating func delete(_ id: String) throws {
        if handlers == nil {
            handlers = (S14NotesGuard(store: store, scripting: try ContactsScripting()), try S15Scripting())
        }
        let (guardCheck, script) = handlers!
        let card = try SafeWriter(store: store).verifiedCard(id, keys: [])
        guard let tag = Harness.marker(card).flatMap(Harness.spikeTag) else {
            throw SpikeError("SAFETY: card \(id) has no spike tag; refusing.")
        }
        try guardCheck.checkTargets([id], allowedSpikes: [tag])
        try script.deletePerson(id)
        let deadline = Date().addingTimeInterval(8)
        while try fetchUnderlying(store, id: id, keys: []) != nil {
            guard Date() < deadline else { throw SpikeError("Contacts.app deleted \(id) but CNContactStore still has it after 8 s.") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
    }
}
