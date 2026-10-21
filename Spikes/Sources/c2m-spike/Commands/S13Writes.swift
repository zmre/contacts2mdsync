import ArgumentParser
import ContactModel
import Contacts
import ContactsAdapter
import Foundation
import SpikeShim

/// S13: the real M3 Apple write path (`CNContactStoreAdapter.apply` →
/// `CardWriter`) against the real Contacts store, on harness scratch cards
/// only. Every batch goes through `HarnessGuardedStore`, which re-fetches each
/// target card (`unifyResults = false`) and refuses the whole batch unless all
/// of them are S13 harness cards.
///
/// The batches are built here by hand following architecture §6 ("Stamping
/// and write targets"): additions to the iCloud card, edits/deletes on every
/// card holding the value, single-valued fields on every card that has one.
/// `AppleWritePlanner` (which normally builds them) is internal to SyncEngine
/// and is covered by the kit's unit tests; S13 checks that `CardWriter`
/// executes those operations correctly against the real store and servers.
struct S13Writes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s13-writes",
        abstract: "S13: exercise the real Contacts2MdSyncKit write path (ContactStore.apply) on scratch cards only.",
        discussion: """
            setup --yes   create a linked iCloud+Google pair, an iCloud-only and a Google-only scratch card
            run --yes     ~15 min later: scripted write sequence through CNContactStoreAdapter.apply, \
            pass/fail table, Spikes/results/s13-<date>.md
            check         15–30 min after run: read-only server round-trip check
            Clean up with: c2m-spike cleanup --spike s13 --yes (also deletes "ZZ Spike S13 Group").
            """,
        subcommands: [Setup.self, Run.self, Check.self])

    static let spike = "s13"
    static let groupName = "ZZ Spike S13 Group"
    /// Same shape as the engine's author (`SyncEngine.transactionAuthorPrefix`
    /// + device id). Spelled out so the harness needs only ContactModel and
    /// ContactsAdapter from the kit, not the (larger, faster-moving) engine.
    static let author = "com.zmre.contacts2mdsync.spike-s13"

    static var setupURL: URL { get throws { try Paths.result("s13-setup.json") } }
    static var stateURL: URL { get throws { try Paths.result("s13-state.json") } }

    /// Keys for card re-fetches: every field the writer touches (no note, no image).
    static func cardKeys() -> [any CNKeyDescriptor] { AppleContactMapper.cardKeys(includeNote: false) }

    static func unifiedKeys() -> [any CNKeyDescriptor] {
        [CNContactIdentifierKey, CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey]
            .map { $0 as NSString }
    }

    static func loadSetup() throws -> S13Setup {
        let url = try setupURL
        guard let setup = try? JSONFile.read(S13Setup.self, from: url) else {
            throw SpikeError("No S13 setup at \(url.path). Run `c2m-spike s13-writes setup --yes` first.")
        }
        return setup
    }

    // MARK: - setup

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create the S13 scratch cards through the real write path (CardWriter creates).")

        @OptionGroup var containerOptions: ContainerOptions

        @Flag(help: "Actually create the cards.")
        var yes = false

        func run() throws {
            try runReporting {
                print("c2m-spike s13-writes setup  \(Stamp.iso())")
                let store = try Access.authorizedStore()
                let scan = try HarnessScan.run(store)
                let existing = scan.harness(spike: S13Writes.spike)
                if !existing.isEmpty {
                    throw SpikeError(
                        """
                        \(existing.count) S13 scratch card(s) already exist. Use `c2m-spike s13-writes run`, or start \
                        over with `c2m-spike cleanup --spike s13 --yes`.
                        """)
                }
                let icloud = try containerOptions.resolve(.icloud, in: store)
                let google = try containerOptions.resolve(.google, in: store)
                let short = Stamp.short()
                let lower = short.lowercased()
                let sharedEmail = "zz-spike-s13-\(lower)@example.invalid"
                let sharedPhone = "+1 415-555-0113"

                var specs: [CardSpec] = [
                    CardSpec(
                        role: .linkedICloud, container: icloud.identifier, family: "S13 Linked \(short)",
                        jobTitle: "S13 baseline icloud", emails: [("work", sharedEmail)],
                        phones: [("mobile", sharedPhone), ("home", "+1 415-555-0114")],
                        relations: [("ZZ Spike S13 Assistant", "assistant")]),
                    CardSpec(
                        role: .linkedGoogle, container: google.identifier, family: "S13 Linked \(short)",
                        jobTitle: "S13 baseline google", emails: [("work", sharedEmail)],
                        phones: [("mobile", sharedPhone), ("work", "+1 415-555-0115")], relations: []),
                    CardSpec(
                        role: .soloICloud, container: icloud.identifier, family: "S13 iCloud \(short)",
                        jobTitle: "S13 baseline", emails: [("work", "zz-spike-s13-\(lower)-icloud@example.invalid")],
                        phones: [], relations: []),
                    CardSpec(
                        role: .soloGoogle, container: google.identifier, family: "S13 Google \(short)",
                        jobTitle: "S13 baseline", emails: [("work", "zz-spike-s13-\(lower)-google@example.invalid")],
                        phones: [("mobile", "+1 415-555-0116")], relations: []),
                ]
                for index in specs.indices {
                    specs[index].marker = Harness.makeMarker(spike: S13Writes.spike, kind: specs[index].role.rawValue)
                }
                let plan =
                    specs.map {
                        "create \"\(Harness.givenName) \($0.family)\" (\($0.role.title)) in container \($0.container)"
                    } + [
                        "all four creates go through the real CNContactStoreAdapter.apply (CardWriter .create), wrapped "
                            + "by the harness guard",
                        "the linked pair shares name + email \(sharedEmail) so Contacts links it automatically",
                    ]
                guard confirmPlan("s13-writes setup", plan, yes: yes) else { return }

                let guarded = HarnessGuardedStore(
                    spike: S13Writes.spike, allowedGroupNames: [S13Writes.groupName], log: ApplyLog())
                var records: [UUID: CardSpec] = [:]
                var operations: [AppleWriteOperation] = []
                for spec in specs {
                    let recordID = UUID()
                    records[recordID] = spec
                    operations.append(.create(spec.newContact(recordID: recordID)))
                }
                let result = try guarded.apply(AppleWriteBatch(operations: operations), author: S13Writes.author)
                for failure in result.failed {
                    print("FAILED: \(HarnessBatchGuard.describe(failure.operation)): \(failure.message)")
                }
                var markers: [String: String] = [:]
                for (recordID, spec) in records.sorted(by: { $0.value.role.order < $1.value.role.order }) {
                    markers[spec.role.rawValue] = spec.marker
                    guard let createdID = result.createdCardIDs[recordID] else {
                        print("\(spec.role.title): not created")
                        continue
                    }
                    let located = try Harness.locate(store, marker: spec.marker)
                    print(
                        "\(spec.role.title): created id=\(createdID)  located by marker: \(located?.identifier ?? "NOT FOUND")"
                    )
                    try Ledger.append(
                        LedgerEntry(
                            spike: S13Writes.spike, kind: spec.role.rawValue,
                            identifier: located?.identifier ?? createdID, marker: spec.marker,
                            containerID: spec.container, createdAt: Stamp.iso()))
                }
                let setup = S13Setup(
                    short: short, createdAt: Stamp.iso(), markers: markers, sharedEmail: sharedEmail,
                    sharedPhone: sharedPhone, icloudContainer: icloud.identifier, googleContainer: google.identifier)
                try JSONFile.write(setup, to: try S13Writes.setupURL)
                print("saved \(try S13Writes.setupURL.path)")
                print(
                    """

                    NEXT: wait about 15 minutes. Contacts should link the "ZZ Spike S13 Linked \(short)" pair by itself, \
                    and Google sync usually replaces the new Google cards (their ids change once; S13 finds them by \
                    marker). Then:
                      c2m-spike s13-writes run          (dry run: shows whether the pair is linked)
                      c2m-spike s13-writes run --yes
                    """)
            }
        }
    }

    // MARK: - run

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scripted write sequence through the real write path; pass/fail table + results file.")

        @Flag(help: "Run even if the S13 pair is not linked yet (unified-display checks become INFO).")
        var allowUnlinked = false

        @Flag(help: "Actually write.")
        var yes = false

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let setup = try S13Writes.loadSetup()
                var runner = try S13Runner(store: store, setup: setup)
                try runner.preflight(allowUnlinked: allowUnlinked)
                guard confirmPlan("s13-writes run", S13Runner.planSteps, yes: yes) else { return }
                do {
                    try runner.runAll()
                } catch {
                    // Keep the evidence: write what ran so far, then stop.
                    runner.report.say("\nABORTED: \(describe(error))")
                    runner.report.say(runner.report.table.render())
                    if let url = try? runner.report.write(
                        "s13-\(Stamp.file())-aborted.md", title: "S13 run (aborted) \(Stamp.iso())")
                    {
                        print("wrote \(url.path)")
                    }
                    throw error
                }
            }
        }
    }

    // MARK: - check

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only: did the values written by `run` survive the server round trip?")

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let setup = try S13Writes.loadSetup()
                try S13Checker(store: store, setup: setup).run()
            }
        }
    }
}

// MARK: - Model

enum S13Role: String, Codable, CaseIterable {
    case linkedICloud = "linked-icloud"
    case linkedGoogle = "linked-google"
    case soloICloud = "icloud"
    case soloGoogle = "google"

    var title: String {
        switch self {
        case .linkedICloud: "linked iCloud card"
        case .linkedGoogle: "linked Google card"
        case .soloICloud: "iCloud-only card"
        case .soloGoogle: "Google-only card"
        }
    }

    var short: String {
        switch self {
        case .linkedICloud: "L-iCloud"
        case .linkedGoogle: "L-Google"
        case .soloICloud: "iCloud-only"
        case .soloGoogle: "Google-only"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct S13Setup: Codable {
    var short: String
    var createdAt: String
    /// Role raw value → marker URL.
    var markers: [String: String]
    var sharedEmail: String
    var sharedPhone: String
    var icloudContainer: String
    var googleContainer: String

    func marker(_ role: S13Role) throws -> String {
        guard let marker = markers[role.rawValue] else { throw SpikeError("s13-setup.json has no \(role.rawValue) marker.") }
        return marker
    }
}

/// One scratch card to create in `setup`.
struct CardSpec {
    var role: S13Role
    var container: String
    var family: String
    var jobTitle: String
    var emails: [(label: String, value: String)]
    var phones: [(label: String, value: String)]
    var relations: [(name: String, type: String)]
    var marker = ""

    func newContact(recordID: UUID) -> NewAppleContact {
        func text(_ list: [(label: String, value: String)]) -> [AppleListElement] {
            list.map { AppleListElement(label: $0.label, value: .text($0.value)) }
        }
        var edits: [CardEdit] = [
            .scalar(.givenName, Harness.givenName),
            .scalar(.familyName, family),
            .scalar(.jobTitle, jobTitle),
            .list(.urls, [AppleListElement(label: Harness.markerLabel, value: .text(marker))]),
        ]
        if !emails.isEmpty { edits.append(.list(.emails, text(emails))) }
        if !phones.isEmpty { edits.append(.list(.phones, text(phones))) }
        if !relations.isEmpty {
            edits.append(
                .list(
                    .relations,
                    relations.map {
                        AppleListElement(label: nil, value: .relation(name: $0.name, type: $0.type, label: nil))
                    }))
        }
        return NewAppleContact(recordID: recordID, containerID: container, kind: .person, edits: edits)
    }
}

/// A labeled value as seen on one card (label, value text, labeled-value id).
struct S13Value: Codable, Hashable {
    var label: String?
    var value: String
    var id: String
}

/// Read-only views of a fetched card (keys from `S13Writes.cardKeys()`).
enum S13View {
    static func emails(_ card: CNContact) -> [S13Value] {
        card.emailAddresses.map { S13Value(label: $0.label, value: $0.value as String, id: $0.identifier) }
    }

    static func phones(_ card: CNContact) -> [S13Value] {
        card.phoneNumbers.map { S13Value(label: $0.label, value: $0.value.stringValue, id: $0.identifier) }
    }

    static func urls(_ card: CNContact) -> [S13Value] {
        card.urlAddresses.map { S13Value(label: $0.label, value: $0.value as String, id: $0.identifier) }
    }

    static func relations(_ card: CNContact) -> [S13Value] {
        card.contactRelations.map { S13Value(label: $0.label, value: $0.value.name, id: $0.identifier) }
    }

    static func emailKey(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Last 10 digits: ignores formatting and a +1 prefix added by a server.
    static func phoneKey(_ text: String) -> String { String(text.filter(\.isNumber).suffix(10)) }

    static func stamp(_ card: CNContact) -> S13Value? {
        urls(card).first { SyncStamp.isStamp($0.value) }
    }

    /// Kept elements for every current value of a text list (identifiers kept by CardWriter).
    static func kept(_ list: [Labeled<String>]) -> [AppleListElement] {
        list.map { AppleListElement(existing: .text($0.value), existingLabel: $0.label, label: $0.label, value: .text($0.value)) }
    }

    static func keptRelations(_ list: [RelationshipRef]) -> [AppleListElement] {
        list.compactMap { ref in
            ref.target?.displayName.map { name in
                let value = AppleValue.relation(name: name, type: ref.type, label: ref.label)
                return AppleListElement(existing: value, label: nil, value: value)
            }
        }
    }
}

/// PASS/FAIL table shared by `run` and `check`; also the markdown results file.
final class S13Report {
    enum Outcome: String {
        case pass = "PASS"
        case fail = "FAIL"
        case warn = "WARN"
        case info = "INFO"
        case skip = "SKIP"
    }

    var log: [String] = []
    var table = MarkdownTable(headers: ["Step", "Check", "Result", "Detail"])
    var counts: [Outcome: Int] = [:]

    func say(_ line: String = "") {
        print(line)
        log.append(line)
    }

    func check(_ step: String, _ name: String, _ outcome: Outcome, _ detail: String = "") {
        counts[outcome, default: 0] += 1
        table.rows.append([step, name, outcome.rawValue, detail])
        say("  [\(outcome.rawValue)] \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    func check(_ step: String, _ name: String, _ ok: Bool, _ detail: String = "") {
        check(step, name, ok ? .pass : .fail, detail)
    }

    var summary: String {
        [S13Report.Outcome.pass, .fail, .warn, .info, .skip].map { "\($0.rawValue) \(counts[$0] ?? 0)" }
            .joined(separator: "  ")
    }

    func write(_ name: String, title: String) throws -> URL {
        let url = try Paths.result(name)
        let text = """
            # \(title)

            \(summary)

            \(table.render())

            ## Log

            ```text
            \(log.joined(separator: "\n"))
            ```

            """
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Locating cards

enum S13Locate {
    /// Finds each role's card by its marker (one identity-key scan), then
    /// re-fetches it with `keys`. Missing roles are absent from the result.
    static func cards(
        _ store: CNContactStore, setup: S13Setup, keys: [any CNKeyDescriptor]
    ) throws -> [S13Role: CNContact] {
        let wanted = Dictionary(uniqueKeysWithValues: S13Role.allCases.compactMap { role in
            setup.markers[role.rawValue].map { ($0, role) }
        })
        var ids: [S13Role: String] = [:]
        let request = CNContactFetchRequest(keysToFetch: Harness.identityKeys)
        request.unifyResults = false
        try catchingObjC {
            try store.enumerateContacts(with: request) { contact, _ in
                guard Harness.isHarness(contact) else { return }
                for url in contact.urlAddresses {
                    if let role = wanted[url.value as String] { ids[role] = contact.identifier }
                }
            }
        }
        var result: [S13Role: CNContact] = [:]
        for (role, id) in ids {
            if let card = try fetchUnderlying(store, id: id, keys: keys), Harness.isHarness(card) { result[role] = card }
        }
        return result
    }
}

// MARK: - run

struct S13Runner {
    let store: CNContactStore
    let setup: S13Setup
    let guarded: HarnessGuardedStore
    let report = S13Report()
    let author = S13Writes.author
    var ids: [S13Role: String] = [:]
    var linked = false
    var histories: [(step: String, history: StepHistory)] = []
    var groupID: String?
    var stamps: [S13Role: UUID] = [:]

    static let planSteps = [
        "0  guard self-test: batches with an unknown card id, a marker-removing URL edit, and a non-harness create "
            + "must be refused before anything is saved",
        "1  add an email to the linked contact → iCloud card only",
        "2  edit the shared email (on both linked cards) → edited on both, labeled-value ids kept",
        "3  change jobTitle → written to both linked cards, per-card verify, unified shows it",
        "4  delete the shared phone → removed from both linked cards",
        "5  stamp x-c2mdsync:<uuid> on the linked iCloud card and on the Google-only card",
        "6  create/reuse group \"\(S13Writes.groupName)\" in iCloud; addMember ×2, then removeMember the iCloud-only card",
        "7  rename a relation on the linked iCloud card; add a relation to the Google-only card",
        "8  no unified mutable-copy save: content + change-history evidence",
        "9  transactionAuthor set: excludedTransactionAuthors hides our saves",
        "every batch: CNContactStoreAdapter.apply via the harness guard (all target cards re-fetched, must be S13 "
            + "harness cards)",
    ]

    init(store: CNContactStore, setup: S13Setup) throws {
        self.store = store
        self.setup = setup
        guarded = HarnessGuardedStore(
            spike: S13Writes.spike, allowedGroupNames: [S13Writes.groupName], log: ApplyLog())
    }

    // MARK: Preflight

    mutating func preflight(allowUnlinked: Bool) throws {
        report.say("c2m-spike s13-writes run  \(Stamp.iso())  author=\(author)")
        report.say("setup \(setup.short) created \(setup.createdAt)")
        let cards = try S13Locate.cards(store, setup: setup, keys: [])
        for role in S13Role.allCases {
            guard let card = cards[role] else {
                throw SpikeError(
                    """
                    The \(role.title) was not found by its marker. If Google stripped the marker URL, \
                    `c2m-spike cleanup` lists it as name-only. Start over: c2m-spike cleanup --spike s13 --yes; \
                    c2m-spike s13-writes setup --yes.
                    """)
            }
            ids[role] = card.identifier
            report.say("  \(role.title): \(card.identifier)")
        }
        let icloud = ids[.linkedICloud]!
        let google = ids[.linkedGoogle]!
        let unified = try catchingObjC {
            try store.unifiedContact(withIdentifier: icloud, keysToFetch: [CNContactIdentifierKey as NSString])
        }
        let members = try memberIDs(of: unified, in: store)
        linked = Set(members) == [icloud, google]
        let writer = SafeWriter(store: store)
        for id in members { _ = try writer.verifiedCard(id, keys: []) }  // refuses non-harness members
        report.say(
            "  linked pair: \(linked ? "YES" : "NO") (unified \(unified.identifier), \(members.count) member card(s))")
        if !linked {
            let message = """
                The S13 pair is not linked yet. Wait (automatic linking took ~15 min in S4/S9) or link the two \
                "ZZ Spike S13 Linked \(setup.short)" cards in Contacts.app (Card ▸ Link Selected Cards). \
                Re-run, or pass --allow-unlinked to run anyway.
                """
            if !allowUnlinked { throw SpikeError(message) }
            report.say("  WARNING: \(message)")
        }
        if store.currentHistoryToken == nil { report.say("  note: no change-history token; steps 8–9 history checks SKIP") }
    }

    // MARK: Plumbing

    struct StepHistory {
        var available = false
        /// The batch changed card fields (not only group membership, which
        /// may record no contact event).
        var contactWrites = false
        var targets: Set<String> = []
        /// Ids with events only when our author is not excluded.
        var authored: Set<String> = []
        /// Ids of target cards still seen when our author is excluded.
        var unauthoredOnTargets: Set<String> = []
        var unfilteredOnTargets: Set<String> = []
    }

    func historyIDs(since token: Data, excluding: [String]) throws -> [String] {
        let result = try store.c2mspike_history(since: token, excludingAuthors: excluding, unify: false, includeGroups: false)
        return result.events.compactMap(S3History.contactID)
    }

    /// Fresh fetch of every role (by last known id, else by marker).
    mutating func cards() throws -> [S13Role: CNContact] {
        var result: [S13Role: CNContact] = [:]
        var missing: [S13Role] = []
        for role in S13Role.allCases {
            if let id = ids[role], let card = try fetchUnderlying(store, id: id, keys: S13Writes.cardKeys()),
                Harness.isHarness(card)
            {
                result[role] = card
            } else {
                missing.append(role)
            }
        }
        if !missing.isEmpty {
            let found = try S13Locate.cards(store, setup: setup, keys: S13Writes.cardKeys())
            for role in missing {
                guard let card = found[role] else { throw SpikeError("\(role.title) vanished (marker not found).") }
                report.say("  note: \(role.title) id CHANGED \(ids[role] ?? "?") -> \(card.identifier) (found by marker)")
                ids[role] = card.identifier
                result[role] = card
            }
        }
        return result
    }

    func unified() throws -> CNContact {
        try catchingObjC {
            try store.unifiedContact(withIdentifier: ids[.linkedICloud]!, keysToFetch: S13Writes.unifiedKeys())
        }
    }

    /// Applies `operations` through the guarded real adapter; records history.
    mutating func write(_ step: String, _ operations: [AppleWriteOperation]) throws -> AppleWriteResult {
        for operation in operations { report.say("  apply: \(HarnessBatchGuard.describe(operation))") }
        let token = store.currentHistoryToken
        let result = try guarded.apply(AppleWriteBatch(operations: operations), author: author)
        report.check(
            step, "adapter applied every operation", result.failed.isEmpty,
            result.failed.isEmpty
                ? "\(result.applied.count) applied"
                : result.failed.map { "\(HarnessBatchGuard.describe($0.operation)): \($0.message)" }.joined(
                    separator: "; "))
        var history = StepHistory(targets: Set(operations.compactMap(\.cardID)))
        history.contactWrites = operations.contains { operation in
            switch operation {
            case .addMember, .removeMember: false
            default: true
            }
        }
        if let token {
            let all = try historyIDs(since: token, excluding: [])
            let excluded = try historyIDs(since: token, excluding: [author])
            history.available = true
            history.authored = Set(all).subtracting(excluded)
            history.unauthoredOnTargets = Set(excluded).intersection(history.targets)
            history.unfilteredOnTargets = Set(all).intersection(history.targets)
        }
        histories.append((step, history))
        return result
    }

    private func ids(_ values: [S13Value]) -> Set<String> { Set(values.map(\.id)) }

    // MARK: Steps

    mutating func runAll() throws {
        try step0GuardSelfTest()
        try step1AddEmail()
        try step2EditSharedEmail()
        try step3JobTitle()
        try step4DeletePhone()
        try step5Stamp()
        try step6Groups()
        try step7Relations()
        step8NoUnifiedSave()
        step9AuthorExcluded()
        try finish()
    }

    mutating func step0GuardSelfTest() throws {
        let step = "0"
        report.say("\n## Step 0: guard self-test (nothing may be saved)")
        let before = try cards()
        let icloud = before[.linkedICloud]!
        let entriesBefore = guarded.log.entries.count
        func refused(_ name: String, _ operations: [AppleWriteOperation]) {
            do {
                _ = try guarded.apply(AppleWriteBatch(operations: operations), author: author)
                report.check(step, name, .fail, "batch was NOT refused")
            } catch let error as SpikeError where error.message.hasPrefix("SAFETY") {
                report.check(step, name, .pass, "refused: \(error.message.prefix(90))…")
            } catch {
                report.check(step, name, .fail, "unexpected error: \(describe(error))")
            }
        }
        refused(
            "unknown card id + valid harness edit → whole batch refused",
            [
                .update(cardID: icloud.identifier, edits: [.scalar(.jobTitle, "S13 MUST NOT BE SAVED")]),
                .update(cardID: "s13-guard-selftest-no-such-card", edits: [.scalar(.jobTitle, "x")]),
            ])
        refused(
            "URL list edit without the marker → refused",
            [.update(cardID: icloud.identifier, edits: [.list(.urls, [])])])
        refused(
            "name edit dropping the ZZ Spike prefix → refused",
            [.update(cardID: icloud.identifier, edits: [.scalar(.givenName, "Not A Spike")])])
        refused(
            "create without harness name/marker → refused",
            [
                .create(
                    NewAppleContact(
                        recordID: UUID(), containerID: setup.icloudContainer, kind: .person,
                        edits: [.scalar(.givenName, "S13 guard"), .scalar(.familyName, "test")]))
            ])
        refused(
            "group op on a non-scratch group id → refused",
            [.addMember(cardID: icloud.identifier, groupID: "s13-guard-selftest-no-such-group")])
        let after = try cards()
        report.check(
            step, "nothing reached the adapter", guarded.log.entries.count == entriesBefore,
            "apply calls forwarded: \(guarded.log.entries.count - entriesBefore)")
        report.check(
            step, "linked iCloud card unchanged", after[.linkedICloud]!.jobTitle == icloud.jobTitle,
            "jobTitle \(after[.linkedICloud]!.jobTitle)")
    }

    mutating func step1AddEmail() throws {
        let step = "1"
        report.say("\n## Step 1: add an email to the linked contact (expect iCloud card only)")
        let before = try cards()
        let icloud = before[.linkedICloud]!
        let google = before[.linkedGoogle]!
        let added = "zz-spike-s13-\(setup.short.lowercased())-add-\(Self.tag())@example.invalid"
        var elements = S13View.kept(AppleContactMapper.canonical(from: icloud).emails)
        elements.append(AppleListElement(label: "home", value: .text(added)))
        _ = try write(step, [.update(cardID: icloud.identifier, edits: [.list(.emails, elements)])])
        let after = try cards()
        let icloudAfter = S13View.emails(after[.linkedICloud]!)
        let googleAfter = S13View.emails(after[.linkedGoogle]!)
        report.check(step, "new email on iCloud card", icloudAfter.contains { $0.value == added })
        report.check(
            step, "new email NOT on Google card", !googleAfter.contains { S13View.emailKey($0.value) == added },
            "a unified mutable-copy save would put it on both (S4)")
        report.check(
            step, "iCloud card's existing email ids kept", ids(S13View.emails(icloud)).isSubset(of: ids(icloudAfter)))
        report.check(step, "Google card emails untouched", S13View.emails(google) == googleAfter)
        try unifiedCheck(step, "unified view shows the new email") { unified in
            (unified.emailAddresses.contains { ($0.value as String) == added }, "")
        }
    }

    mutating func step2EditSharedEmail() throws {
        let step = "2"
        report.say("\n## Step 2: edit the shared email (expect edited on both cards, ids kept)")
        let before = try cards()
        let icloud = before[.linkedICloud]!
        let google = before[.linkedGoogle]!
        let googleKeys = Set(S13View.emails(google).map { S13View.emailKey($0.value) })
        guard let shared = S13View.emails(icloud).first(where: { googleKeys.contains(S13View.emailKey($0.value)) })
        else {
            report.check(step, "shared email present on both cards", .skip, "none found; re-run setup")
            return
        }
        let key = S13View.emailKey(shared.value)
        let edited = "zz-spike-s13-\(setup.short.lowercased())-shared-\(Self.tag())@example.invalid"
        var preIDs: [S13Role: String] = [:]
        var operations: [AppleWriteOperation] = []
        for role in [S13Role.linkedICloud, .linkedGoogle] {
            let card = before[role]!
            let canonical = AppleContactMapper.canonical(from: card).emails
            let elements = S13View.kept(canonical).map { element -> AppleListElement in
                guard case .text(let text) = element.value, S13View.emailKey(text) == key else { return element }
                var changed = element
                changed.value = .text(edited)
                return changed
            }
            preIDs[role] = S13View.emails(card).first { S13View.emailKey($0.value) == key }?.id
            operations.append(.update(cardID: card.identifier, edits: [.list(.emails, elements)]))
        }
        _ = try write(step, operations)
        let after = try cards()
        for role in [S13Role.linkedICloud, .linkedGoogle] {
            let emails = S13View.emails(after[role]!)
            let now = emails.first { $0.value == edited }
            report.check(step, "\(role.short): edited value present", now != nil)
            report.check(
                step, "\(role.short): old value gone", !emails.contains { S13View.emailKey($0.value) == key })
            report.check(
                step, "\(role.short): labeled-value id kept", now?.id != nil && now?.id == preIDs[role],
                "\(preIDs[role] ?? "∅") -> \(now?.id ?? "∅")")
        }
        try unifiedCheck(step, "unified shows the edited email once (collapsed across cards)") { unified in
            let count = unified.emailAddresses.filter { ($0.value as String) == edited }.count
            return (count == 1, "shown \(count)×")
        }
    }

    mutating func step3JobTitle() throws {
        let step = "3"
        report.say("\n## Step 3: change jobTitle (single-valued; expect both linked cards + unified)")
        let before = try cards()
        let wanted = "S13 title \(Self.tag())"
        // Planner rule: the target (iCloud) card, plus every other writable card with a non-empty value.
        let roles = [S13Role.linkedICloud, .linkedGoogle].filter {
            $0 == .linkedICloud || !before[$0]!.jobTitle.isEmpty
        }
        if roles.count == 1 { report.say("  note: Google card has no jobTitle, so the planner rule writes iCloud only") }
        _ = try write(step, roles.map { .update(cardID: before[$0]!.identifier, edits: [.scalar(.jobTitle, wanted)]) })
        let after = try cards()
        for role in roles {
            let value = after[role]!.jobTitle
            report.check(step, "\(role.short): per-card verify", value == wanted, "\"\(value)\"")
        }
        try unifiedCheck(step, "unified jobTitle shows the new value") { unified in
            (unified.jobTitle == wanted, "\"\(unified.jobTitle)\"")
        }
    }

    mutating func step4DeletePhone() throws {
        let step = "4"
        report.say("\n## Step 4: delete the phone present on both linked cards")
        let before = try cards()
        let googleKeys = Set(S13View.phones(before[.linkedGoogle]!).map { S13View.phoneKey($0.value) })
        guard
            let shared = S13View.phones(before[.linkedICloud]!).first(where: {
                googleKeys.contains(S13View.phoneKey($0.value))
            })
        else {
            report.check(step, "shared phone present on both cards", .skip, "none found (already deleted?)")
            return
        }
        let key = S13View.phoneKey(shared.value)
        var otherIDs: [S13Role: Set<String>] = [:]
        var operations: [AppleWriteOperation] = []
        for role in [S13Role.linkedICloud, .linkedGoogle] {
            let card = before[role]!
            let elements = S13View.kept(AppleContactMapper.canonical(from: card).phones).filter { element in
                guard case .text(let text) = element.value else { return true }
                return S13View.phoneKey(text) != key
            }
            otherIDs[role] = Set(S13View.phones(card).filter { S13View.phoneKey($0.value) != key }.map(\.id))
            operations.append(.update(cardID: card.identifier, edits: [.list(.phones, elements)]))
        }
        _ = try write(step, operations)
        let after = try cards()
        for role in [S13Role.linkedICloud, .linkedGoogle] {
            let phones = S13View.phones(after[role]!)
            report.check(step, "\(role.short): shared phone removed", !phones.contains { S13View.phoneKey($0.value) == key })
            report.check(
                step, "\(role.short): other phones kept (ids)", otherIDs[role]!.isSubset(of: ids(phones)),
                "\(otherIDs[role]!.count) other")
        }
        try unifiedCheck(step, "unified no longer shows the phone") { unified in
            (!unified.phoneNumbers.contains { S13View.phoneKey($0.value.stringValue) == key }, "")
        }
    }

    mutating func step5Stamp() throws {
        let step = "5"
        report.say("\n## Step 5: stamp x-c2mdsync:<uuid> (linked iCloud card, Google-only card)")
        let before = try cards()
        let targets: [S13Role] = [.linkedICloud, .soloGoogle]
        for role in targets { stamps[role] = UUID() }
        _ = try write(step, targets.map { .stamp(cardID: before[$0]!.identifier, id: stamps[$0]!) })
        let after = try cards()
        for role in targets {
            let card = after[role]!
            let stamp = S13View.stamp(card)
            report.check(
                step, "\(role.short): stamp URL value", stamp?.value == SyncStamp.url(for: stamps[role]!),
                stamp?.value ?? "∅")
            report.check(step, "\(role.short): stamp label c2mdsync", stamp?.label == SyncStamp.label, stamp?.label ?? "∅")
            report.check(
                step, "\(role.short): marker + other URL ids kept",
                ids(S13View.urls(before[role]!)).isSubset(of: ids(S13View.urls(card))) && Harness.isHarness(card))
        }
        report.check(
            step, "L-Google: no stamp (stamp goes to the iCloud card only)", S13View.stamp(after[.linkedGoogle]!) == nil)
    }

    mutating func step6Groups() throws {
        let step = "6"
        report.say("\n## Step 6: iCloud group membership (scratch group \"\(S13Writes.groupName)\")")
        let writer = SafeWriter(store: store)
        guard let container = try store.container(ofContact: ids[.linkedICloud]!) else {
            report.check(step, "iCloud container of linked card", .fail, "not found")
            return
        }
        if let existing = try writer.scratchGroups(named: S13Writes.groupName).first(where: {
            (try? store.containers(
                matching: CNContainer.predicateForContainerOfGroup(withIdentifier: $0.identifier)
            ).first?.identifier) == container.identifier
        }) {
            groupID = existing.identifier
            report.say("  reusing group \(existing.identifier)")
        } else {
            groupID = try writer.addGroup(named: S13Writes.groupName, to: container.identifier)
            report.say("  created group \(groupID!) in container \(container.identifier) (harness SafeWriter)")
        }
        let group = groupID!
        let before = try cards()
        _ = try write(
            "6a",
            [
                .addMember(cardID: before[.linkedICloud]!.identifier, groupID: group),
                .addMember(cardID: before[.soloICloud]!.identifier, groupID: group),
            ])
        var members = try writer.groupMembers(group)
        report.check(
            "6a", "both iCloud cards are members",
            Set([ids[.linkedICloud]!, ids[.soloICloud]!]).isSubset(of: Set(members.harness)),
            "harness members \(members.harness.count), other \(members.other.count)")
        report.check("6a", "group holds no non-harness cards", members.other.isEmpty)
        _ = try write("6b", [.removeMember(cardID: ids[.soloICloud]!, groupID: group)])
        members = try writer.groupMembers(group)
        report.check("6b", "iCloud-only card removed", !members.harness.contains(ids[.soloICloud]!))
        report.check("6b", "linked iCloud card still a member", members.harness.contains(ids[.linkedICloud]!))
    }

    mutating func step7Relations() throws {
        let step = "7"
        report.say("\n## Step 7: relation name writes")
        let before = try cards()
        let icloud = before[.linkedICloud]!
        let renamed = "ZZ Spike S13 Assistant \(Self.tag())"
        let current = S13View.relations(icloud)
        if let old = current.first(where: { $0.value.hasPrefix("ZZ Spike S13 Assistant") }) {
            let elements = S13View.keptRelations(AppleContactMapper.canonical(from: icloud).relationships).map {
                element -> AppleListElement in
                guard case .relation(let name, let type, let label) = element.value, name == old.value else {
                    return element
                }
                var changed = element
                changed.value = .relation(name: renamed, type: type, label: label)
                return changed
            }
            let google = before[.soloGoogle]!
            var googleElements = S13View.keptRelations(AppleContactMapper.canonical(from: google).relationships)
            let friend = "ZZ Spike S13 Friend \(Self.tag())"
            googleElements.append(AppleListElement(label: nil, value: .relation(name: friend, type: "friend", label: nil)))
            _ = try write(
                step,
                [
                    .update(cardID: icloud.identifier, edits: [.list(.relations, elements)]),
                    .update(cardID: google.identifier, edits: [.list(.relations, googleElements)]),
                ])
            let after = try cards()
            let now = S13View.relations(after[.linkedICloud]!).first { $0.value == renamed }
            report.check(step, "L-iCloud: relation renamed", now != nil, now?.value ?? "∅")
            report.check(
                step, "L-iCloud: relation labeled-value id kept", now?.id == old.id, "\(old.id) -> \(now?.id ?? "∅")")
            report.check(step, "L-iCloud: relation label kept", now?.label == old.label, now?.label ?? "∅")
            let added = S13View.relations(after[.soloGoogle]!).first { $0.value == friend }
            report.check(step, "Google-only: relation added", added != nil, added.map { "label \($0.label ?? "∅")" } ?? "∅")
        } else {
            report.check(step, "relation present on linked iCloud card", .skip, "none found; re-run setup")
        }
    }

    mutating func step8NoUnifiedSave() {
        let step = "8"
        report.say("\n## Step 8: no unified mutable-copy save")
        let operations = guarded.log.entries.flatMap(\.operations)
        let cardIDs = Set(operations.compactMap(\.cardID))
        let knownCards = Set(ids.values)
        report.check(
            step, "every operation named an underlying card id", !operations.isEmpty && cardIDs.isSubset(of: knownCards),
            "\(operations.count) ops on \(cardIDs.count) card ids; CNContactStoreAdapter has no unified-save path "
                + "(CardWriter fetches cards with unifyResults=false and saves only those)")
        report.say(
            "  content evidence: step 1 'new email NOT on Google card' (a unified save writes every linked card, S4)")
        var outside: [String] = []
        var available = false
        for (name, history) in histories where history.available {
            available = true
            let extra = history.authored.subtracting(history.targets)
            if !extra.isEmpty { outside.append("step \(name): \(extra.sorted().joined(separator: ","))") }
        }
        if !available {
            report.check(step, "authored history events only on target cards", .skip, "no history token")
        } else if outside.isEmpty {
            report.check(step, "authored history events only on target cards", .pass)
        } else {
            report.check(
                step, "authored history events only on target cards", .warn,
                "events on non-target cards (a linked partner?): \(outside.joined(separator: "; "))")
        }
    }

    mutating func step9AuthorExcluded() {
        let step = "9"
        report.say("\n## Step 9: transactionAuthor → excludedTransactionAuthors")
        let available = histories.filter { $0.history.available }
        guard !available.isEmpty else {
            report.check(step, "history available", .skip, "no history token")
            return
        }
        let fieldBatches = available.filter { $0.history.contactWrites }
        let recorded = fieldBatches.filter { !$0.history.unfilteredOnTargets.isEmpty }
        report.check(
            step, "our field saves appear in unfiltered history", recorded.count == fieldBatches.count,
            "\(recorded.count)/\(fieldBatches.count) batches")
        for (name, history) in available where !history.contactWrites {
            report.check(
                step, "group-only batch \(name) in history", .info,
                history.unfilteredOnTargets.isEmpty ? "no contact event" : "contact event recorded")
        }
        let leaked = available.filter { !$0.history.unauthoredOnTargets.isEmpty }
        if leaked.isEmpty {
            report.check(step, "excluding our author hides every save", .pass)
        } else {
            report.check(
                step, "excluding our author hides every save", .warn,
                "target cards still seen in: "
                    + leaked.map { "step \($0.step) (\($0.history.unauthoredOnTargets.count))" }.joined(separator: ", ")
                    + ". Either a concurrent unauthored save (Google sync re-saving the card) or the exclusion failed.")
        }
    }

    // MARK: Unified + finish

    func unifiedCheck(_ step: String, _ name: String, _ test: (CNContact) -> (Bool, String)) throws {
        let unified = try unified()
        let (ok, detail) = test(unified)
        if linked {
            report.check(step, name, ok, detail)
        } else {
            report.check(step, name, .info, "pair not linked; \(ok ? "true" : "false") \(detail)")
        }
    }

    mutating func finish() throws {
        let final = try cards()
        let members = groupID.flatMap { try? SafeWriter(store: store).groupMembers($0).harness } ?? []
        let unified = try unified()
        report.say("\n## Unified display after the run")
        report.say("  unified id \(unified.identifier)  jobTitle \"\(unified.jobTitle)\"")
        report.say("  emails: \(unified.emailAddresses.map { $0.value as String }.joined(separator: ", "))")
        report.say("  phones: \(unified.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", "))")
        let state = S13State(
            runAt: Stamp.iso(), author: author, groupID: groupID, unifiedID: unified.identifier,
            unifiedJobTitle: unified.jobTitle,
            cards: S13Role.allCases.compactMap { role in
                final[role].map { card in
                    S13CardRecord(
                        role: role.rawValue, cardID: card.identifier, jobTitle: card.jobTitle,
                        emails: S13View.emails(card), phones: S13View.phones(card), urls: S13View.urls(card),
                        relations: S13View.relations(card), stampID: stamps[role]?.uuidString.lowercased(),
                        inGroup: groupID == nil ? nil : members.contains(card.identifier))
                }
            })
        try JSONFile.write(state, to: try S13Writes.stateURL)
        report.say("\n## Summary: \(report.summary)")
        report.say(report.table.render())
        let url = try report.write("s13-\(Stamp.file()).md", title: "S13 run \(Stamp.iso())")
        print("\nwrote \(url.path)")
        print("saved \(try S13Writes.stateURL.path)")
        print(
            """

            NEXT: wait 15–30 minutes (open the S13 cards on iCloud.com and contacts.google.com to force a round \
            trip), then:
              c2m-spike s13-writes check
            """)
    }

    static func tag() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - State saved by run, read by check

struct S13CardRecord: Codable {
    var role: String
    var cardID: String
    var jobTitle: String
    var emails: [S13Value]
    var phones: [S13Value]
    var urls: [S13Value]
    var relations: [S13Value]
    var stampID: String?
    var inGroup: Bool?
}

struct S13State: Codable {
    var runAt: String
    var author: String
    var groupID: String?
    var unifiedID: String
    var unifiedJobTitle: String
    var cards: [S13CardRecord]
}

// MARK: - check

struct S13Checker {
    let store: CNContactStore
    let setup: S13Setup
    let report = S13Report()

    func run() throws {
        report.say("c2m-spike s13-writes check  \(Stamp.iso())  (read-only)")
        let url = try S13Writes.stateURL
        guard let state = try? JSONFile.read(S13State.self, from: url) else {
            throw SpikeError("No S13 run state at \(url.path). Run `c2m-spike s13-writes run --yes` first.")
        }
        report.say("comparing against the run at \(state.runAt)")
        let cards = try S13Locate.cards(store, setup: setup, keys: S13Writes.cardKeys())
        let scan = try HarnessScan.run(store)
        let nameOnly = scan.nameOnly.filter { Harness.displayName($0).hasPrefix("\(Harness.namePrefix)S13 ") }
        if !nameOnly.isEmpty {
            report.say("WARNING: \(nameOnly.count) S13-named card(s) without a marker (server stripped the URL?)")
        }
        for record in state.cards {
            guard let role = S13Role(rawValue: record.role) else { continue }
            let step = role.short
            report.say("\n## \(role.title)")
            guard let card = cards[role] else {
                report.check(step, "found by marker", false, "missing (deleted, or marker stripped)")
                continue
            }
            if card.identifier == record.cardID {
                report.check(step, "card id", .pass, "same as after run")
            } else {
                report.check(
                    step, "card id", .info, "CHANGED \(record.cardID) -> \(card.identifier) (found by marker: churn handled)")
            }
            report.check(step, "jobTitle survived", card.jobTitle == record.jobTitle, "\"\(card.jobTitle)\"")
            compare(step, "emails", record.emails, S13View.emails(card), key: S13View.emailKey)
            compare(step, "phones", record.phones, S13View.phones(card), key: S13View.phoneKey)
            compare(step, "urls", record.urls, S13View.urls(card), key: { $0.lowercased() })
            compare(step, "relations", record.relations, S13View.relations(card), key: { $0 })
            if let stampID = record.stampID {
                let stamp = S13View.stamp(card)
                report.check(
                    step, "stamp survived", stamp?.value == SyncStamp.prefix + stampID,
                    "\(stamp?.value ?? "∅") label \(stamp?.label ?? "∅")")
            }
            if let inGroup = record.inGroup, inGroup, let groupID = state.groupID {
                let members = (try? SafeWriter(store: store).groupMembers(groupID).harness) ?? []
                report.check(step, "still in \(S13Writes.groupName)", members.contains(card.identifier))
            }
        }
        try unifiedDisplay(state, cards: cards)
        report.say("\n## Summary: \(report.summary)")
        report.say(report.table.render())
        let out = try report.write("s13-check-\(Stamp.file()).md", title: "S13 check \(Stamp.iso())")
        print("\nwrote \(out.path)")
    }

    private func compare(
        _ step: String, _ field: String, _ recorded: [S13Value], _ now: [S13Value], key: (String) -> String
    ) {
        var problems: [String] = []
        var idChanges = 0
        for value in recorded {
            if let match = now.first(where: { $0.id == value.id }) {
                if match.value != value.value { problems.append("rewritten \"\(value.value)\" -> \"\(match.value)\"") }
                if match.label != value.label { problems.append("label \(value.label ?? "∅") -> \(match.label ?? "∅")") }
            } else if let match = now.first(where: { key($0.value) == key(value.value) }) {
                idChanges += 1
                if match.value != value.value { problems.append("rewritten \"\(value.value)\" -> \"\(match.value)\"") }
            } else {
                problems.append("MISSING \"\(value.value)\"")
            }
        }
        let added = now.filter { value in !recorded.contains { key($0.value) == key(value.value) } }
        if !added.isEmpty { problems.append("new: " + added.map(\.value).joined(separator: ", ")) }
        let missing = problems.contains { $0.hasPrefix("MISSING") }
        let outcome: S13Report.Outcome = missing ? .fail : (problems.isEmpty && idChanges == 0 ? .pass : .warn)
        var detail = "\(recorded.count) recorded"
        if idChanges > 0 { detail += ", \(idChanges) labeled-value id(s) CHANGED" }
        if !problems.isEmpty { detail += "; " + problems.joined(separator: "; ") }
        report.check(step, "\(field) survived", outcome, detail)
    }

    private func unifiedDisplay(_ state: S13State, cards: [S13Role: CNContact]) throws {
        report.say("\n## Unified display")
        guard let icloud = cards[.linkedICloud], let google = cards[.linkedGoogle] else {
            report.check("unified", "linked pair present", false)
            return
        }
        let unified = try catchingObjC {
            try store.unifiedContact(withIdentifier: icloud.identifier, keysToFetch: S13Writes.unifiedKeys())
        }
        let linked = unified.isUnifiedWithContact(withIdentifier: google.identifier)
        report.check("unified", "pair still linked", linked, "unified \(unified.identifier) (was \(state.unifiedID))")
        let source =
            unified.jobTitle == icloud.jobTitle && unified.jobTitle == google.jobTitle
            ? "both cards agree"
            : unified.jobTitle == icloud.jobTitle ? "iCloud card's value" : unified.jobTitle == google.jobTitle
                ? "Google card's value" : "neither card"
        report.check(
            "unified", "jobTitle still the written value", unified.jobTitle == state.unifiedJobTitle,
            "\"\(unified.jobTitle)\" (\(source))")
        var counts: [String: Int] = [:]
        for email in unified.emailAddresses { counts[S13View.emailKey(email.value as String), default: 0] += 1 }
        let duplicated = counts.filter { $0.value > 1 }
        report.check(
            "unified", "no email shown twice", duplicated.isEmpty,
            duplicated.isEmpty ? "\(counts.count) distinct" : duplicated.keys.sorted().joined(separator: ", "))
    }
}
