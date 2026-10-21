import ArgumentParser
import Contacts
import Foundation

/// S4: unified-contact write semantics across a linked iCloud + Google pair.
struct S4Unified: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s4-unified",
        abstract: "S4: write semantics on a linked iCloud+Google pair; labeled-value id stability.",
        subcommands: [Create.self, Check.self])

    nonisolated(unsafe) static let keys: [any CNKeyDescriptor] = Snapshot.keys

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create an iCloud and a Google scratch card to be linked by hand in Contacts.app.")

        @OptionGroup var containerOptions: ContainerOptions

        @Flag(help: "Actually create the cards.")
        var yes = false

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let icloud = try containerOptions.resolve(.icloud, in: store)
                let google = try containerOptions.resolve(.google, in: store)
                let short = Stamp.short()
                let email = "zz-spike-s4-\(short.lowercased())@example.invalid"
                func make(_ kind: AccountKind, phone: String) -> (CNMutableContact, String) {
                    let (card, marker) = Harness.newCard(spike: "s4", kind: kind.rawValue, suffix: "Linked \(short)")
                    card.organizationName = "ZZ Spike Org"
                    card.jobTitle = "S4 baseline \(kind.rawValue)"
                    card.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
                    card.phoneNumbers = [
                        CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))
                    ]
                    return (card, marker)
                }
                let pairs = [
                    (AccountKind.icloud, icloud, make(.icloud, phone: "+1 415 555 0141")),
                    (AccountKind.google, google, make(.google, phone: "+1 415 555 0142")),
                ]
                let plan = pairs.map { kind, container, made in
                    "create \"\(Harness.displayName(made.0))\" in \(kind.rawValue) container \(container.identifier): jobTitle=\"\(made.0.jobTitle)\", phone \(made.0.phoneNumbers[0].value.stringValue), email \(email)"
                }
                guard confirmPlan("s4-unified create", plan, yes: yes) else { return }
                let writer = SafeWriter(store: store)
                for (kind, container, made) in pairs {
                    try writer.add(made.0, to: container.identifier)
                    guard let saved = try Harness.locate(store, marker: made.1) else {
                        throw SpikeError("Saved \(kind.rawValue) card but could not find it again by marker.")
                    }
                    try Ledger.append(
                        LedgerEntry(
                            spike: "s4", kind: kind.rawValue, identifier: saved.identifier, marker: made.1,
                            containerID: container.identifier, createdAt: Stamp.iso()))
                    print("created \(kind.rawValue) identifier=\(saved.identifier)")
                }
                print(
                    """

                    NEXT (manual): in Contacts.app select both "ZZ Spike S4 Linked \(short)" cards
                    (enable All Contacts so both accounts show), then Card > Link Selected Cards.
                    Then run: c2m-spike s4-unified check            (read-only report)
                              c2m-spike s4-unified check --yes      (iCloud-card write test)
                              c2m-spike s4-unified check --yes --unified-write
                    """)
            }
        }
    }

    /// Persisted between runs to check labeled-value id stability over time.
    struct State: Codable {
        var recordedAt: String
        var unifiedID: String?
        var cards: [String: CardState]  // kind -> state
        var unifiedRows: [FieldRow]
    }

    struct CardState: Codable {
        var identifier: String
        var rows: [FieldRow]
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report the unified view; with --yes write to the iCloud card (and optionally the unified copy).")

        @Flag(help: "Also save a mutable copy of the UNIFIED contact and see where values land.")
        var unifiedWrite = false

        @Flag(help: "Run the write test even if the two cards are not linked.")
        var allowUnlinked = false

        @Flag(help: "Perform the writes.")
        var yes = false

        static var stateURL: URL { get throws { try Paths.result("s4-state.json") } }

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let scan = try HarnessScan.run(store)
                let cards = try scan.harness(spike: "s4", refetchingIn: store, keys: S4Unified.keys)
                let icloudCards = cards.filter { Harness.marker($0).flatMap(Harness.kindTag) == "icloud" }
                let googleCards = cards.filter { Harness.marker($0).flatMap(Harness.kindTag) == "google" }
                guard icloudCards.count == 1, googleCards.count == 1, let icloud = icloudCards.first,
                    let google = googleCards.first
                else {
                    throw SpikeError(
                        "Expected exactly one iCloud and one Google S4 card, found \(icloudCards.count)/\(googleCards.count). Use `cleanup --spike s4 --yes` and `s4-unified create --yes`."
                    )
                }
                print("s4-unified check  \(Stamp.iso())")
                print("iCloud card \(icloud.identifier)   Google card \(google.identifier)")

                let unifiedA = try catchingObjC {
                    try store.unifiedContact(withIdentifier: icloud.identifier, keysToFetch: S4Unified.keys)
                }
                let unifiedB = try catchingObjC {
                    try store.unifiedContact(withIdentifier: google.identifier, keysToFetch: S4Unified.keys)
                }
                let linked = unifiedA.identifier == unifiedB.identifier
                print(
                    "linked: \(linked ? "YES" : "NO")  unified id via iCloud card=\(unifiedA.identifier) via Google card=\(unifiedB.identifier)"
                )
                print(
                    "unified id equals: \(unifiedA.identifier == icloud.identifier ? "iCloud card id" : unifiedA.identifier == google.identifier ? "Google card id" : "neither card id")"
                )

                let previous = try? JSONFile.read(State.self, from: try Self.stateURL)
                if let previous { compare(previous: previous, icloud: icloud, google: google, unified: unifiedA) }

                report("current unified view", unifiedA, icloud: icloud, google: google)

                var state = State(
                    recordedAt: Stamp.iso(), unifiedID: unifiedA.identifier,
                    cards: [
                        "icloud": CardState(identifier: icloud.identifier, rows: Snapshot.rows(of: icloud)),
                        "google": CardState(identifier: google.identifier, rows: Snapshot.rows(of: google)),
                    ], unifiedRows: Snapshot.rows(of: unifiedA))

                guard linked || allowUnlinked else {
                    print(
                        "\nCards are not linked yet: link them in Contacts.app (Card > Link Selected Cards), then re-run."
                    )
                    try JSONFile.write(state, to: try Self.stateURL)
                    return
                }

                let members = try memberIDs(of: unifiedA, in: store)
                let writer = SafeWriter(store: store)
                for id in members { _ = try writer.verifiedCard(id, keys: []) }  // throws if any non-harness member
                print("unified members: \(members.count) (all harness cards)")

                let stamp = Stamp.iso()
                let newPhone = "+1 415 555 01\(String(format: "%02d", Int.random(in: 50...99)))"
                var plan = [
                    "iCloud card: jobTitle -> \"S4 iCloud write \(stamp)\" (Google keeps \"\(google.jobTitle)\")",
                    "iCloud card: change existing phone in place (same labeled value) -> \(newPhone)",
                    "iCloud card: add phone labeled s4-added",
                    "re-fetch card + unified; compare labeled-value identifiers before/after save/refetch",
                ]
                if unifiedWrite {
                    plan.append(
                        "unified mutable copy: add email label s4-unified, jobTitle -> \"S4 unified write\"; see which card receives them"
                    )
                }
                guard confirmPlan("s4-unified check writes", plan, yes: yes) else {
                    try JSONFile.write(state, to: try Self.stateURL)
                    return
                }

                // Write A: iCloud underlying card.
                let beforeIDs = icloud.phoneNumbers.map(\.identifier)
                let saved = try writer.update(icloud.identifier, keys: S4Unified.keys) { card in
                    card.jobTitle = "S4 iCloud write \(stamp)"
                    if let first = card.phoneNumbers.first {
                        card.phoneNumbers[0] = first.settingValue(CNPhoneNumber(stringValue: newPhone))
                    }
                    card.phoneNumbers.append(
                        CNLabeledValue(label: "s4-added", value: CNPhoneNumber(stringValue: "+1 415 555 0149")))
                }
                let inMemoryIDs = saved.phoneNumbers.map(\.identifier)
                let refetched = try writer.verifiedCard(icloud.identifier, keys: S4Unified.keys)
                let refetchedIDs = refetched.phoneNumbers.map(\.identifier)
                print("\n## Write A (iCloud card)")
                print("phone lv ids before save:      \(beforeIDs)")
                print("phone lv ids in saved object:  \(inMemoryIDs)")
                print("phone lv ids after refetch:    \(refetchedIDs)")
                print("edited-in-place id stable: \(beforeIDs.first.map { refetchedIDs.contains($0) } ?? false)")
                print(
                    "added value id kept after refetch: \(inMemoryIDs.last.map { refetchedIDs.contains($0) } ?? false)")
                let unifiedAfter = try catchingObjC {
                    try store.unifiedContact(withIdentifier: icloud.identifier, keysToFetch: S4Unified.keys)
                }
                let googleNow = try writer.verifiedCard(google.identifier, keys: S4Unified.keys)
                print(
                    "unified jobTitle now: \"\(unifiedAfter.jobTitle)\" -> shows \(origin(unifiedAfter.jobTitle, icloud: refetched.jobTitle, google: googleNow.jobTitle))"
                )
                report("unified view after write A", unifiedAfter, icloud: refetched, google: googleNow)

                // Write B: mutable copy of the unified contact.
                if unifiedWrite {
                    print("\n## Write B (mutable copy of unified contact)")
                    guard let mutable = unifiedAfter.mutableCopy() as? CNMutableContact else {
                        throw SpikeError("mutableCopy failed")
                    }
                    let email = "zz-spike-s4-unified-\(Stamp.short().lowercased())@example.invalid"
                    mutable.emailAddresses.append(CNLabeledValue(label: "s4-unified", value: email as NSString))
                    mutable.jobTitle = "S4 unified write \(stamp)"
                    do {
                        try writer.updateUnified(mutable, memberIDs: members)
                        let ic = try writer.verifiedCard(icloud.identifier, keys: S4Unified.keys)
                        let gg = try writer.verifiedCard(google.identifier, keys: S4Unified.keys)
                        let has = { (c: CNContact) in c.emailAddresses.contains { ($0.value as String) == email } }
                        print("new email landed on: iCloud=\(has(ic)) Google=\(has(gg))")
                        print("jobTitle: iCloud=\"\(ic.jobTitle)\" Google=\"\(gg.jobTitle)\"")
                        let u = try catchingObjC {
                            try store.unifiedContact(withIdentifier: icloud.identifier, keysToFetch: S4Unified.keys)
                        }
                        print(
                            "unified jobTitle: \"\(u.jobTitle)\" -> shows \(origin(u.jobTitle, icloud: ic.jobTitle, google: gg.jobTitle))"
                        )
                        report("unified view after write B", u, icloud: ic, google: gg)
                        state.cards["icloud"] = CardState(identifier: ic.identifier, rows: Snapshot.rows(of: ic))
                        state.cards["google"] = CardState(identifier: gg.identifier, rows: Snapshot.rows(of: gg))
                        state.unifiedRows = Snapshot.rows(of: u)
                    } catch {
                        print("unified save FAILED: \(describe(error))")
                    }
                } else {
                    state.cards["icloud"] = CardState(
                        identifier: refetched.identifier, rows: Snapshot.rows(of: refetched))
                    state.cards["google"] = CardState(
                        identifier: googleNow.identifier, rows: Snapshot.rows(of: googleNow))
                    state.unifiedRows = Snapshot.rows(of: unifiedAfter)
                }
                state.unifiedID = unifiedAfter.identifier
                try JSONFile.write(state, to: try Self.stateURL)
                print(
                    "\nstate saved -> \(try Self.stateURL.path). Re-run `s4-unified check` (no --yes) after iCloud/Google round-trip to compare ids."
                )
            }
        }

        private func origin(_ value: String, icloud: String, google: String) -> String {
            switch value {
            case icloud where icloud == google: return "both (equal)"
            case icloud: return "iCloud card value"
            case google: return "Google card value"
            default: return "neither card's value"
            }
        }

        private func report(_ title: String, _ unified: CNContact, icloud: CNContact, google: CNContact) {
            let icloudRows = Snapshot.rows(of: icloud)
            let googleRows = Snapshot.rows(of: google)
            var table = MarkdownTable(headers: ["field", "label", "value", "lv id", "id found on"])
            for row in Snapshot.rows(of: unified)
            where ["jobTitle", "organization", "phone", "email", "url"].contains(row.field) {
                var on: [String] = []
                if row.key != "-" {
                    if icloudRows.contains(where: { $0.key == row.key }) { on.append("iCloud") }
                    if googleRows.contains(where: { $0.key == row.key }) { on.append("Google") }
                }
                table.rows.append([
                    row.field, row.label ?? "", row.value, row.key, on.isEmpty ? "-" : on.joined(separator: "+"),
                ])
            }
            print("\n### \(title)")
            print(table.render())
        }

        private func compare(previous: State, icloud: CNContact, google: CNContact, unified: CNContact) {
            print("\n## Compared with previous run (\(previous.recordedAt))")
            print(
                "unified id: \(previous.unifiedID == unified.identifier ? "same" : "CHANGED (\(previous.unifiedID ?? "nil") -> \(unified.identifier))")"
            )
            for (kind, card) in [("icloud", icloud), ("google", google)] {
                guard let old = previous.cards[kind] else { continue }
                let now = Snapshot.rows(of: card)
                let oldIDs = Set(old.rows.map(\.key).filter { $0 != "-" })
                let newIDs = Set(now.map(\.key).filter { $0 != "-" })
                print(
                    "\(kind): card id \(old.identifier == card.identifier ? "same" : "CHANGED"); lv ids kept \(oldIDs.intersection(newIDs).count)/\(oldIDs.count), new \(newIDs.subtracting(oldIDs).count)"
                )
                for diff in RowDiff.align(old.rows, now) where diff.changed {
                    print(
                        "  \(diff.field): \(diff.before?.value ?? "∅") -> \(diff.after?.value ?? "∅") (id \(diff.idStable))"
                    )
                }
            }
            let oldU = Set(previous.unifiedRows.map(\.key).filter { $0 != "-" })
            let newU = Set(Snapshot.rows(of: unified).map(\.key).filter { $0 != "-" })
            print("unified lv ids kept \(oldU.intersection(newU).count)/\(oldU.count)")
        }
    }
}
