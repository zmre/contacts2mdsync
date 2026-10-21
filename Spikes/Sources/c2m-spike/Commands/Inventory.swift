import ArgumentParser
import Contacts
import Foundation

/// Read-only overview. Prints counts and opaque identifiers only, never names,
/// emails, phones or notes of real contacts.
struct Inventory: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read-only: container/contact/group/link counts, notes-key probe, history token. No PII.")

    @OptionGroup var containerOptions: ContainerOptions

    func run() throws {
        try runReporting {
            print("c2m-spike inventory  \(Stamp.iso())")
            print("authorization: \(Access.statusName(Access.currentStatus))")
            let store = try Access.authorizedStore()

            let containers = try store.containers(matching: nil)
            let defaultID = store.defaultContainerIdentifier()
            print("\n## Containers (\(containers.count))")
            var table = MarkdownTable(
                headers: ["#", "type", "name", "guessed kind", "default", "cards", "groups", "identifier"])
            let map = try UnifiedMap.build(store, containers: containers)
            let cardsByContainer = Dictionary(grouping: map.cards, by: \.containerID)
            var kindByContainer: [String: AccountKind] = [:]
            for (index, container) in containers.enumerated() {
                let kind = containerOptions.kind(ofContainer: container)
                kindByContainer[container.identifier] = kind
                let groups =
                    (try? store.groups(
                        matching: CNGroup.predicateForGroupsInContainer(withIdentifier: container.identifier)
                    ).count)
                    .map(String.init) ?? "error"
                table.rows.append([
                    "\(index)", container.type.name, redactedContainerName(container.name),
                    kind?.rawValue ?? "-", container.identifier == defaultID ? "yes" : "",
                    "\(cardsByContainer[container.identifier]?.count ?? 0)", groups, container.identifier,
                ])
            }
            print(table.render())
            let byType = Dictionary(grouping: containers, by: { $0.type.name }).mapValues(\.count)
            print(
                "containers by type: "
                    + byType.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

            print("\n## Contacts")
            print("underlying cards:                \(map.cards.count)")
            print("unified (fetch, unify=on):       \(map.unifiedFetchCount)")
            print("unified (distinct via mapping):  \(map.unifiedIDs.count)")
            if map.resolveFailures > 0 { print("unifiedContact(withIdentifier:) failures: \(map.resolveFailures)") }
            if map.unifiedIDs.count != map.unifiedFetchCount {
                print("NOTE: mapping and unified fetch disagree; record this in S4/S9 results.")
            }
            let members = map.members
            let sizeHistogram = Dictionary(grouping: members.values, by: \.count).mapValues(\.count)
            print(
                "cards per unified contact: "
                    + sizeHistogram.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
            var crossICloudGoogle = 0
            var crossContainer = 0
            var sameContainerLinks = 0
            for cards in members.values where cards.count > 1 {
                let containerSet = Set(cards.map(\.containerID))
                let kinds = Set(containerSet.compactMap { kindByContainer[$0] })
                if containerSet.count > 1 { crossContainer += 1 } else { sameContainerLinks += 1 }
                if kinds.contains(.icloud) && kinds.contains(.google) { crossICloudGoogle += 1 }
            }
            print("linked unified contacts spanning >1 container: \(crossContainer)")
            print("linked unified contacts spanning iCloud+Google: \(crossICloudGoogle)")
            print("linked unified contacts within one container:  \(sameContainerLinks)")

            print("\n## Notes key probe (CNContactNoteKey on one card)")
            if let probeID = map.cards.first?.id {
                do {
                    let contact = try catchingObjC {
                        try store.unifiedContact(
                            withIdentifier: probeID, keysToFetch: [CNContactNoteKey as any CNKeyDescriptor])
                    }
                    let readable = contact.isKeyAvailable(CNContactNoteKey)
                    print("notes readable: \(readable ? "yes" : "no (key unavailable)") (content not printed)")
                } catch {
                    let ns = error as NSError
                    let hint =
                        (ns.domain == CNErrorDomain && ns.code == 102)
                        ? " -> error 102 (policy: no notes entitlement)" : ""
                    print("notes readable: no -- \(describe(error))\(hint)")
                }
            } else {
                print("no cards to probe")
            }

            print("\n## Change history")
            if let token = store.currentHistoryToken {
                print("currentHistoryToken: present (\(token.count) bytes)")
            } else {
                print("currentHistoryToken: nil")
            }

            let scan = try HarnessScan.run(store)
            print("\n## Harness scratch cards")
            print(
                "harness cards: \(scan.harness.count)  name-only (marker lost): \(scan.nameOnly.count)  marker-only: \(scan.markerOnly.count)"
            )
        }
    }
}
