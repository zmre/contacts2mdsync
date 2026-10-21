import ArgumentParser
import Contacts
import Foundation

/// S1: does a URL labeled `mdsync` with value `x-mdsync:<uuid>` survive on
/// iCloud and Google cards?
struct S1Stamp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s1-stamp",
        abstract: "S1: stamp URL survival on iCloud / Google.",
        subcommands: [Create.self, Check.self])

    static let stampLabel = "mdsync"
    static let stampScheme = "x-mdsync:"

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a scratch card carrying the S1 stamp URL.")

        @Option(help: "Target account: icloud or google.")
        var container: AccountKind

        @OptionGroup var containerOptions: ContainerOptions

        @Flag(help: "Actually create the card.")
        var yes = false

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let target = try containerOptions.resolve(container, in: store)
                let short = Stamp.short()
                let stamp = "\(S1Stamp.stampScheme)\(UUID().uuidString.lowercased())"
                let (card, marker) = Harness.newCard(
                    spike: "s1", kind: container.rawValue, suffix: "\(container.rawValue) \(short)")
                card.urlAddresses.append(CNLabeledValue(label: S1Stamp.stampLabel, value: stamp as NSString))

                let plan = [
                    "create \"\(Harness.displayName(card))\" in container \(target.identifier) (\(container.rawValue), name \(redactedContainerName(target.name)))",
                    "URL \(Harness.markerLabel) = \(marker)",
                    "URL \(S1Stamp.stampLabel) = \(stamp)",
                ]
                guard confirmPlan("s1-stamp create", plan, yes: yes) else { return }
                let preSaveID = card.identifier
                try SafeWriter(store: store).add(card, to: target.identifier)
                guard let saved = try Harness.locate(store, marker: marker) else {
                    throw SpikeError("Saved, but could not find the card again by marker.")
                }
                try Ledger.append(
                    LedgerEntry(
                        spike: "s1", kind: container.rawValue, identifier: saved.identifier, marker: marker,
                        containerID: target.identifier, createdAt: Stamp.iso()))
                print("created identifier=\(saved.identifier) (pre-save mutable id: \(preSaveID))")
                print("Next: wait for sync, then run `c2m-spike s1-stamp check` here and on other devices;")
                print(
                    "also inspect the card on iPhone, iCloud.com and contacts.google.com, edit it on the web, re-check."
                )
            }
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only: report whether marker + stamp label/value survived on every S1 card.")

        @OptionGroup var containerOptions: ContainerOptions

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let scan = try HarnessScan.run(store)
                let ledger = Ledger.load().filter { $0.spike == "s1" }
                // Name-only matches are included read-only: a stripped URL is a result, not an error.
                let candidates =
                    scan.harness(spike: "s1")
                    + scan.nameOnly.filter { Harness.displayName($0).hasPrefix("\(Harness.namePrefix)S1 ") }
                print(
                    "s1-stamp check  \(Stamp.iso())  cards found: \(candidates.count)  ledger entries (this Mac): \(ledger.count)"
                )
                var table = MarkdownTable(
                    headers: [
                        "card", "container", "identifier", "in ledger", "marker", "stamp label", "stamp value",
                        "all URLs",
                    ])
                var seenLedger = Set<String>()
                for card in candidates {
                    let containerKind =
                        (try? store.container(ofContact: card.identifier))
                        .flatMap { $0.map { containerOptions.kind(ofContainer: $0)?.rawValue ?? $0.type.name } } ?? "?"
                    let urls = card.urlAddresses
                    let stamp = urls.first { ($0.value as String).hasPrefix(S1Stamp.stampScheme) }
                    let markerValue = Harness.marker(card)
                    let ledgerHit =
                        ledger.first { $0.identifier == card.identifier }
                        ?? ledger.first { markerValue != nil && $0.marker == markerValue }
                    if let ledgerHit { seenLedger.insert(ledgerHit.identifier) }
                    let ledgerText: String
                    if let ledgerHit {
                        ledgerText =
                            ledgerHit.identifier == card.identifier
                            ? "yes (same id)" : "yes (ID CHANGED from \(ledgerHit.identifier))"
                    } else {
                        ledgerText = "no"
                    }
                    let stampLabel: String
                    if let stamp {
                        stampLabel = stamp.label == S1Stamp.stampLabel ? "intact" : "CHANGED -> \(stamp.label ?? "nil")"
                    } else {
                        stampLabel = "MISSING"
                    }
                    table.rows.append([
                        Harness.displayName(card), containerKind, card.identifier, ledgerText,
                        markerValue == nil ? "MISSING" : "intact", stampLabel,
                        stamp.map { $0.value as String } ?? "MISSING",
                        urls.map { "\($0.label ?? "nil")=\($0.value)" }.joined(separator: "; "),
                    ])
                }
                print(table.render())
                let missing = ledger.filter { !seenLedger.contains($0.identifier) }
                for entry in missing {
                    print("ledger card NOT FOUND: \(entry.kind) identifier=\(entry.identifier) marker=\(entry.marker)")
                }
            }
        }
    }
}
