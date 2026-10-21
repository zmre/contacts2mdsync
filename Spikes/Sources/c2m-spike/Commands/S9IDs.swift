import ArgumentParser
import Contacts
import Foundation

/// S9: identifier stability across link/unlink and iCloud sign-out/in.
/// Stores SHA-256 of identifiers only; no names.
struct S9IDs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s9-ids",
        abstract: "S9: record hashed contact identifiers + unified mapping; compare later for churn.",
        subcommands: [Record.self, Compare.self])

    struct Snapshot9: Codable {
        struct Card: Codable {
            var id: String  // sha256(identifier)
            var container: String  // sha256(container identifier)
            var unified: String?  // sha256(unified identifier)
            var harnessMarker: String?  // our own scratch marker, if a harness card
        }
        var recordedAt: String
        var containerCount: Int
        var unifiedFetchCount: Int
        var cards: [Card]
    }

    static func capture(_ store: CNContactStore) throws -> Snapshot9 {
        let containers = try store.containers(matching: nil)
        let map = try UnifiedMap.build(store, containers: containers)
        let scan = try HarnessScan.run(store)
        var markers: [String: String] = [:]
        for card in scan.harness { markers[card.identifier] = Harness.marker(card) }
        return Snapshot9(
            recordedAt: Stamp.iso(), containerCount: containers.count, unifiedFetchCount: map.unifiedFetchCount,
            cards: map.cards.map {
                .init(
                    id: sha256Hex($0.id), container: sha256Hex($0.containerID), unified: $0.unifiedID.map(sha256Hex),
                    harnessMarker: markers[$0.id])
            })
    }

    struct Record: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write Spikes/results/ids-<date>.json (hashes only).")

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let snap = try S9IDs.capture(store)
                let url = try Paths.result("ids-\(Stamp.file()).json")
                try JSONFile.write(snap, to: url)
                print(
                    "recorded \(snap.cards.count) cards, \(Set(snap.cards.compactMap(\.unified)).count) unified, \(snap.containerCount) containers -> \(url.path)"
                )
            }
        }
    }

    struct Compare: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare live identifiers against a recorded ids-*.json.")

        @Option(help: "Baseline file. Default: the newest Spikes/results/ids-*.json.")
        var baseline: String?

        func run() throws {
            try runReporting {
                let url: URL
                if let baseline {
                    url = URL(fileURLWithPath: baseline)
                } else {
                    let dir = Paths.results
                    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    guard let newest = files.filter({ $0.hasPrefix("ids-") && $0.hasSuffix(".json") }).sorted().last
                    else {
                        throw SpikeError("No ids-*.json in \(dir.path). Run `s9-ids record` first.")
                    }
                    url = dir.appendingPathComponent(newest)
                }
                let old = try JSONFile.read(Snapshot9.self, from: url)
                let store = try Access.authorizedStore()
                let now = try S9IDs.capture(store)
                print(
                    "s9-ids compare  baseline \(url.lastPathComponent) (\(old.recordedAt)) vs now (\(now.recordedAt))")

                func churn(_ name: String, _ a: Set<String>, _ b: Set<String>) {
                    print(
                        "\(name): before \(a.count), now \(b.count), kept \(a.intersection(b).count), gone \(a.subtracting(b).count), new \(b.subtracting(a).count)"
                    )
                }
                churn("underlying card ids", Set(old.cards.map(\.id)), Set(now.cards.map(\.id)))
                churn("unified ids        ", Set(old.cards.compactMap(\.unified)), Set(now.cards.compactMap(\.unified)))
                churn("container ids      ", Set(old.cards.map(\.container)), Set(now.cards.map(\.container)))
                print("unified fetch count: \(old.unifiedFetchCount) -> \(now.unifiedFetchCount)")

                let oldByID = Dictionary(old.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                var remapped = 0
                var movedContainer = 0
                for card in now.cards {
                    guard let before = oldByID[card.id] else { continue }
                    if before.unified != card.unified { remapped += 1 }
                    if before.container != card.container { movedContainer += 1 }
                }
                print("kept cards whose unified id changed: \(remapped)")
                print("kept cards whose container changed:  \(movedContainer)")

                // Harness cards: same marker, did the identifier survive?
                let oldByMarker = Dictionary(
                    old.cards.compactMap { c in c.harnessMarker.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
                let nowByMarker = Dictionary(
                    now.cards.compactMap { c in c.harnessMarker.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
                if !oldByMarker.isEmpty || !nowByMarker.isEmpty {
                    print("\nharness cards (by marker):")
                    for marker in Set(oldByMarker.keys).union(nowByMarker.keys).sorted() {
                        let a = oldByMarker[marker]
                        let b = nowByMarker[marker]
                        let status: String
                        switch (a, b) {
                        case (let a?, let b?):
                            status =
                                "card id \(a.id == b.id ? "same" : "CHANGED"), unified id \(a.unified == b.unified ? "same" : "CHANGED")"
                        case (nil, _?): status = "new since baseline"
                        case (_?, nil): status = "gone (or marker stripped)"
                        default: status = "?"
                        }
                        print("  \(marker): \(status)")
                    }
                }
            }
        }
    }
}
