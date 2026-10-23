import ArgumentParser
import ContactModel
import Contacts
import ContactsAdapter
import Foundation

/// S15: CNSaveRequest writes to cards that HAVE a note, without the
/// `com.apple.developer.contacts.notes` entitlement.
///
/// Reported (developer forums 723695, FB23452026, mattt/iMCP#148): such saves
/// fail with NSCocoaErrorDomain 134092 "Unhandled error … occurred during
/// faulting". S13 passed only because its scratch cards had no notes. S15
/// records, per operation and per card (no note / noted / noted + linked),
/// what CNSaveRequest does, whether a failed save leaves partial changes,
/// whether cheap variations avoid the failure, and whether Contacts.app
/// scripting (Apple Events) can do the same operation instead.
///
/// Safety: every CN write re-fetches its target (`unifyResults = false`) and
/// refuses unless it is an S15 harness card (name prefix + marker, tag s15);
/// group writes need the exact scratch group name; deletes only target the
/// two delete cards (D, E). Every scripting write first runs
/// `S14NotesGuard.checkTargets` (CNContactStore AND Contacts.app agree the
/// person is an S15 harness card). Scripting parameters are descriptors.
struct S15NotedWrites: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s15-noted-writes",
        abstract: "S15: CNSaveRequest vs Contacts.app scripting on scratch cards that have a note (error 134092).",
        discussion: """
            setup --yes   create "ZZ Spike S15 …" cards A (no note), B (note), C (iCloud+Google pair, note on the \
            iCloud card), D (note, delete), E (no note, delete) and "ZZ Spike S15 Group"; notes are set with the \
            production ScriptingNotesProvider
            run --yes     ~15 min later (C linked): every operation via CNSaveRequest (variants V0–V5 and the kit \
            adapter), then the failed ones via Contacts.app scripting → results/s15-<date>.md
            Clean up with: c2m-spike cleanup --spike s15 --yes (falls back to scripting for noted cards).
            """,
        subcommands: [Setup.self, Run.self])

    static let spike = "s15"
    static let groupName = Harness.scratchGroupsBySpike["s15"]!
    static let author = "com.zmre.contacts2mdsync.spike-s15"

    static var setupURL: URL { get throws { try Paths.result("s15-setup.json") } }

    static func loadSetup() throws -> S15Setup {
        let url = try setupURL
        guard let setup = try? JSONFile.read(S15Setup.self, from: url) else {
            throw SpikeError("No S15 setup at \(url.path). Run `c2m-spike s15-noted-writes setup --yes` first.")
        }
        return setup
    }

    // MARK: - setup

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create the S15 scratch cards and group; set notes on B, C (iCloud) and D via the provider.")

        @OptionGroup var containerOptions: ContainerOptions

        @Flag(help: "Actually create the cards, the group and the notes.")
        var yes = false

        func run() throws {
            try runReporting {
                print("c2m-spike s15-noted-writes setup  \(Stamp.iso())")
                let store = try Access.authorizedStore()
                let scan = try HarnessScan.run(store)
                let existing = scan.harness(spike: S15NotedWrites.spike)
                if !existing.isEmpty {
                    throw SpikeError(
                        """
                        \(existing.count) S15 scratch card(s) already exist. Use `c2m-spike s15-noted-writes run`, \
                        or start over with `c2m-spike cleanup --spike s15 --yes`.
                        """)
                }
                let icloud = try containerOptions.resolve(.icloud, in: store)
                let google = try containerOptions.resolve(.google, in: store)
                let short = Stamp.short()
                let sharedEmail = "zz-spike-s15-\(short.lowercased())-c@example.invalid"
                let plan =
                    S15Kind.allCases.map { kind in
                        "create \"\(Harness.givenName) \(kind.family(short))\" (\(kind.title)) in "
                            + "\(kind.account == .icloud ? "iCloud \(icloud.identifier)" : "Google \(google.identifier)")"
                    } + [
                        "create (or reuse) group \"\(S15NotedWrites.groupName)\" in iCloud",
                        "C pair shares name + email \(sharedEmail) so Contacts links it automatically",
                        "launch Contacts.app hidden (production ScriptingNotesProvider), check each noted card in "
                            + "CNContactStore AND Contacts.app, then write a synthetic note to B, C-iCloud and D",
                    ]
                guard confirmPlan("s15-noted-writes setup", plan, yes: yes) else { return }

                let writer = SafeWriter(store: store)
                var markers: [String: String] = [:]
                var families: [String: String] = [:]
                var ids: [S15Kind: String] = [:]
                for (index, kind) in S15Kind.allCases.enumerated() {
                    let (card, marker) = Harness.newCard(
                        spike: S15NotedWrites.spike, kind: kind.rawValue, suffix: kind.suffix(short))
                    card.jobTitle = "S15 baseline"
                    let email = kind.isPair ? sharedEmail : "zz-spike-s15-\(short.lowercased())-\(kind.rawValue)@example.invalid"
                    card.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
                    card.phoneNumbers = [
                        CNLabeledValue(
                            label: CNLabelPhoneNumberMobile,
                            value: CNPhoneNumber(stringValue: "+1 415-555-01\(String(format: "%02d", 90 + index))"))
                    ]
                    let container = kind.account == .icloud ? icloud : google
                    try writer.add(card, to: container.identifier)
                    guard let saved = try Harness.locate(store, marker: marker) else {
                        throw SpikeError("Saved the \(kind.title) but could not find it again by marker.")
                    }
                    try Ledger.append(
                        LedgerEntry(
                            spike: S15NotedWrites.spike, kind: kind.rawValue, identifier: saved.identifier,
                            marker: marker, containerID: container.identifier, createdAt: Stamp.iso()))
                    markers[kind.rawValue] = marker
                    families[kind.rawValue] = card.familyName
                    ids[kind] = saved.identifier
                    print("created \(kind.title): identifier=\(saved.identifier)")
                }
                let groupID: String
                if let group = try writer.scratchGroups(named: S15NotedWrites.groupName).first(where: {
                    (try? store.containers(matching: CNContainer.predicateForContainerOfGroup(withIdentifier: $0.identifier))
                        .first?.identifier) == icloud.identifier
                }) {
                    groupID = group.identifier
                    print("reusing group \(groupID)")
                } else {
                    groupID = try writer.addGroup(named: S15NotedWrites.groupName, to: icloud.identifier)
                    print("created group \(groupID)")
                }
                var notes: [String: String] = [:]
                for kind in S15Kind.allCases where kind.noted {
                    notes[kind.rawValue] = S15Text.note(kind, Stamp.iso())
                }
                var setup = S15Setup(
                    short: short, createdAt: Stamp.iso(), markers: markers, families: families, notes: notes,
                    sharedEmail: sharedEmail, icloudContainer: icloud.identifier, googleContainer: google.identifier,
                    groupID: groupID, notesWritten: false)
                try JSONFile.write(setup, to: try S15NotedWrites.setupURL)  // saved before the notes, for cleanup

                let run = S14Run(title: "s15-noted-writes setup (notes)")
                defer { run.writeReport(name: "s15-setup-\(Stamp.file()).md", title: "S15 setup \(Stamp.iso())") }
                try run.body {
                    defer { run.finishLifecycle() }
                    guard try run.start(requestPermission: false) else {
                        throw SpikeError("Notes scripting is not usable; the noted cards have no note yet.")
                    }
                    let guardCheck = S14NotesGuard(store: store, scripting: try run.scripting())
                    var wanted: [String: String?] = [:]
                    for kind in S15Kind.allCases where kind.noted {
                        let id = ids[kind]!
                        run.report.check("N", "\(kind.short) resolves in Contacts.app", try run.waitUntilVisible(id), id)
                        wanted[id] = .some(notes[kind.rawValue]!)
                    }
                    try guardCheck.checkTargets(wanted.keys.sorted(), allowedSpikes: [S15NotedWrites.spike])
                    let toWrite = wanted
                    let result = try run.session.call { try $0.write(toWrite) }
                    run.report.check(
                        "N", "provider.write wrote every note", result.failed.isEmpty && result.written.count == wanted.count,
                        "written \(result.written.count), failed \(result.failed)")
                    let writtenIDs = Array(toWrite.keys)
                    let read = try run.session.call { try $0.readAll(cardIDs: writtenIDs) }
                    for kind in S15Kind.allCases where kind.noted {
                        let (outcome, detail) = S14Text.fidelity(notes[kind.rawValue]!, read[ids[kind]!] ?? nil)
                        run.report.check("N", "\(kind.short) note reads back", outcome, detail)
                    }
                }
                setup.notesWritten = true
                try JSONFile.write(setup, to: try S15NotedWrites.setupURL)
                print("saved \(try S15NotedWrites.setupURL.path)")
                print(
                    """

                    NEXT: wait about 15 minutes so Contacts links the "ZZ Spike S15 C Linked \(short)" pair (and the \
                    Google card's id settles; S15 finds cards by marker). Then:
                      c2m-spike s15-noted-writes run          (dry run: shows whether the pair is linked)
                      c2m-spike s15-noted-writes run --yes
                    """)
            }
        }
    }

    // MARK: - run

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Every op via CNSaveRequest (variants + kit adapter), failed ones via Contacts.app scripting.")

        @Flag(help: "Run even if the S15 C pair is not linked yet.")
        var allowUnlinked = false

        @Flag(help: "Also run the scripting equivalent for operations that CNSaveRequest V0 did NOT fail on.")
        var scriptingAll = false

        @Flag(help: "Actually write.")
        var yes = false

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let setup = try S15NotedWrites.loadSetup()
                let runner = try S15Runner(store: store, setup: setup, scriptingAll: scriptingAll)
                try runner.preflight(allowUnlinked: allowUnlinked)
                guard confirmPlan("s15-noted-writes run", S15Runner.planSteps, yes: yes) else { return }
                defer { runner.writeResults() }
                try runner.run.body { try runner.runAll() }
                if runner.report.counts[.fail, default: 0] > 0 { throw ExitCode(1) }
            }
        }
    }
}

// MARK: - Model

enum S15Kind: String, Codable, CaseIterable {
    case a
    case b
    case cICloud = "c-icloud"
    case cGoogle = "c-google"
    case d
    case e

    static let editTargets: [S15Kind] = [.a, .b, .cICloud, .cGoogle]
    static let deleteTargets: [S15Kind] = [.e, .d]

    var noted: Bool { [.b, .cICloud, .d].contains(self) }
    var isPair: Bool { self == .cICloud || self == .cGoogle }
    var account: AccountKind { self == .cGoogle ? .google : .icloud }

    var title: String {
        switch self {
        case .a: "card A (no note, control)"
        case .b: "card B (note)"
        case .cICloud: "pair C iCloud card (note)"
        case .cGoogle: "pair C Google card (no note, linked to C iCloud)"
        case .d: "card D (note, delete)"
        case .e: "card E (no note, delete)"
        }
    }

    var short: String {
        switch self {
        case .a: "A"
        case .b: "B noted"
        case .cICloud: "C-iCloud noted"
        case .cGoogle: "C-Google"
        case .d: "D noted"
        case .e: "E"
        }
    }

    func suffix(_ short: String) -> String {
        switch self {
        case .a: "A \(short)"
        case .b: "B Noted \(short)"
        case .cICloud, .cGoogle: "C Linked \(short)"
        case .d: "D Noted Delete \(short)"
        case .e: "E Delete \(short)"
        }
    }

    /// Family name as `Harness.newCard` builds it.
    func family(_ short: String) -> String { "\(S15NotedWrites.spike.uppercased()) \(suffix(short))" }
}

struct S15Setup: Codable {
    var short: String
    var createdAt: String
    /// Kind raw value → marker URL.
    var markers: [String: String]
    /// Kind raw value → family name at creation.
    var families: [String: String]
    /// Kind raw value → synthetic note text (noted kinds only).
    var notes: [String: String]
    var sharedEmail: String
    var icloudContainer: String
    var googleContainer: String
    var groupID: String
    var notesWritten: Bool
}

enum S15Op: String, CaseIterable {
    case names = "1"
    case addEmail = "2"
    case editPhone = "3"
    case groupAdd = "4a"
    case groupRemove = "4b"
    case urls = "5"
    case delete = "6"

    static let fieldOps: [S15Op] = [.names, .addEmail, .editPhone, .urls]

    var title: String {
        switch self {
        case .names: "familyName + jobTitle"
        case .addEmail: "add email"
        case .editPhone: "edit phone in place"
        case .groupAdd: "add to group"
        case .groupRemove: "remove from group"
        case .urls: "urlAddresses + stamp"
        case .delete: "delete card"
        }
    }

    /// Keys beyond `Harness.identityKeys` that the op needs (variant V1).
    var minimalKeys: [any CNKeyDescriptor] {
        switch self {
        case .names: [CNContactFamilyNameKey, CNContactJobTitleKey].map { $0 as NSString }
        case .addEmail: [CNContactEmailAddressesKey as NSString]
        case .editPhone: [CNContactPhoneNumbersKey as NSString]
        case .groupAdd, .groupRemove, .urls, .delete: []
        }
    }
}

/// How a CNSaveRequest attempt is made. `kit` runs the production adapter.
enum S15Variant: String, CaseIterable {
    case prodKeys = "V0"
    case minKeys = "V1"
    case noRefetch = "V2"
    case freshStore = "V3"
    case combined = "V4"
    case noteKey = "V5"
    case kit = "K"

    var title: String {
        switch self {
        case .prodKeys: "production key set (AppleContactMapper.cardKeys, no note key)"
        case .minKeys: "minimal keys (identity + the op's field only)"
        case .noRefetch: "production keys, CNSaveRequest.shouldRefetchContacts = false"
        case .freshStore: "production keys, a fresh CNContactStore for fetch + save"
        case .combined: "minimal keys + shouldRefetchContacts = false + fresh store"
        case .noteKey: "production keys + CNContactNoteKey (fetch probe; the value is never read)"
        case .kit: "production adapter: CNContactStoreAdapter.apply → CardWriter (harness-guarded)"
        }
    }

    var usesFreshStore: Bool { self == .freshStore || self == .combined }
    var noRefetch: Bool { self == .noRefetch || self == .combined }

    func keys(for op: S15Op) -> [any CNKeyDescriptor] {
        switch self {
        case .minKeys, .combined: op.minimalKeys
        case .noteKey: AppleContactMapper.cardKeys(includeNote: false) + [CNContactNoteKey as NSString]
        default: AppleContactMapper.cardKeys(includeNote: false)
        }
    }
}

enum S15Outcome {
    case ok
    case faulting(String)
    case other(String)
    case fetchFailed(String)
    case skipped(String)

    var cell: String {
        switch self {
        case .ok: "ok"
        case .faulting: "134092"
        case .other: "other"
        case .fetchFailed: "fetch failed"
        case .skipped: "n/a"
        }
    }

    var isOK: Bool { if case .ok = self { true } else { false } }
    var isSkipped: Bool { if case .skipped = self { true } else { false } }

    var detail: String {
        switch self {
        case .ok: ""
        case .faulting(let text), .other(let text), .fetchFailed(let text), .skipped(let text): text
        }
    }

    /// NSCocoaErrorDomain 134092 anywhere in the error chain or text → `.faulting`.
    static func classify(_ error: any Error) -> S15Outcome {
        let chain = S15Outcome.chain(error as NSError)
        let text = describe(error)
        let summary = chain.map { "\($0.domain) \($0.code)" }.joined(separator: " ← ")
        let brief = String(text.prefix(220))
        let detail = summary.isEmpty ? brief : "\(summary): \(brief)"
        let faulting =
            chain.contains { $0.domain == NSCocoaErrorDomain && $0.code == 134092 } || text.contains("134092")
        return faulting ? .faulting(detail) : .other(detail)
    }

    static func classify(message: String) -> S15Outcome {
        message.contains("134092") ? .faulting(String(message.prefix(220))) : .other(String(message.prefix(220)))
    }

    /// The error and its underlying / detailed errors (depth-limited).
    private static func chain(_ error: NSError, depth: Int = 0) -> [NSError] {
        guard depth < 6 else { return [] }
        var result = [error]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += chain(underlying, depth: depth + 1)
        }
        if let detailed = error.userInfo["NSDetailedErrors"] as? [NSError] {
            for item in detailed { result += chain(item, depth: depth + 1) }
        }
        return result
    }
}

/// What a successful op should leave behind.
struct S15Expect {
    var family: String?
    var jobTitle: String?
    var email: String?
    var phone: (id: String, value: String)?
    var stamp: String?
    var member: Bool?
    var deleted = false

    /// Fields an op is allowed to change (others are reported as unexpected).
    var fields: Set<String> {
        var result: Set<String> = []
        if family != nil { result.insert("familyName") }
        if jobTitle != nil { result.insert("jobTitle") }
        if email != nil { result.insert("email") }
        if phone != nil { result.insert("phone") }
        if stamp != nil { result.insert("url") }
        return result
    }
}

/// A card as seen on CNContactStore right now (fresh store, no note key).
struct S15CardState {
    var exists: Bool
    var rows: [FieldRow]
    var member: Bool
    var card: CNContact?
}

struct S15Attempt {
    var kind: S15Kind
    var op: S15Op
    var path: String
    var outcome: S15Outcome
    var verified: Bool?
    var verify: String
    var partial: String
    var history: String
    var note: String
}

enum S15Text {
    static func note(_ kind: S15Kind, _ stamp: String) -> String {
        "c2m-spike S15 synthetic note (\(kind.rawValue)) \(stamp)\nSecond line ✓ “quoted” and 'single'\nThird line"
    }

    /// Last 10 digits (servers may reformat or add +1).
    static func phoneKey(_ text: String) -> String { String(text.filter(\.isNumber).suffix(10)) }
}

// MARK: - Runner

final class S15Runner {
    let store: CNContactStore
    let setup: S15Setup
    let scriptingAll: Bool
    let run = S14Run(title: "s15-noted-writes run")
    var report: S13Report { run.report }
    let guarded = HarnessGuardedStore(
        spike: S15NotedWrites.spike, allowedGroupNames: [S15NotedWrites.groupName], log: ApplyLog())

    var ids: [S15Kind: String] = [:]
    var everIDs: Set<String> = []
    var groupID = ""
    var linked = false
    var attempts: [S15Attempt] = []
    var counter = 0
    let runTag: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }()
    private var scriptingInstance: S15Scripting?
    private var guardInstance: S14NotesGuard?
    var started = false

    static let planSteps = [
        "preflight (Apple Events, read-only): Contacts.app launched hidden by the production provider; B, C-iCloud "
            + "and D must have their synthetic note (re-set if missing)",
        "CNSaveRequest phase on A, B, C-iCloud, C-Google (unifyResults=false cards, S15 harness guard): ops 1 names, "
            + "2 add email, 3 edit phone in place, 4a/4b group add/remove (iCloud cards), 5 urlAddresses + stamp; "
            + "each via V0 production keys, V1 minimal keys, V2 shouldRefetchContacts=false, V3 fresh store, V4 all "
            + "three, V5 + CNContactNoteKey, K kit adapter",
        "each attempt: success / 134092 / other; after a failure, any partial change; after a success, the field "
            + "verify + history events per card",
        "Contacts.app scripting phase: for each (card, op) where V0 failed (all with --scripting-all), the AppleScript equivalent (set last "
            + "name/job title, make new email, set value of phone id, add/remove person to/from group, make new "
            + "url, save); verify on CNContactStore (fields, labeled-value ids, card id, history) and by re-reading "
            + "through scripting",
        "labeled-value ids: Contacts.app email/phone/url `id` vs CNLabeledValue.identifier; group `id` vs CNGroup id",
        "delete phase: E (no note) then D (note): V0…K until one works, else `delete person id X` + save",
        "notes on B and C-iCloud intact (provider read, hashes); no other card added/removed; history only on S15 "
            + "cards → results/s15-<date>.md",
    ]

    init(store: CNContactStore, setup: S15Setup, scriptingAll: Bool) throws {
        self.store = store
        self.setup = setup
        self.scriptingAll = scriptingAll
    }

    // MARK: Lookup

    /// Finds every kind's card by marker (one identity-key scan).
    func locateAll() throws -> [S15Kind: String] {
        var byMarker: [String: S15Kind] = [:]
        for kind in S15Kind.allCases { if let marker = setup.markers[kind.rawValue] { byMarker[marker] = kind } }
        var found: [S15Kind: String] = [:]
        let request = CNContactFetchRequest(keysToFetch: Harness.identityKeys)
        request.unifyResults = false
        try catchingObjC {
            try store.enumerateContacts(with: request) { contact, _ in
                guard Harness.isHarness(contact) else { return }
                for url in contact.urlAddresses {
                    if let kind = byMarker[url.value as String] { found[kind] = contact.identifier }
                }
            }
        }
        return found
    }

    /// Current id of `kind` (re-located by marker if the recorded id is gone).
    func currentID(_ kind: S15Kind) throws -> String? {
        if let id = ids[kind], try fetchUnderlying(store, id: id, keys: []) != nil { return id }
        guard let id = try locateAll()[kind] else { return nil }
        if let old = ids[kind], old != id { report.say("  note: \(kind.short) id CHANGED \(old) -> \(id) (found by marker)") }
        ids[kind] = id
        everIDs.insert(id)
        return id
    }

    func state(_ id: String) throws -> S15CardState {
        let fresh = CNContactStore()
        guard let card = try fetchUnderlying(fresh, id: id, keys: Snapshot.keys) else {
            return S15CardState(exists: false, rows: [], member: false, card: nil)
        }
        let member = try SafeWriter(store: fresh).groupMembers(groupID).harness.contains(id)
        return S15CardState(exists: true, rows: Snapshot.rows(of: card), member: member, card: card)
    }

    /// The S15 scratch group, fetched fresh from `store`; SAFETY-checked by exact name.
    func scratchGroup(_ store: CNContactStore) throws -> CNGroup {
        let groups = try catchingObjC {
            try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupID]))
        }
        guard let group = groups.first(where: { $0.identifier == groupID }) else {
            throw SpikeError("S15 group \(groupID) not found.")
        }
        guard group.name == S15NotedWrites.groupName, Harness.scratchGroupNames.contains(group.name) else {
            throw SpikeError("SAFETY: group \(groupID) is not \"\(S15NotedWrites.groupName)\"; refusing.")
        }
        return group
    }

    func scripting() throws -> S15Scripting {
        if let scriptingInstance { return scriptingInstance }
        let made = try S15Scripting()
        scriptingInstance = made
        return made
    }

    func scriptGuard() throws -> S14NotesGuard {
        if let guardInstance { return guardInstance }
        let made = S14NotesGuard(store: store, scripting: try run.scripting())
        guardInstance = made
        return made
    }

    func nextTag() -> String {
        counter += 1
        return String(format: "%02d", counter)
    }

    // MARK: Preflight (CNContactStore only, no Apple Events)

    func preflight(allowUnlinked: Bool) throws {
        report.say("author=\(S15NotedWrites.author)  run tag \(runTag)")
        report.say("setup \(setup.short) created \(setup.createdAt); notes written at setup: \(setup.notesWritten)")
        let found = try locateAll()
        for kind in S15Kind.allCases {
            guard let id = found[kind] else {
                throw SpikeError(
                    """
                    The \(kind.title) was not found by its marker. If Google stripped the marker URL, `c2m-spike \
                    cleanup` lists it as name-only. Start over: c2m-spike cleanup --spike s15 --yes; \
                    c2m-spike s15-noted-writes setup --yes.
                    """)
            }
            guard let card = try fetchUnderlying(store, id: id, keys: []),
                Harness.marker(card).flatMap(Harness.spikeTag) == S15NotedWrites.spike
            else { throw SpikeError("SAFETY: \(kind.title) \(id) is not an S15 harness card.") }
            ids[kind] = id
            everIDs.insert(id)
            report.say("  \(kind.title): \(id)")
        }
        let unified = try catchingObjC {
            try store.unifiedContact(withIdentifier: ids[.cICloud]!, keysToFetch: [CNContactIdentifierKey as NSString])
        }
        let members = try memberIDs(of: unified, in: store)
        for id in members { _ = try SafeWriter(store: store).verifiedCard(id, keys: []) }  // non-harness member → refuse
        linked = Set(members) == [ids[.cICloud]!, ids[.cGoogle]!]
        report.say("  C pair linked: \(linked ? "YES" : "NO") (unified \(unified.identifier), \(members.count) member(s))")
        if !linked {
            let message = """
                The S15 C pair is not linked yet. Wait (~15 min) or link the two "ZZ Spike S15 C Linked \(setup.short)" \
                cards in Contacts.app (Card ▸ Link Selected Cards). Re-run, or pass --allow-unlinked.
                """
            if !allowUnlinked { throw SpikeError(message) }
            report.say("  WARNING: \(message)")
        }
        let groups = try catchingObjC {
            try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [setup.groupID]))
        }
        if let group = groups.first, group.name == S15NotedWrites.groupName {
            groupID = group.identifier
            report.say("  group \"\(group.name)\": \(groupID)")
        } else {
            report.say("  group \(setup.groupID) missing; run --yes will create \"\(S15NotedWrites.groupName)\" again")
        }
        if store.currentHistoryToken == nil { report.say("  note: no change-history token; history columns are empty") }
    }

    // MARK: Run

    func runAll() throws {
        attemptedRun = true
        let cnBefore = try S12Notes.Probe.cnIDs(store, unify: false)
        let overallToken = store.currentHistoryToken
        try ensureGroup()

        defer { run.finishLifecycle() }
        guard try run.start(requestPermission: false) else {
            throw SpikeError("Contacts.app scripting is not usable (see above); nothing written.")
        }
        started = true
        try notesPrecondition()
        try groupIdentity()

        report.say("\n# CNSaveRequest phase")
        for kind in S15Kind.editTargets {
            report.say("\n## \(kind.title)")
            for op in S15Op.fieldOps {
                for variant in S15Variant.allCases { _ = try cnAttempt(kind, op, variant) }
            }
            try groupOps(kind)
        }
        try noteCheck("after the CNSaveRequest phase")

        report.say("\n# Labeled-value ids: Contacts.app scripting vs CNContactStore")
        for kind in S15Kind.editTargets { try compareLabeledValueIDs(kind) }

        report.say("\n# Contacts.app scripting phase")
        for kind in S15Kind.editTargets {
            report.say("\n## \(kind.title)")
            for op in S15Op.fieldOps where needsScripting(kind, op) { _ = try scriptAttempt(kind, op) }
            if kind.account == .icloud {
                if needsScripting(kind, .groupAdd) {
                    try ensureMember(kind, false)
                    _ = try scriptAttempt(kind, .groupAdd)
                }
                if needsScripting(kind, .groupRemove) {
                    try ensureMember(kind, true)
                    _ = try scriptAttempt(kind, .groupRemove)
                }
            }
        }
        try noteCheck("after the scripting phase")

        report.say("\n# Delete phase")
        var deleted: Set<String> = []
        for kind in S15Kind.deleteTargets {
            report.say("\n## \(kind.title)")
            guard let id = try currentID(kind) else { continue }
            var gone = false
            for variant in S15Variant.allCases {
                let attempt = try cnAttempt(kind, .delete, variant)
                if attempt.outcome.isOK, attempt.verified == true {
                    gone = true
                    break
                }
            }
            if !gone {
                let attempt = try scriptAttempt(kind, .delete)
                gone = attempt.outcome.isOK && attempt.verified == true
            }
            report.check("6", "\(kind.short) deleted", gone, gone ? "" : "still present: delete by hand")
            if gone { deleted.insert(id) }
        }

        report.say("\n# Final checks")
        try noteCheck("final")
        let unified = try catchingObjC {
            try store.unifiedContact(withIdentifier: try currentID(.cICloud) ?? "", keysToFetch: [CNContactIdentifierKey as NSString])
        }
        let stillLinked = unified.isUnifiedWithContact(withIdentifier: try currentID(.cGoogle) ?? "")
        report.check("F", "C pair still linked", linked ? (stillLinked ? .pass : .fail) : .info, "unified \(unified.identifier)")
        let cnAfter = try S12Notes.Probe.cnIDs(store, unify: false)
        let expected = cnBefore.subtracting(deleted)
        let added = cnAfter.subtracting(expected)
        let removed = expected.subtracting(cnAfter)
        let churnOnly = added.isSubset(of: everIDs) && removed.isSubset(of: everIDs)
        report.check(
            "F", "no card added or removed except D/E", added.isEmpty && removed.isEmpty ? .pass : churnOnly ? .warn : .fail,
            "before \(cnBefore.count), after \(cnAfter.count), deleted \(deleted.count), unexpected +\(added.count) "
                + "-\(removed.count)\(churnOnly && !(added.isEmpty && removed.isEmpty) ? " (S15 id churn)" : "")")
        if let overallToken {
            let byCard = try historyByCard(since: overallToken)
            let others = byCard.keys.filter { !everIDs.contains($0) }
            report.check(
                "F", "history events (whole run) only on S15 cards", others.isEmpty ? .pass : .warn,
                others.isEmpty
                    ? "\(byCard.count) S15 card(s) with events"
                    : "\(others.count) other card(s) (concurrent sync or edits?): "
                        + others.sorted().prefix(5).joined(separator: ", "))
        }
    }

    private var attemptedRun = false

    func needsScripting(_ kind: S15Kind, _ op: S15Op) -> Bool {
        if scriptingAll { return true }
        return attempts.contains {
            $0.kind == kind && $0.op == op && $0.path == S15Variant.prodKeys.rawValue
                && !$0.outcome.isOK && !$0.outcome.isSkipped
        }
    }

    // MARK: Setup checks

    func ensureGroup() throws {
        guard groupID.isEmpty else { return }
        groupID = try SafeWriter(store: store).addGroup(named: S15NotedWrites.groupName, to: setup.icloudContainer)
        report.say("created group \(groupID) (SafeWriter)")
    }

    func notesPrecondition() throws {
        report.say("\n## Notes on the scratch cards (provider read; only synthetic text)")
        var repair: [String: String?] = [:]
        for kind in S15Kind.allCases {
            guard let id = try currentID(kind) else { continue }
            guard try run.waitUntilVisible(id) else {
                report.check("P", "\(kind.short) resolves in Contacts.app", false, id)
                continue
            }
        }
        let wanted = S15Kind.allCases.compactMap { ids[$0] }
        let read = try run.session.call { try $0.readAll(cardIDs: wanted) }
        for kind in S15Kind.allCases {
            guard let id = ids[kind] else { continue }
            let note = read[id] ?? nil
            if kind.noted {
                let (outcome, detail) = S14Text.fidelity(setup.notes[kind.rawValue] ?? "", note)
                if outcome == .fail {
                    report.check("P", "\(kind.short) has its synthetic note", .warn, "missing/different (\(detail)); re-setting it")
                    repair[id] = .some(setup.notes[kind.rawValue]!)
                } else {
                    report.check("P", "\(kind.short) has its synthetic note", outcome, detail)
                }
            } else {
                let empty = (note ?? "").isEmpty
                report.check(
                    "P", "\(kind.short) has no note", empty ? .pass : (kind == .cGoogle ? .info : .warn),
                    empty ? "" : "\(note!.count) chars (linked partner's note shown on this card?)")
            }
        }
        guard !repair.isEmpty else { return }
        try scriptGuard().checkTargets(repair.keys.sorted(), allowedSpikes: [S15NotedWrites.spike])
        let toWrite = repair
        let result = try run.session.call { try $0.write(toWrite) }
        report.check("P", "re-set missing notes", result.failed.isEmpty, "written \(result.written.count), failed \(result.failed)")
    }

    func groupIdentity() throws {
        let name = try? scripting().groupName(groupID)
        report.check(
            "G", "CNGroup.identifier resolves as `group id` in Contacts.app", name == S15NotedWrites.groupName,
            name.map { "name \"\($0)\"" } ?? "does not resolve")
    }

    // MARK: Notes

    func noteCheck(_ label: String) throws {
        let kinds = S15Kind.allCases.filter { $0.noted }
        var wanted: [S15Kind: String] = [:]
        for kind in kinds { if let id = try currentID(kind), try fetchUnderlying(store, id: id, keys: []) != nil { wanted[kind] = id } }
        guard !wanted.isEmpty else { return }
        let wantedIDs = Array(wanted.values)
        let read = try run.session.call { try $0.readAll(cardIDs: wantedIDs) }
        for (kind, id) in wanted.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let (outcome, detail) = S14Text.fidelity(setup.notes[kind.rawValue] ?? "", read[id] ?? nil)
            report.check("N", "\(kind.short) note intact \(label)", outcome, detail)
        }
    }

    func noteHash(_ id: String) -> String {
        guard started, let read = try? run.session.call({ try $0.readAll(cardIDs: [id]) }) else { return "?" }
        guard let note = read[id] else { return "absent" }
        return S14Text.hash(note)
    }

    // MARK: History

    func historyByCard(since token: Data) throws -> [String: [String]] {
        let result = try store.c2mspike_history(since: token, excludingAuthors: [], unify: false, includeGroups: true)
        var byCard: [String: [String]] = [:]
        for event in result.events {
            let id: String?
            switch event {
            case let e as CNChangeHistoryAddMemberToGroupEvent: id = e.member.identifier
            case let e as CNChangeHistoryRemoveMemberFromGroupEvent: id = e.member.identifier
            default: id = S3History.contactID(event)
            }
            if let id { byCard[id, default: []].append(S3History.eventName(event)) }
        }
        return byCard
    }

    func historyLine(since token: Data?, target: String) -> String {
        guard let token else { return "no token" }
        guard let byCard = try? historyByCard(since: token) else { return "unreadable" }
        if byCard.isEmpty { return "no events" }
        func names(_ list: [String]) -> String {
            Dictionary(grouping: list, by: { $0 }).map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: ",")
        }
        var parts: [String] = []
        if let mine = byCard[target] { parts.append("target: \(names(mine))") } else { parts.append("target: none") }
        let partnerKind: S15Kind? = ids[.cICloud] == target ? .cGoogle : ids[.cGoogle] == target ? .cICloud : nil
        for (id, list) in byCard.sorted(by: { $0.key < $1.key }) where id != target {
            let who = partnerKind.flatMap { ids[$0] } == id ? "linked partner" : everIDs.contains(id) ? "other S15 card" : "OTHER card"
            parts.append("\(who) \(id): \(names(list))")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: Verification

    func verify(_ expect: S15Expect, before: S15CardState, after: S15CardState) -> (Bool, String) {
        if expect.deleted { return after.exists ? (false, "card still present") : (true, "card gone") }
        guard after.exists else { return (false, "card id no longer resolves (identifier changed or card gone)") }
        var ok = true
        var notes: [String] = []
        func single(_ field: String) -> String { after.rows.first { $0.field == field }?.value ?? "" }
        if let family = expect.family {
            let now = single("familyName")
            if now != family { ok = false; notes.append("familyName \"\(now)\"") }
        }
        if let job = expect.jobTitle {
            let now = single("jobTitle")
            if now != job { ok = false; notes.append("jobTitle \"\(now)\"") }
        }
        if let email = expect.email {
            let present = after.rows.contains { $0.field == "email" && $0.value == email }
            if !present { ok = false; notes.append("new email missing") }
            let oldIDs = Set(before.rows.filter { $0.field == "email" }.map(\.key))
            let nowIDs = Set(after.rows.filter { $0.field == "email" }.map(\.key))
            notes.append(oldIDs.isSubset(of: nowIDs) ? "existing email ids kept" : "existing email ids CHANGED")
        }
        if let phone = expect.phone {
            let key = S15Text.phoneKey(phone.value)
            if let same = after.rows.first(where: { $0.field == "phone" && $0.key == phone.id }) {
                if S15Text.phoneKey(same.value) == key {
                    notes.append("phone edited in place, labeled-value id kept")
                } else {
                    ok = false
                    notes.append("phone id kept but value \"\(same.value)\"")
                }
            } else if let moved = after.rows.first(where: { $0.field == "phone" && S15Text.phoneKey($0.value) == key }) {
                notes.append("value present but labeled-value id CHANGED \(phone.id) -> \(moved.key)")
            } else {
                ok = false
                notes.append("new phone value missing")
            }
        }
        if let stamp = expect.stamp {
            let urls = after.rows.filter { $0.field == "url" }
            let stamps = urls.filter { SyncStamp.isStamp($0.value) }
            if !(stamps.count == 1 && stamps.first?.value == stamp) {
                ok = false
                notes.append("stamps \(stamps.map(\.value))")
            }
            if let label = stamps.first?.label { notes.append("stamp label \(label)") }
            let marker = before.rows.first { $0.field == "url" && Harness.markerSchemePrefix($0.value) != nil }
            if let marker, !urls.contains(where: { $0.key == marker.key && $0.value == marker.value }) {
                ok = false
                notes.append("marker URL id/value changed")
            }
        }
        if let member = expect.member, after.member != member {
            ok = false
            notes.append("group member: \(after.member)")
        }
        let unexpected = RowDiff.align(before.rows, after.rows).filter(\.changed).filter {
            !expect.fields.contains($0.field)
        }
        if !unexpected.isEmpty {
            ok = false
            notes.append(
                "UNEXPECTED: "
                    + unexpected.map { "\($0.field) \($0.before?.value ?? "∅") -> \($0.after?.value ?? "∅")" }
                    .joined(separator: "; "))
        }
        return (ok, notes.isEmpty ? "as expected" : notes.joined(separator: "; "))
    }

    /// What changed between two states (for failed saves: partial writes).
    func changes(_ before: S15CardState, _ after: S15CardState) -> String {
        var parts: [String] = []
        if before.exists != after.exists { parts.append(after.exists ? "card appeared" : "card GONE") }
        if before.member != after.member { parts.append("group member \(before.member) -> \(after.member)") }
        for diff in RowDiff.align(before.rows, after.rows) where diff.changed {
            parts.append("\(diff.field) \(diff.before?.value ?? "∅") -> \(diff.after?.value ?? "∅")")
        }
        return parts.isEmpty ? "none" : "PARTIAL: " + parts.joined(separator: "; ")
    }

    /// Records one attempt (row + log line + FAIL rows for alarming results).
    @discardableResult
    func record(
        _ kind: S15Kind, _ op: S15Op, _ path: String, _ outcome: S15Outcome, before: S15CardState,
        after: S15CardState, expect: S15Expect, token: Data?, targetID: String, noteBefore: String, extra: String = ""
    ) -> S15Attempt {
        var attempt = S15Attempt(
            kind: kind, op: op, path: path, outcome: outcome, verified: nil, verify: "-", partial: "-",
            history: historyLine(since: token, target: targetID), note: "-")
        if outcome.isOK {
            let (ok, detail) = verify(expect, before: before, after: after)
            attempt.verified = ok
            attempt.verify = detail + (extra.isEmpty ? "" : "; \(extra)")
            if !ok { report.check(op.rawValue, "\(kind.short) \(path) \(op.title): saved but verify failed", false, detail) }
        } else if !outcome.isSkipped {
            attempt.partial = changes(before, after)
            if attempt.partial != "none" {
                report.check(op.rawValue, "\(kind.short) \(path) \(op.title): failed save left changes", false, attempt.partial)
            }
            if !extra.isEmpty { attempt.verify = extra }
        }
        if kind.noted, !outcome.isSkipped, after.exists {
            let now = noteHash(targetID)
            attempt.note = now == noteBefore ? "intact" : "CHANGED"
            if now != noteBefore {
                report.check(op.rawValue, "\(kind.short) \(path) \(op.title): note changed", false, "\(noteBefore) -> \(now)")
            }
        }
        attempts.append(attempt)
        let result = outcome.isOK ? (attempt.verified == true ? "ok" : "ok (verify FAIL)") : outcome.cell
        report.say(
            "  [\(path)] \(op.rawValue) \(op.title): \(result)"
                + (outcome.detail.isEmpty ? "" : " — \(outcome.detail)")
                + (attempt.partial == "-" ? "" : " | partial: \(attempt.partial)")
                + (attempt.verify == "-" ? "" : " | \(attempt.verify)")
                + " | history: \(attempt.history)" + (attempt.note == "-" ? "" : " | note \(attempt.note)"))
        return attempt
    }

    func skipped(_ kind: S15Kind, _ op: S15Op, _ path: String, _ why: String) -> S15Attempt {
        let attempt = S15Attempt(
            kind: kind, op: op, path: path, outcome: .skipped(why), verified: nil, verify: "-", partial: "-",
            history: "-", note: "-")
        attempts.append(attempt)
        report.say("  [\(path)] \(op.rawValue) \(op.title): n/a — \(why)")
        return attempt
    }

    // MARK: CNSaveRequest attempts

    /// SAFETY: an S15 harness card; deletes only for D/E.
    func assertTarget(_ card: CNContact, _ kind: S15Kind, _ op: S15Op) throws {
        guard Harness.isHarness(card), Harness.marker(card).flatMap(Harness.spikeTag) == S15NotedWrites.spike,
            Harness.marker(card) == setup.markers[kind.rawValue]
        else { throw SpikeError("SAFETY: \(card.identifier) is not the S15 \(kind.title); refusing.") }
        if op == .delete, !S15Kind.deleteTargets.contains(kind) {
            throw SpikeError("SAFETY: delete is only allowed on cards D and E; refusing.")
        }
    }

    func cnAttempt(_ kind: S15Kind, _ op: S15Op, _ variant: S15Variant) throws -> S15Attempt {
        guard let id = try currentID(kind) else { return skipped(kind, op, variant.rawValue, "card not found") }
        if variant == .kit { return try kitAttempt(kind, op, id) }
        let before = try state(id)
        guard before.exists else { return skipped(kind, op, variant.rawValue, "card gone") }
        let noteBefore = kind.noted ? noteHash(id) : "-"
        let saveStore = variant.usesFreshStore ? CNContactStore() : store
        let token = store.currentHistoryToken
        let fetched: CNContact
        do {
            guard let card = try fetchUnderlying(saveStore, id: id, keys: variant.keys(for: op)) else {
                return skipped(kind, op, variant.rawValue, "not found")
            }
            fetched = card
        } catch {
            return record(
                kind, op, variant.rawValue, .fetchFailed(describe(error)), before: before, after: before,
                expect: S15Expect(), token: nil, targetID: id, noteBefore: noteBefore)
        }
        try assertTarget(fetched, kind, op)
        let request = CNSaveRequest()
        request.transactionAuthor = S15NotedWrites.author
        if variant.noRefetch { request.shouldRefetchContacts = false }
        var expect = S15Expect()
        let tag = nextTag()
        switch op {
        case .groupAdd, .groupRemove:
            let group = try scratchGroup(saveStore)
            if op == .groupAdd {
                request.addMember(fetched, to: group)
            } else {
                request.removeMember(fetched, from: group)
            }
            expect.member = op == .groupAdd
        default:
            guard let mutable = fetched.mutableCopy() as? CNMutableContact else { throw SpikeError("mutableCopy failed") }
            switch op {
            case .names:
                let family = "\(setup.families[kind.rawValue] ?? kind.family(setup.short)) n\(tag)"
                let job = "S15 \(variant.rawValue) title \(runTag)-\(tag)"
                mutable.familyName = family
                mutable.jobTitle = job
                expect.family = family
                expect.jobTitle = job
            case .addEmail:
                let email = "zz-spike-s15-\(setup.short.lowercased())-\(kind.rawValue)-add\(runTag)\(tag)@example.invalid"
                mutable.emailAddresses += [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
                expect.email = email
            case .editPhone:
                guard let first = mutable.phoneNumbers.first else { return skipped(kind, op, variant.rawValue, "no phone") }
                let value = "+1 415-555-01\(tag.suffix(2))"
                mutable.phoneNumbers[0] = first.settingValue(CNPhoneNumber(stringValue: value))
                expect.phone = (first.identifier, value)
            case .urls:
                let stamp = SyncStamp.url(for: UUID())
                var urls = mutable.urlAddresses.filter { !SyncStamp.isStamp($0.value as String) }
                urls.append(CNLabeledValue(label: SyncStamp.label, value: stamp as NSString))
                mutable.urlAddresses = urls
                expect.stamp = stamp
            case .delete:
                expect.deleted = true
            case .groupAdd, .groupRemove:
                break
            }
            if op == .delete {
                request.delete(mutable)
            } else {
                guard Harness.isHarness(mutable) else {
                    throw SpikeError("SAFETY: mutation removed the harness name prefix or marker; not saving.")
                }
                request.update(mutable)
            }
        }
        var outcome: S15Outcome
        do {
            try catchingObjC { try saveStore.execute(request) }
            outcome = .ok
        } catch {
            outcome = S15Outcome.classify(error)
        }
        let after = try state(id)
        return record(
            kind, op, variant.rawValue, outcome, before: before, after: after, expect: expect, token: token, targetID: id,
            noteBefore: noteBefore)
    }

    /// The production adapter (CardWriter) via the harness guard.
    func kitAttempt(_ kind: S15Kind, _ op: S15Op, _ id: String) throws -> S15Attempt {
        let path = S15Variant.kit.rawValue
        let before = try state(id)
        guard before.exists, let card = try fetchUnderlying(store, id: id, keys: AppleContactMapper.cardKeys(includeNote: false))
        else { return skipped(kind, op, path, "card gone") }
        try assertTarget(card, kind, op)
        let noteBefore = kind.noted ? noteHash(id) : "-"
        let canonical = AppleContactMapper.canonical(from: card)
        let tag = nextTag()
        var expect = S15Expect()
        let operation: AppleWriteOperation
        switch op {
        case .names:
            let family = "\(setup.families[kind.rawValue] ?? kind.family(setup.short)) n\(tag)"
            let job = "S15 K title \(runTag)-\(tag)"
            operation = .update(cardID: id, edits: [.scalar(.familyName, family), .scalar(.jobTitle, job)])
            expect.family = family
            expect.jobTitle = job
        case .addEmail:
            let email = "zz-spike-s15-\(setup.short.lowercased())-\(kind.rawValue)-add\(runTag)\(tag)@example.invalid"
            operation = .update(
                cardID: id,
                edits: [.list(.emails, S13View.kept(canonical.emails) + [AppleListElement(label: "home", value: .text(email))])])
            expect.email = email
        case .editPhone:
            guard let first = card.phoneNumbers.first else { return skipped(kind, op, path, "no phone") }
            let value = "+1 415-555-01\(tag.suffix(2))"
            let key = S15Text.phoneKey(first.value.stringValue)
            var changed = false
            let elements = S13View.kept(canonical.phones).map { element -> AppleListElement in
                guard !changed, case .text(let text) = element.value, S15Text.phoneKey(text) == key else { return element }
                changed = true
                var edited = element
                edited.value = .text(value)
                return edited
            }
            guard changed else { return skipped(kind, op, path, "phone not found in canonical list") }
            operation = .update(cardID: id, edits: [.list(.phones, elements)])
            expect.phone = (first.identifier, value)
        case .groupAdd:
            operation = .addMember(cardID: id, groupID: groupID)
            expect.member = true
        case .groupRemove:
            operation = .removeMember(cardID: id, groupID: groupID)
            expect.member = false
        case .urls:
            let uuid = UUID()
            operation = .stamp(cardID: id, id: uuid)
            expect.stamp = SyncStamp.url(for: uuid)
        case .delete:
            operation = .delete(cardID: id)
            expect.deleted = true
        }
        let token = store.currentHistoryToken
        var outcome: S15Outcome
        do {
            let result = try guarded.apply(AppleWriteBatch(operations: [operation]), author: S15NotedWrites.author)
            outcome = result.failed.first.map { S15Outcome.classify(message: $0.message) } ?? .ok
        } catch let error as SpikeError where error.message.hasPrefix("SAFETY") {
            throw error
        } catch {
            outcome = S15Outcome.classify(error)
        }
        let after = try state(id)
        return record(
            kind, op, path, outcome, before: before, after: after, expect: expect, token: token, targetID: id,
            noteBefore: noteBefore)
    }

    // MARK: Group ops (CN phase)

    func groupOps(_ kind: S15Kind) throws {
        guard kind.account == .icloud else {
            for op in [S15Op.groupAdd, .groupRemove] {
                for variant in S15Variant.allCases {
                    _ = skipped(kind, op, variant.rawValue, "Google card; the scratch group is in iCloud")
                }
            }
            return
        }
        for variant in S15Variant.allCases {
            try ensureMember(kind, false)
            _ = try cnAttempt(kind, .groupAdd, variant)
            try ensureMember(kind, true)
            _ = try cnAttempt(kind, .groupRemove, variant)
        }
        try ensureMember(kind, false)
    }

    /// Puts `kind` in or out of the scratch group (preparation, not a result):
    /// plain CNSaveRequest first, Contacts.app scripting if that fails.
    func ensureMember(_ kind: S15Kind, _ want: Bool) throws {
        guard let id = try currentID(kind) else { return }
        if try state(id).member == want { return }
        let card = try SafeWriter(store: store).verifiedCard(id, keys: [])
        try assertTarget(card, kind, want ? .groupAdd : .groupRemove)
        let request = CNSaveRequest()
        request.transactionAuthor = S15NotedWrites.author
        let group = try scratchGroup(store)
        if want { request.addMember(card, to: group) } else { request.removeMember(card, from: group) }
        var how = "CNSaveRequest"
        do {
            try catchingObjC { try store.execute(request) }
        } catch {
            how = "scripting (CNSaveRequest: \(S15Outcome.classify(error).cell))"
            try scriptGuard().checkTargets([id], allowedSpikes: [S15NotedWrites.spike])
            if want { try scripting().addToGroup(id, groupID: groupID) } else { try scripting().removeFromGroup(id, groupID: groupID) }
            _ = try waitFor { try self.state(id).member == want }
        }
        let now = try state(id).member
        report.say("  prep: \(kind.short) group member -> \(want) via \(how): \(now == want ? "ok" : "FAILED")")
        if now != want { throw SpikeError("Could not set group membership of \(kind.short) to \(want) for the next step.") }
    }

    // MARK: Scripting attempts

    func scriptAttempt(_ kind: S15Kind, _ op: S15Op) throws -> S15Attempt {
        let path = "AS"
        guard let id = try currentID(kind) else { return skipped(kind, op, path, "card not found") }
        if op == .delete, !S15Kind.deleteTargets.contains(kind) { throw SpikeError("SAFETY: scripting delete only on D/E.") }
        let before = try state(id)
        guard before.exists, let card = before.card else { return skipped(kind, op, path, "card gone") }
        try assertTarget(card, kind, op)
        try scriptGuard().checkTargets([id], allowedSpikes: [S15NotedWrites.spike])  // CN + Contacts.app, right before
        let noteBefore = kind.noted ? noteHash(id) : "-"
        let token = store.currentHistoryToken
        let script = try scripting()
        let tag = nextTag()
        var expect = S15Expect()
        var extra: [String] = []
        var outcome: S15Outcome = .ok
        do {
            switch op {
            case .names:
                let family = "\(setup.families[kind.rawValue] ?? kind.family(setup.short)) n\(tag)"
                let job = "S15 AS title \(runTag)-\(tag)"
                expect.family = family
                expect.jobTitle = job
                try script.setNames(id, lastName: family, jobTitle: job)
            case .addEmail:
                let email = "zz-spike-s15-\(setup.short.lowercased())-\(kind.rawValue)-add\(runTag)\(tag)@example.invalid"
                expect.email = email
                let newID = try script.addEmail(id, label: "work", value: email)
                extra.append("make new email returned id \(newID.isEmpty ? "∅" : newID)")
            case .editPhone:
                guard let first = card.phoneNumbers.first else { return skipped(kind, op, path, "no phone") }
                let value = "+1 415-555-01\(tag.suffix(2))"
                expect.phone = (first.identifier, value)
                let phones = try script.phones(id)
                if phones.contains(where: { $0.id == first.identifier }) {
                    try script.setPhone(id, phoneID: first.identifier, value: value)
                    extra.append("by `phone id <CNLabeledValue.identifier>`")
                } else if let index = phones.firstIndex(where: {
                    S15Text.phoneKey($0.value) == S15Text.phoneKey(first.value.stringValue)
                }) {
                    try script.setPhone(id, index: index + 1, value: value)
                    extra.append("by index \(index + 1) (scripting phone ids ≠ CN ids)")
                } else {
                    return skipped(kind, op, path, "phone not visible to scripting")
                }
            case .groupAdd:
                expect.member = true
                try script.addToGroup(id, groupID: groupID)
            case .groupRemove:
                expect.member = false
                try script.removeFromGroup(id, groupID: groupID)
            case .urls:
                let stamp = SyncStamp.url(for: UUID())
                expect.stamp = stamp
                for url in try script.urls(id) where SyncStamp.isStamp(url.value) {
                    try script.deleteURL(id, urlID: url.id)
                    extra.append("deleted old stamp url id \(url.id)")
                }
                let newID = try script.addURL(id, label: SyncStamp.label, value: stamp)
                extra.append("make new url returned id \(newID.isEmpty ? "∅" : newID)")
            case .delete:
                expect.deleted = true
                try script.deletePerson(id)
            }
        } catch {
            outcome = S15Outcome.classify(error)
        }
        // Contacts.app saves asynchronously relative to our store: wait for the change.
        var after = try state(id)
        if outcome.isOK {
            let waited = try waitFor { [self] in
                after = try state(id)
                return verify(expect, before: before, after: after).0
            }
            extra.append(String(format: "CN saw it after %.1fs", waited))
        }
        if outcome.isOK { extra.append(scriptingReread(op, id, expect)) }
        return record(
            kind, op, path, outcome, before: before, after: after, expect: expect, token: token, targetID: id,
            noteBefore: noteBefore, extra: extra.joined(separator: "; "))
    }

    /// Re-reads the written value through Contacts.app scripting.
    func scriptingReread(_ op: S15Op, _ id: String, _ expect: S15Expect) -> String {
        do {
            let script = try scripting()
            switch op {
            case .names:
                let (last, job) = try script.lastNameAndJobTitle(id)
                return "AS re-read \(last == expect.family && job == expect.jobTitle ? "ok" : "MISMATCH")"
            case .addEmail:
                return "AS re-read \(try script.emails(id).contains { $0.value == expect.email } ? "ok" : "MISMATCH")"
            case .editPhone:
                let key = S15Text.phoneKey(expect.phone?.value ?? "")
                return "AS re-read \(try script.phones(id).contains { S15Text.phoneKey($0.value) == key } ? "ok" : "MISMATCH")"
            case .urls:
                return "AS re-read \(try script.urls(id).contains { $0.value == expect.stamp } ? "ok" : "MISMATCH")"
            case .groupAdd, .groupRemove:
                let member = try script.groupIDs(of: id).contains(groupID)
                return "AS re-read \(member == expect.member ? "ok" : "MISMATCH")"
            case .delete:
                return "AS re-read \(try script.personExists(id) ? "MISMATCH (still exists)" : "ok (gone)")"
            }
        } catch {
            return "AS re-read failed: \(describe(error))"
        }
    }

    /// Polls `condition` (with the main run loop turning) for up to `timeout`.
    /// Returns the seconds waited.
    @discardableResult
    func waitFor(timeout: TimeInterval = 8, _ condition: () throws -> Bool) throws -> Double {
        let start = Date()
        while try !condition() {
            if Date().timeIntervalSince(start) > timeout { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        return Date().timeIntervalSince(start)
    }

    // MARK: Labeled-value ids

    func compareLabeledValueIDs(_ kind: S15Kind) throws {
        guard let id = try currentID(kind), let card = try state(id).card else { return }
        let script = try scripting()
        func compare(_ field: String, _ cn: [String], _ script: [S15Scripting.Entry]) {
            let cnSet = Set(cn)
            let asSet = Set(script.map(\.id))
            let outcome: S13Report.Outcome = cnSet == asSet ? .pass : .info
            let sample = "CN \(cn.first ?? "∅") / AS \(script.first?.id ?? "∅")"
            report.check(
                "ID", "\(kind.short): scripting \(field) ids == CNLabeledValue.identifier", outcome,
                cnSet == asSet ? "\(cn.count) equal (\(sample))" : "differ: \(cn.count) CN vs \(script.count) AS; \(sample)")
        }
        do {
            compare("email", card.emailAddresses.map(\.identifier), try script.emails(id))
            compare("phone", card.phoneNumbers.map(\.identifier), try script.phones(id))
            compare("url", card.urlAddresses.map(\.identifier), try script.urls(id))
        } catch {
            report.check("ID", "\(kind.short): scripting labeled-value read", false, describe(error))
        }
    }

    // MARK: Results

    func writeResults() {
        guard attemptedRun else { return }
        report.say("\n## Summary: \(report.summary)")
        let paths = S15Variant.allCases.map(\.rawValue) + ["AS"]
        var matrix = MarkdownTable(headers: ["Card", "Op"] + paths)
        let kinds = S15Kind.editTargets + S15Kind.deleteTargets
        for kind in kinds {
            for op in S15Op.allCases {
                let rows = attempts.filter { $0.kind == kind && $0.op == op }
                guard !rows.isEmpty else { continue }
                let cells = paths.map { path -> String in
                    let list = rows.filter { $0.path == path }
                    guard !list.isEmpty else { return "" }
                    return list.map { attempt in
                        var cell = attempt.outcome.isOK ? (attempt.verified == true ? "ok" : "ok, verify FAIL") : attempt.outcome.cell
                        if attempt.partial.hasPrefix("PARTIAL") { cell += ", PARTIAL" }
                        if attempt.note == "CHANGED" { cell += ", NOTE CHANGED" }
                        return cell
                    }.joined(separator: " / ")
                }
                matrix.rows.append([kind.short, "\(op.rawValue) \(op.title)"] + cells)
            }
        }
        var detail = MarkdownTable(headers: ["Card", "Op", "Path", "Result", "Error / verify", "Partial after failure", "Note", "History (unify=false)"])
        for attempt in attempts {
            let result = attempt.outcome.isOK ? (attempt.verified == true ? "ok" : "ok (verify FAIL)") : attempt.outcome.cell
            let text = [attempt.outcome.detail, attempt.verify == "-" ? "" : attempt.verify].filter { !$0.isEmpty }
                .joined(separator: " | ")
            detail.rows.append([
                attempt.kind.short, "\(attempt.op.rawValue) \(attempt.op.title)", attempt.path, result, text, attempt.partial,
                attempt.note, attempt.history,
            ])
        }
        let legend = S15Variant.allCases.map { "- **\($0.rawValue)**: \($0.title)" }.joined(separator: "\n")
            + "\n- **AS**: Contacts.app scripting (NSAppleScript handlers, descriptor parameters, `save`)"
        let text = """
            # S15 run \(Stamp.iso())

            Setup \(setup.short) (created \(setup.createdAt)). C pair linked at start: \(linked ? "yes" : "no").

            \(report.summary)

            ## Matrix (per card and operation; `134092` = NSCocoaErrorDomain 134092 faulting error)

            \(legend)

            \(matrix.render())

            ## Checks

            \(report.table.render())

            ## Attempts

            \(detail.render())

            ## Log

            ```text
            \(report.log.joined(separator: "\n"))
            ```

            """
        do {
            let url = try Paths.result("s15-\(Stamp.file()).md")
            try Data(text.utf8).write(to: url, options: .atomic)
            print("\nwrote \(url.path)")
        } catch {
            stderrLine("could not write the report: \(describe(error))")
        }
    }
}
