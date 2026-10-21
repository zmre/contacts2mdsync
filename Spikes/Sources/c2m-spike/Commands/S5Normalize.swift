import ArgumentParser
import Contacts
import Foundation

/// S5: catalog of tricky values written to iCloud and Google scratch cards,
/// compared after a server round-trip.
struct S5Normalize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s5-normalize",
        abstract: "S5: server normalization catalog (phones, addresses, URLs, labels, yearless birthday, image).",
        subcommands: [Create.self, Check.self])

    struct Before: Codable {
        var createdAt: String
        var cards: [String: Card]  // kind -> card
    }

    struct Card: Codable {
        var identifier: String
        var marker: String
        var written: [FieldRow]
        var localRefetch: [FieldRow]
    }

    static var beforeURL: URL { get throws { try Paths.result("s5-before.json") } }

    /// Fills `card` with the catalog. Phone numbers use the 555-01xx fictional range.
    static func fillCatalog(_ card: CNMutableContact, image: Data) {
        card.namePrefix = "Dr."
        card.middleName = "Q."
        card.nameSuffix = "Jr."
        card.nickname = "Spikey"
        card.phoneticGivenName = "zee zee"
        card.organizationName = "ZZ Spike Normalization GmbH & Co."
        card.departmentName = "R&D / QA"
        card.jobTitle = "Chief Échec Officer"
        func phone(_ label: String?, _ value: String) -> CNLabeledValue<CNPhoneNumber> {
            CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: value))
        }
        card.phoneNumbers = [
            phone(CNLabelPhoneNumberMobile, "4155550100"),
            phone(CNLabelHome, "(415) 555-0101"),
            phone(CNLabelWork, "+1 415 555 0102"),
            phone(CNLabelPhoneNumberiPhone, "+14155550103"),
            phone(CNLabelPhoneNumberMain, "415.555.0104"),
            phone(CNLabelPhoneNumberHomeFax, "1-415-555-0105"),
            phone(CNLabelOther, "555-0106 ext. 12"),
            phone(CNLabelPhoneNumberPager, "+1 (415) 555-0107;ext=3"),
            phone("spike custom label", "+44 20 7946 0958"),
            phone("Spike-Custom-Case", "011 33 1 23 45 67 89"),
            phone(nil, "+49 30 901820"),
        ]
        card.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "Zz.Spike.S5@Example.INVALID" as NSString),
            CNLabeledValue(label: "Spike Label With Spaces", value: "zz-spike-s5+tag@example.invalid" as NSString),
        ]
        card.urlAddresses += [
            CNLabeledValue(label: CNLabelURLAddressHomePage, value: "example.com" as NSString),
            CNLabeledValue(label: CNLabelWork, value: "HTTP://Example.COM/Path?q=1&r=2#frag" as NSString),
            CNLabeledValue(label: "x-custom", value: "https://example.com/" as NSString),
            CNLabeledValue(label: "c2mdsync", value: "x-c2mdsync:00000000-0000-4000-8000-000000000005" as NSString),
        ]
        func address(_ configure: (CNMutablePostalAddress) -> Void) -> CNPostalAddress {
            let a = CNMutablePostalAddress()
            configure(a)
            return a.copy() as! CNPostalAddress
        }
        card.postalAddresses = [
            CNLabeledValue(
                label: CNLabelHome,
                value: address {
                    $0.street = "1 Infinite Loop\nApt 5"
                    $0.city = "Cupertino"
                    $0.state = "ca"
                    $0.postalCode = "95014"
                    $0.country = "United States"
                    $0.isoCountryCode = "us"
                }),
            CNLabeledValue(
                label: CNLabelWork,
                value: address {
                    $0.street = "Unter den Linden 77"
                    $0.city = "Berlin"
                    $0.postalCode = "10117"
                    $0.country = "Germany"
                    $0.isoCountryCode = "de"
                }),
            CNLabeledValue(label: "spike city only", value: address { $0.city = "Boulder" }),
            CNLabeledValue(
                label: CNLabelOther,
                value: address {
                    $0.street = "Flat 2, 10 Downing St"
                    $0.subLocality = "Westminster"
                    $0.city = "London"
                    $0.subAdministrativeArea = "Greater London"
                    $0.postalCode = "sw1a 2aa"
                    $0.country = "UK"
                }),
        ]
        card.birthday = DateComponents(month: 2, day: 29)  // yearless + leap day
        card.dates = [
            CNLabeledValue(
                label: CNLabelDateAnniversary, value: DateComponents(year: 2001, month: 6, day: 15) as NSDateComponents),
            CNLabeledValue(label: "spike yearless", value: DateComponents(month: 12, day: 25) as NSDateComponents),
        ]
        card.socialProfiles = [
            CNLabeledValue(
                label: nil,
                value: CNSocialProfile(
                    urlString: "https://mastodon.example/@zzspike", username: "zzspike", userIdentifier: nil,
                    service: "Mastodon")),
            CNLabeledValue(
                label: nil,
                value: CNSocialProfile(
                    urlString: nil, username: "zzspike", userIdentifier: nil, service: CNSocialProfileServiceTwitter)),
        ]
        card.instantMessageAddresses = [
            CNLabeledValue(label: CNLabelHome, value: CNInstantMessageAddress(username: "zzspike", service: "Signal"))
        ]
        card.contactRelations = [
            CNLabeledValue(label: CNLabelContactRelationMother, value: CNContactRelation(name: "ZZ Spike Mother")),
            CNLabeledValue(label: "spike mentor", value: CNContactRelation(name: "ZZ Spike Mentor")),
        ]
        card.imageData = image
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write the catalog to new iCloud and Google scratch cards.")

        @OptionGroup var containerOptions: ContainerOptions

        @Option(help: "Accounts to target (repeatable). Default: icloud and google.")
        var account: [AccountKind] = [.icloud, .google]

        @Flag(help: "Actually create the cards.")
        var yes = false

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let image = try Snapshot.makeTestPNG()
                let short = Stamp.short()
                var targets: [(AccountKind, CNContainer, CNMutableContact, String)] = []
                for kind in account {
                    let container = try containerOptions.resolve(kind, in: store)
                    let (card, marker) = Harness.newCard(
                        spike: "s5", kind: kind.rawValue, suffix: "\(kind.rawValue) \(short)")
                    S5Normalize.fillCatalog(card, image: image)
                    targets.append((kind, container, card, marker))
                }
                var plan = targets.map {
                    "create \"\(Harness.displayName($0.2))\" in \($0.0.rawValue) container \($0.1.identifier) with \(Snapshot.rows(of: $0.2).count) catalog values"
                }
                plan.append("write \(try S5Normalize.beforeURL.path) (written + immediate local refetch)")
                guard confirmPlan("s5-normalize create", plan, yes: yes) else { return }

                var before = Before(createdAt: Stamp.iso(), cards: [:])
                let writer = SafeWriter(store: store)
                for (kind, container, card, marker) in targets {
                    let written = Snapshot.rows(of: card)
                    try writer.add(card, to: container.identifier)
                    guard let located = try Harness.locate(store, marker: marker) else {
                        throw SpikeError("Saved \(kind.rawValue) card but could not find it again by marker.")
                    }
                    let local = try writer.verifiedCard(located.identifier, keys: Snapshot.keys)
                    before.cards[kind.rawValue] = Card(
                        identifier: located.identifier, marker: marker, written: written,
                        localRefetch: Snapshot.rows(of: local))
                    try Ledger.append(
                        LedgerEntry(
                            spike: "s5", kind: kind.rawValue, identifier: located.identifier, marker: marker,
                            containerID: container.identifier, createdAt: Stamp.iso()))
                    print("created \(kind.rawValue) identifier=\(located.identifier)")
                }
                try JSONFile.write(before, to: try S5Normalize.beforeURL)
                print(
                    "Next: wait for the server round-trip (5-15 min; open contacts.google.com / iCloud.com to force),")
                print("then run `c2m-spike s5-normalize check`.")
            }
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only: diff written vs local vs now; markdown to stdout and Spikes/results/s5-<date>.md.")

        @Flag(help: "Show unchanged rows too.")
        var all = false

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let url = try S5Normalize.beforeURL
                guard let before = try? JSONFile.read(Before.self, from: url) else {
                    throw SpikeError("No \(url.path). Run `s5-normalize create --yes` first.")
                }
                var markdown = "# S5 normalization catalog\n\ncreated \(before.createdAt), checked \(Stamp.iso())\n"
                for (kind, card) in before.cards.sorted(by: { $0.key < $1.key }) {
                    markdown += "\n## \(kind)\n\n"
                    let now: CNContact?
                    do {
                        // Read-only fetch; tolerate a stripped marker (that is itself a result).
                        now = try fetchUnderlying(store, id: card.identifier, keys: Snapshot.keys)
                        if now == nil {
                            markdown += "card \(card.identifier) NOT FOUND (deleted or identifier changed)\n"
                        }
                    } catch {
                        markdown += "card \(card.identifier) not fetchable: \(describe(error))\n"
                        now = nil
                    }
                    let nowRows = now.map(Snapshot.rows(of:)) ?? []
                    let localByKey = Dictionary(
                        card.localRefetch.map { ("\($0.field)|\($0.key)", $0) }, uniquingKeysWith: { a, _ in a })
                    var table = MarkdownTable(
                        headers: [
                            "field", "label written", "label now", "value written", "value local refetch", "value now",
                            "lv id", "changed",
                        ])
                    var changedCount = 0
                    for diff in RowDiff.align(card.written, nowRows) {
                        if diff.changed { changedCount += 1 }
                        guard all || diff.changed else { continue }
                        let local = diff.before.flatMap { localByKey["\($0.field)|\($0.key)"] }
                        table.rows.append([
                            diff.field, diff.before?.label ?? "", diff.after?.label ?? "",
                            diff.before?.value ?? "∅", local?.value ?? "∅", diff.after?.value ?? "∅",
                            diff.idStable, diff.changed ? "YES" : "",
                        ])
                    }
                    markdown +=
                        "card \(card.identifier): \(changedCount) of \(card.written.count) written values differ now\n\n"
                    markdown += table.render() + "\n"
                }
                print(markdown)
                let out = try Paths.result("s5-\(Stamp.file()).md")
                try markdown.write(to: out, atomically: true, encoding: .utf8)
                print("written -> \(out.path)")
            }
        }
    }
}
