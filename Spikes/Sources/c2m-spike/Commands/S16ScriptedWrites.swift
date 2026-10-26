import AppKit
import ArgumentParser
import ContactModel
import Contacts
import ContactsAdapter
import Foundation
import class SyncEngine.CardWriteRouter
import struct SyncEngine.CardWriteRouteLog

/// S16: the PRODUCTION write routing on the real Contacts store and the real
/// Contacts.app: `CardWriteRouter` (SyncEngine) around the real
/// `CNContactStoreAdapter`, with the real `ScriptingCardWriter` as its
/// `CardScripting`, sharing one `ContactsAppSession(quitWhenDone: false)` with
/// the real `ScriptingNotesProvider` (which supplies `cardNotes`, as the
/// engine's notes bridge does). Architecture §6 "Write routing"; follows up
/// the S15 findings (raw-event forms, raw-label storage, element ids of
/// addresses / related names / social profiles / IMs).
///
/// Safety: every batch goes through `S16Runner.guarded`, which refuses the
/// WHOLE batch unless, right before `router.apply`:
///
/// - every target card passes `HarnessBatchGuard.check` (fresh CNContactStore
///   fetch, `unifyResults = false`, S16 harness card, marker kept by URL
///   edits, `ZZ Spike ` prefix kept, groups only "ZZ Spike S16 Group", no
///   note edits), AND
/// - `S14NotesGuard.checkTargets` confirms in Contacts.app that the same
///   person id shows the `ZZ Spike ` prefix and the card's marker, AND
/// - image and birthday edits target only a card whose note the provider
///   reads as present now (so the router sends them to scripting, which
///   reports them skipped and writes nothing).
///
/// After the save `HarnessBatchGuard.postCheck` re-checks every target.
/// Nothing about non-harness cards is printed except counts.
struct S16ScriptedWrites: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s16-scripted-writes",
        abstract: "S16: the production write routing (CardWriteRouter → ScriptingCardWriter) on scratch cards.",
        discussion: """
            setup --yes   create "ZZ Spike S16 …" iCloud cards B (note, set with the production \
            ScriptingNotesProvider; emails, phones, URLs, address, related name, social profile, IM) and A \
            (same fields, no note, control), and "ZZ Spike S16 Group". Works without a Google account.
            run --yes     every write through CardWriteRouter (real CNContactStoreAdapter + real \
            ScriptingCardWriter, cardNotes from the real notes provider) behind the harness guard; PASS/FAIL \
            table → results/s16-<date>.md
            Clean up with: c2m-spike cleanup --spike s16 --yes (noted cards are deleted through scripting).
            """,
        subcommands: [Setup.self, Run.self])

    static let spike = "s16"
    static let groupName = Harness.scratchGroupsBySpike["s16"]!
    static let author = "com.zmre.contacts2mdsync.spike-s16"

    static var setupURL: URL { get throws { try Paths.result("s16-setup.json") } }

    static func loadSetup() throws -> S16Setup {
        let url = try setupURL
        guard let setup = try? JSONFile.read(S16Setup.self, from: url) else {
            throw SpikeError("No S16 setup at \(url.path). Run `c2m-spike s16-scripted-writes setup --yes` first.")
        }
        return setup
    }

    // MARK: - setup

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create the S16 scratch cards A (no note) and B (note via the provider) and the group.")

        @OptionGroup var containerOptions: ContainerOptions

        @Flag(help: "Actually create the cards, the group and B's note.")
        var yes = false

        func run() throws {
            try runReporting {
                print("c2m-spike s16-scripted-writes setup  \(Stamp.iso())")
                let store = try Access.authorizedStore()
                let scan = try HarnessScan.run(store)
                let existing = scan.harness(spike: S16ScriptedWrites.spike)
                if !existing.isEmpty {
                    throw SpikeError(
                        """
                        \(existing.count) S16 scratch card(s) already exist. Use `c2m-spike s16-scripted-writes run`, \
                        or start over with `c2m-spike cleanup --spike s16 --yes`.
                        """)
                }
                let icloud = try containerOptions.resolve(.icloud, in: store)
                let short = Stamp.short()
                let plan =
                    S16Kind.allCases.map { kind in
                        "create \"\(Harness.givenName) \(kind.family(short))\" (\(kind.title)) in iCloud "
                            + "\(icloud.identifier): 2 emails, 2 phones, marker + 2 URLs, address, related name, "
                            + "Twitter profile, Skype IM"
                    } + [
                        "create (or reuse) group \"\(S16ScriptedWrites.groupName)\" in iCloud",
                        "launch Contacts.app hidden (production ScriptingNotesProvider), check B in CNContactStore "
                            + "AND Contacts.app, then write a synthetic note to B only",
                    ]
                guard confirmPlan("s16-scripted-writes setup", plan, yes: yes) else { return }

                let writer = SafeWriter(store: store)
                var markers: [String: String] = [:]
                var families: [String: String] = [:]
                var ids: [S16Kind: String] = [:]
                for kind in S16Kind.allCases {
                    let (card, marker) = S16Fixture.card(kind, short: short)
                    try writer.add(card, to: icloud.identifier)
                    guard let saved = try Harness.locate(store, marker: marker) else {
                        throw SpikeError("Saved the \(kind.title) but could not find it again by marker.")
                    }
                    try Ledger.append(
                        LedgerEntry(
                            spike: S16ScriptedWrites.spike, kind: kind.rawValue, identifier: saved.identifier,
                            marker: marker, containerID: icloud.identifier, createdAt: Stamp.iso()))
                    markers[kind.rawValue] = marker
                    families[kind.rawValue] = card.familyName
                    ids[kind] = saved.identifier
                    print("created \(kind.title): identifier=\(saved.identifier)")
                }
                let groupID: String
                if let group = try writer.scratchGroups(named: S16ScriptedWrites.groupName).first(where: {
                    (try? store.containers(matching: CNContainer.predicateForContainerOfGroup(withIdentifier: $0.identifier))
                        .first?.identifier) == icloud.identifier
                }) {
                    groupID = group.identifier
                    print("reusing group \(groupID)")
                } else {
                    groupID = try writer.addGroup(named: S16ScriptedWrites.groupName, to: icloud.identifier)
                    print("created group \(groupID)")
                }
                let note = S16Text.note(Stamp.iso())
                var setup = S16Setup(
                    short: short, createdAt: Stamp.iso(), markers: markers, families: families, note: note,
                    icloudContainer: icloud.identifier, groupID: groupID, notesWritten: false)
                try JSONFile.write(setup, to: try S16ScriptedWrites.setupURL)  // saved before the note, for cleanup

                let run = S14Run(title: "s16-scripted-writes setup (note on B)")
                defer { run.writeReport(name: "s16-setup-\(Stamp.file()).md", title: "S16 setup \(Stamp.iso())") }
                try run.body {
                    defer { run.finishLifecycle() }
                    guard try run.start(requestPermission: false) else {
                        throw SpikeError("Notes scripting is not usable; card B has no note yet.")
                    }
                    let bID = ids[.b]!
                    run.report.check("N", "B resolves in Contacts.app", try run.waitUntilVisible(bID), bID)
                    try S14NotesGuard(store: store, scripting: try run.scripting())
                        .checkTargets([bID], allowedSpikes: [S16ScriptedWrites.spike])
                    let wanted: [String: String?] = [bID: .some(note)]
                    let result = try run.session.call { try $0.write(wanted) }
                    run.report.check(
                        "N", "provider.write wrote B's note", result.failed.isEmpty && result.written == [bID],
                        "written \(result.written.count), failed \(result.failed)")
                    let read = try run.session.call { try $0.readAll(cardIDs: [bID]) }
                    let (outcome, detail) = S14Text.fidelity(note, read[bID] ?? nil)
                    run.report.check("N", "B note reads back", outcome, detail)
                }
                setup.notesWritten = true
                try JSONFile.write(setup, to: try S16ScriptedWrites.setupURL)
                print("saved \(try S16ScriptedWrites.setupURL.path)")
                print(
                    """

                    NEXT (no wait needed; iCloud only):
                      c2m-spike s16-scripted-writes run          (dry run: preflight, plan)
                      c2m-spike s16-scripted-writes run --yes
                    """)
            }
        }
    }

    // MARK: - run

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Every write through CardWriteRouter → ScriptingCardWriter / CNContactStoreAdapter (guarded).")

        @Flag(help: "Actually write.")
        var yes = false

        func run() throws {
            try runReporting {
                let store = try Access.authorizedStore()
                let setup = try S16ScriptedWrites.loadSetup()
                let runner = S16Runner(store: store, setup: setup)
                try runner.preflight()
                guard confirmPlan("s16-scripted-writes run", S16Runner.planSteps, yes: yes) else { return }
                defer { runner.writeResults() }
                try runner.run.body { try runner.runAll() }
                if runner.report.counts[.fail, default: 0] > 0 { throw ExitCode(1) }
            }
        }
    }
}

// MARK: - Model

enum S16Kind: String, Codable, CaseIterable {
    case a
    case b

    var title: String {
        switch self {
        case .a: "card A (no note, control)"
        case .b: "card B (note)"
        }
    }

    var short: String {
        switch self {
        case .a: "A"
        case .b: "B"
        }
    }

    var noted: Bool { self == .b }

    func suffix(_ short: String) -> String {
        switch self {
        case .a: "A \(short)"
        case .b: "B Noted \(short)"
        }
    }

    /// Family name as `Harness.newCard` builds it.
    func family(_ short: String) -> String { "\(S16ScriptedWrites.spike.uppercased()) \(suffix(short))" }
}

struct S16Setup: Codable {
    var short: String
    var createdAt: String
    /// Kind raw value → marker URL.
    var markers: [String: String]
    /// Kind raw value → family name at creation.
    var families: [String: String]
    /// B's synthetic note.
    var note: String
    var icloudContainer: String
    var groupID: String
    var notesWritten: Bool
}

enum S16Text {
    static func note(_ stamp: String) -> String {
        "c2m-spike S16 synthetic note (b) \(stamp)\nSecond line ✓ “quoted” and 'single'\nThird line"
    }
}

/// The scratch cards' starting values (all synthetic, `example.invalid`).
enum S16Fixture {
    static func card(_ kind: S16Kind, short: String) -> (CNMutableContact, String) {
        let (card, marker) = Harness.newCard(spike: S16ScriptedWrites.spike, kind: kind.rawValue, suffix: kind.suffix(short))
        let lower = short.lowercased()
        let tag = kind.rawValue
        let base = kind == .b ? 61 : 63
        card.jobTitle = "S16 baseline"
        card.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "zz-spike-s16-\(lower)-\(tag)@example.invalid" as NSString),
            CNLabeledValue(label: CNLabelHome, value: "zz-spike-s16-\(lower)-\(tag)-home@example.invalid" as NSString),
        ]
        card.phoneNumbers = [
            CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "+1 415-555-01\(base)")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "+1 415-555-01\(base + 1)")),
        ]
        card.urlAddresses += [
            CNLabeledValue(
                label: CNLabelURLAddressHomePage, value: "https://example.invalid/s16/\(lower)/\(tag)/keep" as NSString),
            CNLabeledValue(label: CNLabelOther, value: "https://example.invalid/s16/\(lower)/\(tag)/delete" as NSString),
        ]
        let address = CNMutablePostalAddress()
        address.street = "1 Spike Street"
        address.city = "Testville"
        address.state = "CA"
        address.postalCode = "94016"
        address.country = "United States"
        address.isoCountryCode = "us"
        card.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address.copy() as? CNPostalAddress ?? address)]
        card.contactRelations = [
            CNLabeledValue(label: CNLabelContactRelationFriend, value: CNContactRelation(name: "ZZ Spike S16 Friend"))
        ]
        card.socialProfiles = [
            CNLabeledValue(
                label: nil,
                value: CNSocialProfile(
                    urlString: nil, username: "zzspike16\(tag)", userIdentifier: nil, service: CNSocialProfileServiceTwitter))
        ]
        card.instantMessageAddresses = [
            CNLabeledValue(
                label: CNLabelHome,
                value: CNInstantMessageAddress(username: "zzspike16\(tag)", service: CNInstantMessageServiceSkype))
        ]
        return (card, marker)
    }

    /// The URL step 1 deletes (never the marker, never the stamp).
    static func isDeletableURL(_ value: String) -> Bool {
        value.hasPrefix("https://example.invalid/s16/") && value.hasSuffix("/delete")
    }
}

/// What step 1 / step 6 (the same update on B and A) should leave behind.
struct S16FieldUpdate {
    var cardID: String
    var operations: [AppleWriteOperation]
    var family: String
    var job: String
    var phoneID: String
    var phoneValue: String
    var untouchedPhone: (id: String, value: String)?
    var newEmail: String
    var keptEmailIDs: [String]
    var deletedURL: (id: String, value: String)?
    var keptURLs: [(id: String, value: String)]
    var stamp: String
}

/// One guarded `router.apply` and what history showed for it.
struct S16BatchRecord {
    enum Expectation: String {
        case exactlyOne = "exactly 1"
        case atMostOne = "at most 1"
        case none = "0"
    }

    var step: String
    var title: String
    var targets: [String]
    var expectation: Expectation
    /// Harness card id → event names in this batch's history window.
    var events: [String: [String]]
    /// Distinct non-harness cards with events in the window (count only).
    var otherCards: Int
    var historyRead: Bool
}

/// Runs a body off the main thread while the main run loop turns (the
/// session and Contacts.app control use NSWorkspace / NSRunningApplication,
/// as `S14Session.call` does for the provider).
enum S16Thread {
    static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let box = S14ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = Result { try body() }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return try box.result!.get()
    }
}

// MARK: - Runner

final class S16Runner {
    let store: CNContactStore
    let setup: S16Setup
    /// The run's one Contacts.app session, shared by the notes provider and the card writer.
    let session = ContactsAppSession(quitWhenDone: false)
    let provider: ScriptingNotesProvider
    let writer: ScriptingCardWriter
    let router: CardWriteRouter
    let run: S14Run
    var report: S13Report { run.report }
    let applyLog = ApplyLog()

    var ids: [S16Kind: String] = [:]
    var everIDs: Set<String> = []
    var groupID = ""
    var batches: [S16BatchRecord] = []
    var appBefore = ContactsAppState.now()
    var attempted = false
    private var lifecycleDone = false
    private var notesGuardInstance: S14NotesGuard?
    let runTag: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }()

    static let planSteps = [
        "Contacts.app launched hidden through ContactsAppSession(quitWhenDone: false), shared by the production "
            + "ScriptingNotesProvider and ScriptingCardWriter; router = CardWriteRouter(inner: CNContactStoreAdapter(), "
            + "scripting: ScriptingCardWriter); cardNotes for every batch read through the provider",
        "every batch: HarnessBatchGuard (CNContactStore) + S14NotesGuard (Contacts.app) on every target, else the "
            + "whole batch is refused; then router.apply; then the post-save harness check",
        "1  B: last name + job title + in-place phone edit + new `work` email + delete a URL + stamp (via scripting)",
        "2  labels: new email's CN label; relabel phones to `mobile` and custom `summer`",
        "3  B add to / remove from \"\(S16ScriptedWrites.groupName)\" (via scripting)",
        "4  B in-place edits: address street/city, related name, Twitter profile (reported applied), Skype IM "
            + "(IM: skipped up front — needs the notes entitlement — no IM Apple Event, card applied, never a card "
            + "failure); 4b the IM alone (the same IM outcome, nothing sent); 4c related names: add one "
            + "(`make new related name`), re-point two in one batch (one to A's name, an existing contact, as a sync "
            + "does for `to: \"[[Title]]\"`), delete the added one (`delete related name id`)",
        "5  B clear job title (\"\"), add an email with no label",
        "6  A (no note): the step-1 update via the Contacts framework; A add to group (framework) and remove "
            + "(scripting)",
        "7  B image → skipped, nothing written; B birthday → skipped",
        "8  history: one UpdateContactEvent per card per batch, none on other cards; no cards added/removed; "
            + "Contacts.app left as found",
        "9  B's note intact (hash), A still has none → results/s16-<date>.md",
    ]

    init(store: CNContactStore, setup: S16Setup) {
        self.store = store
        self.setup = setup
        provider = ScriptingNotesProvider(session: session)
        writer = ScriptingCardWriter(session: session)
        router = CardWriteRouter(inner: CNContactStoreAdapter(), scripting: writer)
        run = S14Run(title: "s16-scripted-writes run", session: S14Session(provider: provider))
    }

    var a: String { ids[.a]! }
    var b: String { ids[.b]! }

    // MARK: Preflight (CNContactStore only, no Apple Events)

    func preflight() throws {
        report.say("author=\(S16ScriptedWrites.author)  run tag \(runTag)")
        report.say("setup \(setup.short) created \(setup.createdAt); B's note written at setup: \(setup.notesWritten)")
        var byMarker: [String: S16Kind] = [:]
        for kind in S16Kind.allCases { if let marker = setup.markers[kind.rawValue] { byMarker[marker] = kind } }
        let request = CNContactFetchRequest(keysToFetch: Harness.identityKeys)
        request.unifyResults = false
        try catchingObjC {
            try store.enumerateContacts(with: request) { contact, _ in
                guard Harness.isHarness(contact) else { return }
                for url in contact.urlAddresses {
                    if let kind = byMarker[url.value as String] { self.ids[kind] = contact.identifier }
                }
            }
        }
        for kind in S16Kind.allCases {
            guard let id = ids[kind] else {
                throw SpikeError(
                    """
                    The \(kind.title) was not found by its marker. Start over: c2m-spike cleanup --spike s16 --yes; \
                    c2m-spike s16-scripted-writes setup --yes.
                    """)
            }
            guard let card = try fetchUnderlying(store, id: id, keys: []),
                Harness.marker(card).flatMap(Harness.spikeTag) == S16ScriptedWrites.spike
            else { throw SpikeError("SAFETY: \(kind.title) \(id) is not an S16 harness card.") }
            everIDs.insert(id)
            report.say("  \(kind.title): \(id)")
        }
        let groups = try catchingObjC {
            try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [setup.groupID]))
        }
        guard let group = groups.first(where: { $0.identifier == setup.groupID }),
            group.name == S16ScriptedWrites.groupName
        else {
            throw SpikeError(
                "\"\(S16ScriptedWrites.groupName)\" (\(setup.groupID)) is missing. Start over with cleanup + setup.")
        }
        groupID = group.identifier
        report.say("  group \"\(group.name)\": \(groupID)")
        if !setup.notesWritten { report.say("  WARNING: setup did not finish writing B's note; run re-sets it.") }
        if store.currentHistoryToken == nil { report.say("  note: no change-history token; history checks are skipped") }
    }

    // MARK: Run

    func runAll() throws {
        attempted = true
        appBefore = ContactsAppState.now()
        let cnBefore = try S12Notes.Probe.cnIDs(store, unify: false)
        let overallToken = store.currentHistoryToken
        defer { finishLifecycle() }

        guard try run.start(requestPermission: false) else {
            throw SpikeError("Contacts.app scripting is not usable (see above); nothing written.")
        }
        report.say("router: notes entitlement \((try? CNContactStoreAdapter().capabilities.notesAvailable) == true ? "yes" : "no")")
        try preconditions()

        try step1()
        try step2()
        try step3()
        try step4()
        try step4c()
        try step5()
        try step6()
        try step7()
        try step9()
        try step8(cnBefore: cnBefore, overallToken: overallToken)
    }

    // MARK: Preconditions

    func preconditions() throws {
        report.say("\n## Preconditions (provider read; only synthetic text)")
        for kind in S16Kind.allCases {
            report.check("P", "\(kind.short) resolves in Contacts.app", try run.waitUntilVisible(ids[kind]!), ids[kind]!)
        }
        let wanted = [a, b]
        let read = try run.session.call { try $0.readAll(cardIDs: wanted) }
        let aNote = read[a] ?? nil
        guard !S14Text.isNonEmpty(aNote) else {
            report.check("P", "A has no note", false, "\(aNote?.count ?? 0) chars")
            throw SpikeError("Card A has a note; the framework-route control is void. Start over with cleanup + setup.")
        }
        report.check("P", "A has no note", true)
        let (outcome, detail) = S14Text.fidelity(setup.note, read[b] ?? nil)
        if outcome == .fail {
            report.check("P", "B has its synthetic note", .warn, "missing/different (\(detail)); re-setting it")
            try notesGuard().checkTargets([b], allowedSpikes: [S16ScriptedWrites.spike])
            let toWrite: [String: String?] = [b: .some(setup.note)]
            let result = try run.session.call { try $0.write(toWrite) }
            report.check("P", "re-set B's note", result.failed.isEmpty, "written \(result.written.count)")
        } else {
            report.check("P", "B has its synthetic note", outcome, detail)
        }
        for kind in S16Kind.allCases {
            let member = try isMember(ids[kind]!)
            report.say("  \(kind.short) in \"\(S16ScriptedWrites.groupName)\" at start: \(member)")
        }
    }

    func notesGuard() throws -> S14NotesGuard {
        if let notesGuardInstance { return notesGuardInstance }
        let made = S14NotesGuard(store: store, scripting: try run.scripting())
        notesGuardInstance = made
        return made
    }

    // MARK: The guarded router

    /// The ONLY way S16 writes cards. Refuses the whole batch unless every
    /// target passes both guards right now; nothing is written before that.
    func guarded(_ operations: [AppleWriteOperation]) throws -> (AppleWriteResult, [String: Bool]) {
        let targets = Self.targets(operations)
        guard !targets.isEmpty, operations.allSatisfy({ $0.cardID != nil }) else {
            throw SpikeError("SAFETY: S16 batches only touch existing cards; refusing.")
        }
        for operation in operations {
            switch operation {
            case .create, .delete: throw SpikeError("SAFETY: S16 never creates or deletes; refusing the whole batch.")
            default: break
            }
        }
        // cardNotes as the engine supplies it: each target's note as read this run (through the provider).
        let read = try run.session.call { try $0.readAll(cardIDs: targets) }
        var cardNotes: [String: Bool] = [:]
        for id in targets { if let note = read[id] { cardNotes[id] = S14Text.isNonEmpty(note) } }
        var imageCards: Set<String> = []
        for operation in operations {
            guard case .update(let id, let edits) = operation else { continue }
            let media = edits.filter {
                switch $0 {
                case .image, .birthday: true
                default: false
                }
            }
            guard !media.isEmpty else { continue }
            guard cardNotes[id] == true else {
                throw SpikeError(
                    "SAFETY: image/birthday edit on \(id), which has no note now (it would go through the Contacts "
                        + "framework and be written); refusing the whole batch.")
            }
            imageCards.insert(id)
        }
        let batch = AppleWriteBatch(operations: operations, cardNotes: cardNotes)
        let cnGuard = HarnessBatchGuard(
            store: CNContactStore(), spike: S16ScriptedWrites.spike, allowedGroupNames: [S16ScriptedWrites.groupName],
            imageAllowedCardIDs: imageCards)
        try cnGuard.check(batch)
        try notesGuard().checkTargets(targets, allowedSpikes: [S16ScriptedWrites.spike])
        let router = self.router
        let result = try S16Thread.offMain { try router.apply(batch, author: S16ScriptedWrites.author) }
        applyLog.record(batch: batch, author: S16ScriptedWrites.author, result: result)
        try cnGuard.postCheck(batch, result: result)
        return (result, cardNotes)
    }

    static func targets(_ operations: [AppleWriteOperation]) -> [String] {
        var seen: [String] = []
        for id in operations.compactMap(\.cardID) where !seen.contains(id) { seen.append(id) }
        return seen
    }

    /// One guarded batch: log lines, the no-failure check, history, B's note.
    @discardableResult
    func apply(
        _ step: String, _ title: String, _ operations: [AppleWriteOperation], expect: S16BatchRecord.Expectation
    ) throws -> AppleWriteResult {
        let targets = Self.targets(operations)
        let noteBefore = targets.contains(b) ? noteHash(b) : nil
        let token = store.currentHistoryToken
        let logBefore = router.log
        let (result, cardNotes) = try guarded(operations)
        let logAfter = router.log
        report.say(
            "  [\(step)] \(title): cardNotes \(targets.map { "\(name($0))=\(cardNotes[$0].map(String.init) ?? "unknown")" }.joined(separator: ",")) | "
                + "applied \(result.applied.count), scripted \(result.scripted.count), failed \(result.failed.count), "
                + "held \(result.held.count), skipped \(result.skipped.count) | route log: scripted "
                + "+\(logAfter.scriptedAttempted - logBefore.scriptedAttempted)/"
                + "+\(logAfter.scriptedApplied - logBefore.scriptedApplied) applied, retried after 134092 "
                + "+\(logAfter.retriedAfterRejection - logBefore.retriedAfterRejection)")
        for failure in result.failed {
            report.say("    failed: \(HarnessBatchGuard.describe(failure.operation)): \(failure.message)")
        }
        for hold in result.held { report.say("    held: \(HarnessBatchGuard.describe(hold.operation)): \(hold.reason)") }
        for skip in result.skipped { report.say("    skipped: \(HarnessBatchGuard.describe(skip.edit)) — \(skip.reason)") }
        report.check(
            step, "\(title): router reports no failures or holds", result.failed.isEmpty && result.held.isEmpty,
            result.failed.map(\.message).joined(separator: "; "))
        let (events, others, readOK) = history(since: token, waitFor: expect == .exactlyOne ? Set(targets) : [])
        batches.append(
            S16BatchRecord(
                step: step, title: title, targets: targets, expectation: expect, events: events, otherCards: others,
                historyRead: readOK))
        if let noteBefore {
            let now = noteHash(b)
            report.check(step, "B note unchanged by \(title)", now == noteBefore, now == noteBefore ? "" : "\(noteBefore) -> \(now)")
        }
        return result
    }

    func name(_ id: String) -> String { id == ids[.a] ? "A" : id == ids[.b] ? "B" : id }

    // MARK: Reads

    /// A card fresh from a new CNContactStore (unified results off), every field the writer and the snapshot read.
    func cardNow(_ id: String) throws -> CNContact {
        let keys = Snapshot.keys + AppleContactMapper.cardKeys(includeNote: false)
        guard let card = try fetchUnderlying(CNContactStore(), id: id, keys: keys) else {
            throw SpikeError("Card \(id) no longer resolves (identifier changed or card gone).")
        }
        guard Harness.isHarness(card) else { throw SpikeError("SAFETY: \(id) no longer passes the harness check.") }
        return card
    }

    func isMember(_ id: String) throws -> Bool {
        try SafeWriter(store: CNContactStore()).groupMembers(groupID).harness.contains(id)
    }

    /// Polls membership until it equals `want` (up to 8 s); returns the final value and seconds waited.
    func waitMember(_ id: String, _ want: Bool) throws -> (Bool, Double) {
        let start = Date()
        var now = try isMember(id)
        while now != want, Date().timeIntervalSince(start) < 8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            now = try isMember(id)
        }
        return (now, Date().timeIntervalSince(start))
    }

    func noteHash(_ id: String) -> String {
        guard let read = try? run.session.call({ try $0.readAll(cardIDs: [id]) }) else { return "?" }
        guard let note = read[id] else { return "absent" }
        return S14Text.hash(note)
    }

    /// History since `token` split into harness cards (event names) and a
    /// count of other cards. Waits (up to 3 s) until every `waitFor` card has
    /// an UpdateContactEvent, then a little longer to catch duplicates.
    func history(since token: Data?, waitFor: Set<String>) -> ([String: [String]], Int, Bool) {
        guard let token else { return ([:], 0, false) }
        func read() -> ([String: [String]], Int)? {
            guard let result = try? store.c2mspike_history(
                since: token, excludingAuthors: [], unify: false, includeGroups: true)
            else { return nil }
            var harness: [String: [String]] = [:]
            var others: Set<String> = []
            for event in result.events {
                let id: String?
                switch event {
                case let e as CNChangeHistoryAddMemberToGroupEvent: id = e.member.identifier
                case let e as CNChangeHistoryRemoveMemberFromGroupEvent: id = e.member.identifier
                default: id = S3History.contactID(event)
                }
                guard let id else { continue }
                if everIDs.contains(id) {
                    harness[id, default: []].append(S3History.eventName(event))
                } else {
                    others.insert(id)
                }
            }
            return (harness, others.count)
        }
        let deadline = Date().addingTimeInterval(waitFor.isEmpty ? 1.5 : 3)
        var last = read()
        while Date() < deadline {
            if !waitFor.isEmpty, let (harness, _) = last,
                waitFor.allSatisfy({ harness[$0]?.contains("UpdateContactEvent") == true })
            {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            last = read()
        }
        if !waitFor.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.75))
            last = read() ?? last
        }
        guard let (harness, others) = last else { return ([:], 0, false) }
        return (harness, others, true)
    }

    // MARK: Checks shared by steps 1 and 6

    func freshPhone(_ current: String, _ base: String, _ alternative: String) -> String {
        S13View.phoneKey(current) == S13View.phoneKey(base) ? alternative : base
    }

    func fieldUpdate(_ kind: S16Kind) throws -> S16FieldUpdate {
        let id = ids[kind]!
        let card = try cardNow(id)
        let canonical = AppleContactMapper.canonical(from: card)
        guard canonical.phones.count == card.phoneNumbers.count, card.phoneNumbers.count >= 2,
            canonical.emails.count == card.emailAddresses.count
        else { throw SpikeError("\(kind.title): unexpected phones/emails (setup changed by hand?).") }
        let first = card.phoneNumbers[0]
        let base = kind == .b ? ("+1 415-555-0171", "+1 415-555-0172") : ("+1 415-555-0173", "+1 415-555-0174")
        let phoneValue = freshPhone(first.value.stringValue, base.0, base.1)
        var phones = S13View.kept(canonical.phones)
        phones[0].value = .text(phoneValue)
        let newEmail = "zz-spike-s16-\(setup.short.lowercased())-\(kind.rawValue)-w\(runTag)@example.invalid"
        let emails = S13View.kept(canonical.emails) + [AppleListElement(label: "work", value: .text(newEmail))]
        let deletable = canonical.urls.first { S16Fixture.isDeletableURL($0.value) }
        let family = "\(setup.families[kind.rawValue] ?? kind.family(setup.short)) r\(runTag)"
        let job = "S16 job \(runTag)"
        var edits: [CardEdit] = [
            .scalar(.familyName, family), .scalar(.jobTitle, job), .list(.phones, phones), .list(.emails, emails),
        ]
        if let deletable {
            edits.append(.list(.urls, S13View.kept(canonical.urls.filter { $0.value != deletable.value })))
        }
        let uuid = UUID()
        let urls = card.urlAddresses.map { (id: $0.identifier, value: $0.value as String) }
        return S16FieldUpdate(
            cardID: id, operations: [.update(cardID: id, edits: edits), .stamp(cardID: id, id: uuid)], family: family,
            job: job, phoneID: first.identifier, phoneValue: phoneValue,
            untouchedPhone: (card.phoneNumbers[1].identifier, card.phoneNumbers[1].value.stringValue),
            newEmail: newEmail, keptEmailIDs: card.emailAddresses.map(\.identifier),
            deletedURL: deletable.flatMap { wanted in urls.first { $0.value == wanted.value } },
            keptURLs: urls.filter { !SyncStamp.isStamp($0.value) && $0.value != deletable?.value },
            stamp: SyncStamp.url(for: uuid))
    }

    func checkRoute(
        _ step: String, _ what: String, _ operations: [AppleWriteOperation], _ result: AppleWriteResult, scripted: Bool
    ) {
        let applied = operations.allSatisfy(result.applied.contains)
        let viaScripting = operations.filter(result.scripted.contains).count
        let ok = applied && (scripted ? viaScripting == operations.count : viaScripting == 0)
        report.check(
            step, "\(what) routed via \(scripted ? "Contacts.app scripting (AppleWriteResult.scripted)" : "the Contacts framework (not scripted)")",
            ok, "\(operations.count) op(s): applied \(applied ? "all" : "NOT all"), scripted \(viaScripting)")
    }

    func verifyFieldUpdate(
        _ step: String, _ kind: S16Kind, _ update: S16FieldUpdate, before: CNContact, result: AppleWriteResult,
        scripted: Bool
    ) throws {
        let who = kind.short
        checkRoute(step, "\(who) update + stamp", update.operations, result, scripted: scripted)
        let after = try cardNow(update.cardID)
        report.check(
            step, "\(who) last name + job title", after.familyName == update.family && after.jobTitle == update.job,
            "familyName \"\(after.familyName)\", jobTitle \"\(after.jobTitle)\"")
        let phone = after.phoneNumbers.first { $0.identifier == update.phoneID }
        report.check(
            step, "\(who) phone edited in place (labeled-value id kept)",
            phone.map { S13View.phoneKey($0.value.stringValue) == S13View.phoneKey(update.phoneValue) } ?? false,
            phone.map { "id \(update.phoneID) now \"\($0.value.stringValue)\"" }
                ?? "id \(update.phoneID) gone; phones \(after.phoneNumbers.map { "\($0.identifier)=\($0.value.stringValue)" })")
        if let untouched = update.untouchedPhone {
            let same = after.phoneNumbers.first { $0.identifier == untouched.id }
            report.check(
                step, "\(who) untouched phone keeps id and value",
                same.map { S13View.phoneKey($0.value.stringValue) == S13View.phoneKey(untouched.value) } ?? false,
                same == nil ? "id \(untouched.id) gone" : "")
        }
        let emailIDs = Set(after.emailAddresses.map(\.identifier))
        let missing = update.keptEmailIDs.filter { !emailIDs.contains($0) }
        report.check(step, "\(who) existing email ids kept", missing.isEmpty, missing.isEmpty ? "" : "gone: \(missing)")
        let added = after.emailAddresses.first { S13View.emailKey($0.value as String) == S13View.emailKey(update.newEmail) }
        report.check(
            step, "\(who) new email present", added != nil,
            added.map { "id \($0.identifier), CN label \($0.label ?? "nil")" } ?? "missing")
        let urls = after.urlAddresses.map { (id: $0.identifier, value: $0.value as String, label: $0.label) }
        if let deleted = update.deletedURL {
            let still = urls.contains { $0.id == deleted.id || $0.value == deleted.value }
            report.check(step, "\(who) deleted URL gone (not the marker)", !still, still ? "still present" : "id \(deleted.id)")
        } else {
            report.check(step, "\(who) deleted URL gone (not the marker)", .skip, "no deletable URL left (a previous run deleted it)")
        }
        let lostURLs = update.keptURLs.filter { kept in !urls.contains { $0.id == kept.id && $0.value == kept.value } }
        report.check(
            step, "\(who) marker + kept URL keep ids and values", lostURLs.isEmpty,
            lostURLs.isEmpty ? "\(update.keptURLs.count) kept" : "changed: \(lostURLs.map(\.id))")
        let stamps = urls.filter { SyncStamp.isStamp($0.value) }
        report.check(
            step, "\(who) exactly one stamp, the new one", stamps.count == 1 && stamps.first?.value == update.stamp,
            "stamps \(stamps.count); label \(stamps.first?.label ?? "nil")")
        unexpected(step, who, before: before, after: after, allowed: ["familyName", "jobTitle", "phone", "email", "url"])
    }

    /// FAIL row if any field outside `allowed` changed.
    func unexpected(_ step: String, _ who: String, before: CNContact, after: CNContact, allowed: Set<String>) {
        let changed = RowDiff.align(Snapshot.rows(of: before), Snapshot.rows(of: after)).filter(\.changed)
            .filter { !allowed.contains($0.field) }
        report.check(
            step, "\(who): no other field changed", changed.isEmpty,
            changed.map { "\($0.field) \($0.before?.value ?? "∅") -> \($0.after?.value ?? "∅")" }.joined(separator: "; "))
    }

    // MARK: Steps

    private var stepOneEmail: String?

    func step1() throws {
        report.say("\n# 1. B (noted): names, phone in place, new email, delete a URL, stamp")
        let before = try cardNow(b)
        let update = try fieldUpdate(.b)
        stepOneEmail = update.newEmail
        let result = try apply("1", "B update + stamp", update.operations, expect: .exactlyOne)
        try verifyFieldUpdate("1", .b, update, before: before, result: result, scripted: true)
    }

    func step2() throws {
        report.say("\n# 2. Labels: raw Contacts labels through scripting")
        let card = try cardNow(b)
        if let email = stepOneEmail,
            let entry = card.emailAddresses.first(where: { S13View.emailKey($0.value as String) == S13View.emailKey(email) })
        {
            report.check(
                "2", "step-1 email (`work` → raw \(CNLabelWork) sent) has CN label CNLabelWork",
                entry.label == CNLabelWork, "CN label \(entry.label ?? "nil")")
        } else {
            report.check("2", "step-1 email (`work` → raw \(CNLabelWork) sent) has CN label CNLabelWork", false, "email missing")
        }
        let canonical = AppleContactMapper.canonical(from: card)
        guard canonical.phones.count == card.phoneNumbers.count, card.phoneNumbers.count >= 2 else {
            report.check("2", "relabel phones", false, "unexpected phones")
            return
        }
        var phones = S13View.kept(canonical.phones)
        phones[0].label = "mobile"
        phones[1].label = "summer"
        let custom = LabelMap.appleLabel(fromMarkdown: "summer") ?? "Summer"
        let before = card
        let operations: [AppleWriteOperation] = [.update(cardID: b, edits: [.list(.phones, phones)])]
        let result = try apply("2", "B relabel phones (mobile, summer)", operations, expect: .exactlyOne)
        checkRoute("2", "B relabel", operations, result, scripted: true)
        let after = try cardNow(b)
        for (index, wanted) in [(0, CNLabelPhoneNumberMobile), (1, custom)] {
            let original = before.phoneNumbers[index]
            let now = after.phoneNumbers.first { $0.identifier == original.identifier }
            let sameValue = now.map { S13View.phoneKey($0.value.stringValue) == S13View.phoneKey(original.value.stringValue) } ?? false
            report.check(
                "2", "phone \(index + 1) relabeled to \(index == 0 ? "CNLabelPhoneNumberMobile" : "custom \"\(custom)\"") (raw \(wanted) sent)",
                now?.label == wanted && sameValue,
                now.map { "CN label \($0.label ?? "nil"), id kept, value \(sameValue ? "unchanged" : "CHANGED")" }
                    ?? "id \(original.identifier) gone")
        }
        unexpected("2", "B", before: before, after: after, allowed: ["phone"])
    }

    func step3() throws {
        report.say("\n# 3. B (noted): add to and remove from the group via the router")
        if try isMember(b) {
            report.say("  B is already a member: removing first (prep)")
            try apply("3", "prep: B removeMember", [.removeMember(cardID: b, groupID: groupID)], expect: .atMostOne)
            _ = try waitMember(b, false)
        }
        let add: [AppleWriteOperation] = [.addMember(cardID: b, groupID: groupID)]
        let added = try apply("3", "B addMember", add, expect: .atMostOne)
        checkRoute("3", "B addMember", add, added, scripted: true)
        let (inGroup, addWait) = try waitMember(b, true)
        report.check("3", "B member after addMember (CNContactStore)", inGroup, String(format: "after %.1fs", addWait))
        let remove: [AppleWriteOperation] = [.removeMember(cardID: b, groupID: groupID)]
        let removed = try apply("3", "B removeMember", remove, expect: .atMostOne)
        checkRoute("3", "B removeMember", remove, removed, scripted: true)
        let (stillIn, removeWait) = try waitMember(b, false)
        report.check("3", "B not a member after removeMember (CNContactStore)", !stillIn, String(format: "after %.1fs", removeWait))
    }

    func step4() throws {
        report.say("\n# 4. B (noted): in-place edits of address, related name, social profile, IM")
        let before = try cardNow(b)
        let canonical = AppleContactMapper.canonical(from: before)
        guard let address = canonical.addresses.first, let relation = canonical.relationships.first,
            let relationName = relation.target?.displayName, !canonical.social.isEmpty,
            !canonical.im.isEmpty, let cnAddress = before.postalAddresses.first,
            let cnRelation = before.contactRelations.first, let cnSocial = before.socialProfiles.first,
            !before.instantMessageAddresses.isEmpty
        else {
            report.check("4", "B has address, related name, social profile and IM", false, "missing (setup changed?)")
            return
        }
        var newAddress = address.value
        newAddress.street = "\(runTag) Scripted Avenue"
        newAddress.city = "Scriptville \(runTag)"
        let newRelation = "ZZ Spike S16 Friend \(runTag)"
        let newHandle = "zzspike16b\(runTag)"
        let oldRelation = AppleValue.relation(name: relationName, type: relation.type, label: relation.label)
        var addresses = canonical.addresses.map {
            AppleListElement(existing: .address($0.value), existingLabel: $0.label, label: $0.label, value: .address($0.value))
        }
        addresses[0].value = .address(newAddress)
        var relations = S13View.keptRelations(canonical.relationships)
        if let index = relations.firstIndex(where: { $0.existing == oldRelation }) {
            relations[index].value = .relation(name: newRelation, type: relation.type, label: relation.label)
        }
        var socials = canonical.social.map {
            AppleListElement(existing: .social($0.value), existingLabel: $0.label, label: $0.label, value: .social($0.value))
        }
        socials[0].value = .social(SocialHandle(newHandle))
        var ims = canonical.im.map {
            AppleListElement(existing: .im($0.value), existingLabel: $0.label, label: $0.label, value: .im($0.value))
        }
        ims[0].value = .im(IMHandle(newHandle))
        let operations: [AppleWriteOperation] = [
            .update(
                cardID: b,
                edits: [.list(.addresses, addresses), .list(.relations, relations), .list(.social, socials), .list(.im, ims)])
        ]
        let elementLogBefore = writer.elementLog
        let result = try apply("4", "B address + related name + social + IM", operations, expect: .exactlyOne)
        checkRoute("4", "B structured edits", operations, result, scripted: true)
        checkReportedApplied("4", result, operations, fields: [.addresses, .relations, .social])
        let after = try cardNow(b)
        let nowAddress = after.postalAddresses.first { $0.identifier == cnAddress.identifier }
        report.check(
            "4", "address street/city edited in place (id kept)",
            nowAddress.map { $0.value.street == newAddress.street && $0.value.city == newAddress.city } ?? false,
            nowAddress.map { "id kept; \(Snapshot.render(address: $0.value)); label \($0.label ?? "nil")" }
                ?? "id \(cnAddress.identifier) gone; \(after.postalAddresses.map { "\($0.identifier): \(Snapshot.render(address: $0.value))" })")
        let nowRelation = after.contactRelations.first { $0.identifier == cnRelation.identifier }
        report.check(
            "4", "related name edited in place (id kept)", nowRelation?.value.name == newRelation,
            nowRelation.map { "id kept; \"\($0.value.name)\" label \($0.label ?? "nil")" }
                ?? "id \(cnRelation.identifier) gone; \(after.contactRelations.map { "\($0.identifier)=\($0.value.name)" })")
        let nowSocial = after.socialProfiles.first { $0.identifier == cnSocial.identifier }
        report.check(
            "4", "social profile username edited in place (id kept)", nowSocial?.value.username == newHandle,
            nowSocial.map {
                "id kept; service=\($0.value.service) user=\($0.value.username) url=\($0.value.urlString) (before url=\(cnSocial.value.urlString))"
            } ?? "id \(cnSocial.identifier) gone; \(after.socialProfiles.map { "\($0.identifier)=\($0.value.username)" })")
        checkIM("4", result, before: before, after: after, wanted: newHandle, log: elementLogBefore)
        unexpected("4", "B", before: before, after: after, allowed: ["address", "relation", "social"])
        try step4b()
    }

    /// 4b: the IM alone. The writer skips it before planning, so nothing is
    /// sent to Contacts.app for the card; the operation counts as applied.
    func step4b() throws {
        report.say("\n# 4b. B (noted): IM-only edit (first command is the IM element)")
        let before = try cardNow(b)
        let canonical = AppleContactMapper.canonical(from: before)
        guard !canonical.im.isEmpty, !before.instantMessageAddresses.isEmpty else {
            report.check("4b", "B has an IM", false, "missing (setup changed?)")
            return
        }
        let newHandle = "zzspike16b\(runTag)x"
        var ims = canonical.im.map {
            AppleListElement(existing: .im($0.value), existingLabel: $0.label, label: $0.label, value: .im($0.value))
        }
        ims[0].value = .im(IMHandle(newHandle))
        let operations: [AppleWriteOperation] = [.update(cardID: b, edits: [.list(.im, ims)])]
        let log = writer.elementLog
        let result = try apply("4b", "B IM only", operations, expect: .atMostOne)
        checkRoute("4b", "B IM-only edit", operations, result, scripted: true)
        let after = try cardNow(b)
        checkIM("4b", result, before: before, after: after, wanted: newHandle, log: log)
        unexpected("4b", "B", before: before, after: after, allowed: [])
    }

    /// 4c: related names beyond the in-place edit of step 4 (never verified
    /// before; a real sync on 2026-10-25 left two noted cards without the
    /// related names it re-pointed). Each batch goes through the same guards.
    func step4c() throws {
        report.say("\n# 4c. B (noted): add, re-point two at once, delete a related name")
        let before = try cardNow(b)
        guard let friend = before.contactRelations.first else {
            report.check("4c", "B has a related name", false, "missing (setup changed?)")
            return
        }
        let kept = { (card: CNContact) in S13View.keptRelations(AppleContactMapper.canonical(from: card).relationships) }
        let ids = { (card: CNContact) in card.contactRelations.map { "\($0.identifier)=\($0.value.name) \($0.label ?? "nil")" } }

        // 1. Add.
        let added = "ZZ Spike S16 Sibling \(runTag)"
        let addOps: [AppleWriteOperation] = [
            .update(
                cardID: b,
                edits: [
                    .list(
                        .relations,
                        kept(before) + [AppleListElement(label: nil, value: .relation(name: added, type: "sibling", label: nil))])
                ])
        ]
        let addResult = try apply("4c", "B add a related name", addOps, expect: .exactlyOne)
        checkRoute("4c", "B add related name", addOps, addResult, scripted: true)
        let afterAdd = try cardNow(b)
        let newEntry = afterAdd.contactRelations.first { $0.value.name == added }
        report.check(
            "4c", "related name added (`make new related name`), label sibling",
            newEntry.map { RelationLabelMap.mbr(fromApple: $0.label).type == "sibling" } ?? false,
            newEntry.map { "id \($0.identifier) label \($0.label ?? "nil")" } ?? "not added; now \(ids(afterAdd))")
        report.check(
            "4c", "the existing related name kept its id (add)",
            afterAdd.contactRelations.contains { $0.identifier == friend.identifier }, "\(ids(afterAdd))")
        report.check(
            "4c", "add reported applied, not skipped", addResult.skipped.isEmpty && addResult.failed.isEmpty,
            addResult.skipped.map(\.reason).joined(separator: "; "))
        unexpected("4c", "B", before: before, after: afterAdd, allowed: ["relation"])

        // 2. Re-point both in one batch; the friend to A's name (an existing contact).
        let aCard = try cardNow(a)
        let aName = [aCard.givenName, aCard.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let renamed = "ZZ Spike S16 Sibling \(runTag)b"
        var repoint = kept(afterAdd)
        for index in repoint.indices {
            guard case .relation(let name, let type, let label)? = repoint[index].existing else { continue }
            if name == friend.value.name { repoint[index].value = .relation(name: aName, type: type, label: label) }
            if name == added { repoint[index].value = .relation(name: renamed, type: type, label: label) }
        }
        let repointOps: [AppleWriteOperation] = [.update(cardID: b, edits: [.list(.relations, repoint)])]
        let repointResult = try apply("4c", "B re-point two related names", repointOps, expect: .exactlyOne)
        checkRoute("4c", "B re-point related names", repointOps, repointResult, scripted: true)
        let afterRepoint = try cardNow(b)
        let nowFriend = afterRepoint.contactRelations.first { $0.identifier == friend.identifier }
        let nowAdded = newEntry.flatMap { entry in afterRepoint.contactRelations.first { $0.identifier == entry.identifier } }
        report.check(
            "4c", "both re-pointed in place (ids kept), one to an existing contact's name",
            nowFriend?.value.name == aName && nowAdded?.value.name == renamed,
            "now \(ids(afterRepoint)) (wanted \"\(aName)\" and \"\(renamed)\")")
        report.check(
            "4c", "no related name lost by the re-point",
            afterRepoint.contactRelations.count == afterAdd.contactRelations.count,
            "\(afterAdd.contactRelations.count) -> \(afterRepoint.contactRelations.count)")
        unexpected("4c", "B", before: afterAdd, after: afterRepoint, allowed: ["relation"])
        // On the real Mac the related names looked unchanged right after the
        // write and were gone a few minutes later: look again after a pause.
        Thread.sleep(forTimeInterval: 10)
        let later = try cardNow(b)
        report.check(
            "4c", "both re-pointed related names still there 10 s later",
            later.contactRelations.contains { $0.identifier == friend.identifier && $0.value.name == aName }
                && later.contactRelations.contains { $0.value.name == renamed },
            "now \(ids(later))")

        // 3. Delete the added one.
        let deleteOps: [AppleWriteOperation] = [
            .update(
                cardID: b,
                edits: [.list(.relations, kept(afterRepoint).filter { $0.existing != .relation(name: renamed, type: "sibling", label: nil) })])
        ]
        let deleteResult = try apply("4c", "B delete a related name", deleteOps, expect: .exactlyOne)
        checkRoute("4c", "B delete related name", deleteOps, deleteResult, scripted: true)
        let afterDelete = try cardNow(b)
        report.check(
            "4c", "related name deleted (`delete related name id`), the other kept (id kept)",
            !afterDelete.contactRelations.contains { $0.value.name == renamed }
                && afterDelete.contactRelations.contains { $0.identifier == friend.identifier },
            "now \(ids(afterDelete))")
        unexpected("4c", "B", before: afterRepoint, after: afterDelete, allowed: ["relation"])
    }

    /// Step 4's address, related name and social edits: the operation is
    /// applied and none of those edits is in `skipped`.
    func checkReportedApplied(
        _ step: String, _ result: AppleWriteResult, _ operations: [AppleWriteOperation], fields: [AppleListField]
    ) {
        let applied = operations.allSatisfy(result.applied.contains)
        let skippedFields = result.skipped.compactMap { skip -> AppleListField? in
            if case .list(let field, _) = skip.edit, fields.contains(field) { return field }
            return nil
        }
        report.check(
            step, "address, related name and social edits reported applied (not skipped, not failed)",
            applied && skippedFields.isEmpty && result.failed.isEmpty,
            "operation applied: \(applied); skipped among them: \(skippedFields.map(\.rawValue)); "
                + "failed \(result.failed.count)")
    }

    /// The IM outcome the writer allows (architecture §6, S16 re-run):
    /// Contacts.app refuses every IM change (`-1719`), so the IM edit is
    /// skipped up front with `CardScriptingSupport.instantMessageReason`, no
    /// IM Apple Event is sent, the IM is unchanged and the card is applied.
    /// Never a card failure, never a different IM touched.
    func checkIM(
        _ step: String, _ result: AppleWriteResult, before beforeCard: CNContact,
        after: CNContact, wanted: String, log: ScriptingCardWriter.ElementLog
    ) {
        guard let cnIM = beforeCard.instantMessageAddresses.first else { return }
        let now = writer.elementLog
        let imCode = ContactsScriptingEvents.CardCode.instantMessage
        let imSent = (now.sent[imCode] ?? 0) - (log.sent[imCode] ?? 0)
        let refused = now.refused - log.refused
        let nowIM = after.instantMessageAddresses.first { $0.identifier == cnIM.identifier }
        let unchanged = nowIM.map { $0.value == cnIM.value && $0.label == cnIM.label } ?? false
        let imSkips = result.skipped.filter { if case .list(.im, _) = $0.edit { true } else { false } }
        let skippedUpFront = !imSkips.isEmpty
            && imSkips.allSatisfy { $0.reason == CardScriptingSupport.instantMessageReason }
        let applied = imSkips.allSatisfy { result.applied.contains($0.operation) }
        let detail =
            nowIM.map { "id kept; service=\($0.value.service) user=\($0.value.username) label \($0.label ?? "nil")" }
            ?? "id \(cnIM.identifier) gone; \(after.instantMessageAddresses.map { "\($0.identifier)=\($0.value.username)" })"
        report.check(
            step, "IM element commands (writer element log)", .info,
            "IM commands sent: \(imSent); element commands refused: \(refused)")
        report.check(
            step, "IM: no Apple Event sent for the IM", imSent == 0, "IM commands sent: \(imSent)")
        report.check(
            step, "IM unchanged (id, service, user name, label kept; \(wanted) not written)", unchanged, detail)
        report.check(
            step, "IM: skipped (\"\(CardScriptingSupport.instantMessageReason)\") with the card applied (never a card failure)",
            result.failed.isEmpty && skippedUpFront && applied && unchanged,
            "failed \(result.failed.count), applied \(applied), IM skips \(imSkips.map(\.reason))")
        report.check(
            step, "IM: nothing but an IM edit skipped", result.skipped.count == imSkips.count,
            result.skipped.map { "\(HarnessBatchGuard.describe($0.edit)) — \($0.reason)" }.joined(separator: "; "))
        let others = { (card: CNContact) in
            card.instantMessageAddresses.filter { $0.identifier != cnIM.identifier }
                .map { "\($0.identifier)|\($0.label ?? "")|\($0.value.service)|\($0.value.username)" }.sorted()
        }
        report.check(
            step, "IM: no other IM of B touched, none added", others(after) == others(beforeCard),
            "\(others(beforeCard).count) other(s) before, \(others(after).count) after")
    }

    func step5() throws {
        report.say("\n# 5. B (noted): clear the job title with \"\", add an email with no label")
        let before = try cardNow(b)
        let canonical = AppleContactMapper.canonical(from: before)
        let email = "zz-spike-s16-\(setup.short.lowercased())-b-n\(runTag)@example.invalid"
        let emails = S13View.kept(canonical.emails) + [AppleListElement(label: nil, value: .text(email))]
        let operations: [AppleWriteOperation] = [
            .update(cardID: b, edits: [.scalar(.jobTitle, ""), .list(.emails, emails)])
        ]
        let result = try apply("5", "B clear job title + unlabeled email", operations, expect: .exactlyOne)
        checkRoute("5", "B clear + unlabeled email", operations, result, scripted: true)
        let after = try cardNow(b)
        report.check("5", "job title empty in CN", after.jobTitle.isEmpty, "jobTitle \"\(after.jobTitle)\" (was \"\(before.jobTitle)\")")
        let entry = after.emailAddresses.first { S13View.emailKey($0.value as String) == S13View.emailKey(email) }
        report.check("5", "unlabeled email present", entry != nil, entry.map { "id \($0.identifier)" } ?? "missing")
        report.check(
            "5", "CN label of an email made with no label", .info,
            entry.map { "CN label \($0.label.map { "\"\($0)\"" } ?? "nil")" } ?? "-")
        let ids = Set(after.emailAddresses.map(\.identifier))
        report.check(
            "5", "existing email ids kept", before.emailAddresses.allSatisfy { ids.contains($0.identifier) })
        unexpected("5", "B", before: before, after: after, allowed: ["jobTitle", "email"])
    }

    func step6() throws {
        report.say("\n# 6. A (no note): the step-1 update via the Contacts framework; group add + remove")
        let before = try cardNow(a)
        let update = try fieldUpdate(.a)
        let logBefore = router.log
        let result = try apply("6", "A update + stamp", update.operations, expect: .exactlyOne)
        try verifyFieldUpdate("6", .a, update, before: before, result: result, scripted: false)
        let retried = router.log.retriedAfterRejection - logBefore.retriedAfterRejection
        report.check("6", "A: no 134092 retry through scripting", retried == 0, "retried \(retried)")
        if try isMember(a) {
            report.say("  A is already a member: removing first (prep)")
            try apply("6", "prep: A removeMember", [.removeMember(cardID: a, groupID: groupID)], expect: .atMostOne)
            _ = try waitMember(a, false)
        }
        let add: [AppleWriteOperation] = [.addMember(cardID: a, groupID: groupID)]
        let added = try apply("6", "A addMember", add, expect: .atMostOne)
        checkRoute("6", "A addMember", add, added, scripted: false)
        let (inGroup, addWait) = try waitMember(a, true)
        report.check("6", "A member after addMember (CNContactStore)", inGroup, String(format: "after %.1fs", addWait))
        let remove: [AppleWriteOperation] = [.removeMember(cardID: a, groupID: groupID)]
        let removed = try apply("6", "A removeMember", remove, expect: .atMostOne)
        checkRoute("6", "A removeMember (no note, still scripting)", remove, removed, scripted: true)
        let (stillIn, removeWait) = try waitMember(a, false)
        report.check("6", "A not a member after removeMember (CNContactStore)", !stillIn, String(format: "after %.1fs", removeWait))
    }

    func step7() throws {
        report.say("\n# 7. B (noted): image and birthday are not scriptable → skipped, nothing written")
        let png = try Snapshot.makeTestPNG()
        for (title, edit, field) in [
            ("B image", CardEdit.image(png), "image"), ("B birthday", CardEdit.birthday(.monthDay(month: 6, day: 16)), "birthday"),
        ] {
            let before = try cardNow(b)
            let operations: [AppleWriteOperation] = [.update(cardID: b, edits: [edit])]
            let result = try apply("7", title, operations, expect: .none)
            let skip = result.skipped.first { $0.edit == edit }
            report.check(
                "7", "\(field) reported skipped (unapplyable) by the write result",
                skip.map { $0.reason.hasPrefix(CardScriptingSupport.reason) } ?? false, skip?.reason ?? "not in skipped")
            report.check(
                "7", "\(field): operation routed via scripting", operations.allSatisfy(result.scripted.contains),
                "scripted \(result.scripted.count)")
            let after = try cardNow(b)
            let changed = RowDiff.align(Snapshot.rows(of: before), Snapshot.rows(of: after)).filter(\.changed)
            report.check(
                "7", "\(field): nothing written (CN unchanged)", changed.isEmpty,
                changed.isEmpty
                    ? "imageDataAvailable \(after.imageDataAvailable), birthday \(after.birthday.map(Snapshot.render(date:)) ?? "none")"
                    : changed.map { "\($0.field) \($0.before?.value ?? "∅") -> \($0.after?.value ?? "∅")" }.joined(separator: "; "))
        }
    }

    func step8(cnBefore: Set<String>, overallToken: Data?) throws {
        report.say("\n# 8. History and side effects")
        for batch in batches {
            guard batch.historyRead else {
                report.check("8", "\(batch.title): history", .skip, "no history token / unreadable")
                continue
            }
            for target in batch.targets {
                let names = batch.events[target] ?? []
                let updates = names.filter { $0 == "UpdateContactEvent" }.count
                let outcome: S13Report.Outcome
                switch batch.expectation {
                case .exactlyOne: outcome = updates == 1 ? .pass : updates == 0 ? .fail : .warn
                case .atMostOne: outcome = updates <= 1 ? .pass : .warn
                case .none: outcome = updates == 0 ? .pass : .fail
                }
                report.check(
                    "8", "\(batch.step) \(batch.title): UpdateContactEvent on \(name(target)) = \(batch.expectation.rawValue)",
                    outcome, Self.summary(names))
            }
            let untouched = everIDs.subtracting(batch.targets).filter { !(batch.events[$0] ?? []).isEmpty }
            if !untouched.isEmpty {
                report.check(
                    "8", "\(batch.step) \(batch.title): no events on the other S16 card", .warn,
                    untouched.map { "\(name($0)): \(Self.summary(batch.events[$0] ?? []))" }.joined(separator: "; "))
            }
            if batch.otherCards > 0 {
                report.check(
                    "8", "\(batch.step) \(batch.title): no events on non-harness cards", .warn,
                    "\(batch.otherCards) other card(s) (ids not printed; concurrent sync or edits?)")
            }
        }
        if let overallToken {
            let (_, others, readOK) = history(since: overallToken, waitFor: [])
            report.check(
                "8", "whole run: no history events on non-harness cards", !readOK ? .skip : others == 0 ? .pass : .warn,
                readOK ? "\(others) non-harness card(s) with events (ids not printed)" : "unreadable")
        }
        let cnAfter = try S12Notes.Probe.cnIDs(store, unify: false)
        report.check(
            "8", "no card added or removed", cnAfter == cnBefore,
            "before \(cnBefore.count), after \(cnAfter.count), +\(cnAfter.subtracting(cnBefore).count) "
                + "-\(cnBefore.subtracting(cnAfter).count)")
        for kind in S16Kind.allCases {
            let member = try isMember(ids[kind]!)
            report.check("8", "\(kind.short) not left in the group", !member)
        }
        report.say(
            "applied batches: \(applyLog.entries.count); route log: \(router.log.scriptedAttempted) scripted attempted, "
                + "\(router.log.scriptedApplied) applied, \(router.log.retriedAfterRejection) retried after 134092, "
                + "\(router.log.held) held")
    }

    static func summary(_ names: [String]) -> String {
        guard !names.isEmpty else { return "no events" }
        return Dictionary(grouping: names, by: { $0 }).map { "\($0.key)×\($0.value.count)" }.sorted()
            .joined(separator: ", ")
    }

    func step9() throws {
        report.say("\n# 9. Notes at the end (provider read, hashes only)")
        let wanted = [a, b]
        let read = try run.session.call { try $0.readAll(cardIDs: wanted) }
        let (outcome, detail) = S14Text.fidelity(setup.note, read[b] ?? nil)
        report.check("9", "B note intact at end", outcome, "\(detail); sha256 \(S14Text.hash(read[b] ?? nil))")
        report.check("9", "A still has no note", !S14Text.isNonEmpty(read[a] ?? nil))
    }

    // MARK: Contacts.app lifecycle

    /// The session has `quitWhenDone: false`, so `finishSession()` never quits
    /// Contacts.app; the harness quits it itself when the run launched it and
    /// it is still hidden, so Contacts.app is left as found.
    func finishLifecycle() {
        guard !lifecycleDone else { return }
        lifecycleDone = true
        report.say("\n## Contacts.app lifecycle")
        do {
            try run.session.call { $0.finishSession() }
        } catch {
            report.check("8", "finishSession()", false, describe(error))
        }
        var now = ContactsAppState.now()
        report.say("Contacts.app before the run: \(appBefore); after finishSession() (quitWhenDone: false): \(now)")
        if !appBefore.running, now.running {
            guard now.hidden, !now.active else {
                report.check("8", "Contacts.app left as found", .warn, "launched by the run but now in use; left running (\(now))")
                return
            }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: ContactsScriptingEvents.bundleID) {
                app.terminate()
            }
            let deadline = Date().addingTimeInterval(10)
            while now.running, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                now = ContactsAppState.now()
            }
            report.check("8", "Contacts.app left as found (not running; quit by the harness)", !now.running, "\(now)")
        } else {
            report.check("8", "Contacts.app left as found", now.running == appBefore.running, "\(appBefore) -> \(now)")
        }
    }

    // MARK: Results

    func writeResults() {
        guard attempted else { return }
        var table = MarkdownTable(headers: ["Step", "Batch", "Targets", "Expected UpdateContactEvent", "Events", "Other cards"])
        for batch in batches {
            table.rows.append([
                batch.step, batch.title, batch.targets.map(name).joined(separator: ", "), batch.expectation.rawValue,
                batch.historyRead
                    ? batch.targets.map { "\(name($0)): \(Self.summary(batch.events[$0] ?? []))" }.joined(separator: "; ")
                    : "unread",
                "\(batch.otherCards)",
            ])
        }
        report.say("\n## Batches (history window per batch)\n")
        report.say(table.render())
        run.writeReport(name: "s16-\(Stamp.file()).md", title: "S16 run \(Stamp.iso()) (setup \(setup.short))")
    }
}
