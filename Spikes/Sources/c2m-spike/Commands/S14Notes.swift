import AppKit
import ArgumentParser
import ContactModel
import Contacts
import ContactsAdapter
import Foundation

/// S14: the PRODUCTION notes provider (`ScriptingNotesProvider`: raw Apple
/// Events, `ContactsScriptingEvents`, `LiveContactsApp`) against the real
/// Contacts.app.
///
/// - `check` is read-only: permission and availability, bulk and per-card
///   reads, parity with the S12 `NSAppleScript` reader (per-card SHA-256
///   hashes only; note text is never printed), and the Contacts.app
///   launch/quit lifecycle.
/// - `write --yes` writes only to harness scratch cards. Every
///   `provider.write` goes through `S14NotesGuard`, which re-fetches each
///   target card from CNContactStore (`unifyResults = false`) and asks
///   Contacts.app for the same person's name and URLs; both must show the
///   `ZZ Spike ` prefix and the card's marker, with an allowed spike tag
///   (`s14`; `s13` only for the reused S13 linked pair). The one id that is
///   not a harness card is the bogus id of case 5, which must provably not
///   exist on either side before it is sent.
struct S14Notes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s14-notes",
        abstract: "S14: the production ScriptingNotesProvider against the real Contacts.app (scratch cards only).",
        discussion: """
            check         read-only: permission, availability, bulk + per-card reads, parity with the S12 \
            NSAppleScript reader (hashes only), Contacts.app lifecycle → results/s14-check-<date>.md
            write --yes   scripted provider writes on "ZZ Spike S14 …" cards (and a linked harness pair) \
            → results/s14-write-<date>.md
            Clean up with: c2m-spike cleanup --spike s14 --yes
            """,
        subcommands: [Check.self, Write.self])

    static let spike = "s14"
    /// File the injection-shaped bogus id would create if it were ever run as script.
    static let injectionProbeFile = "/tmp/c2m-spike-s14-injected"

    // MARK: - check

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only: exercise the provider's reads and lifecycle; compare with NSAppleScript (hashes).",
            discussion: """
                Launches Contacts.app hidden if it is not running (through the provider) and lets \
                finishSession() quit it. Prints counts, timings, opaque card ids and hash comparisons only.
                """)

        @Option(help: "Real cards in the per-card read sample (1–39; one bogus id is added to reach 40).")
        var sample = 39

        @Flag(help: "If Automation was never decided, call provider.requestPermission() (shows the macOS prompt once).")
        var requestPermission = false

        func run() throws {
            try runReporting {
                let run = S14Run(title: "s14-notes check")
                defer { run.writeReport(name: "s14-check-\(Stamp.file()).md", title: "S14 check \(Stamp.iso())") }
                try run.body { try check(run) }
                if run.report.counts[.fail, default: 0] > 0 { throw ExitCode(1) }
            }
        }

        private func check(_ run: S14Run) throws {
            let report = run.report
            let store = try Access.authorizedStore()
            let cnIDs = try S12Notes.Probe.cnIDs(store, unify: false)
            report.say("CNContactStore underlying cards: \(cnIDs.count)")

            defer { run.finishLifecycle() }
            guard try run.start(requestPermission: requestPermission) else { return }

            // Bulk, every card (nil).
            report.say("\n## Bulk read: readAll(cardIDs: nil)")
            let (all, allTime) = try run.session.timed { try $0.readAll(cardIDs: nil) }
            let nonEmpty = all.values.filter { S14Text.isNonEmpty($0) }.count
            report.say(
                String(
                    format: "read %d cards in %.2fs (non-empty %d, nil %d)", all.count, allTime, nonEmpty,
                    all.values.filter { $0 == nil }.count))
            report.check("1", "bulk read returns notes", !all.isEmpty, "\(all.count) cards, \(nonEmpty) non-empty")
            report.check(
                "1", "bulk read under 5 s", allTime < 5,
                String(format: "%.2fs (includes the readiness probe on first use)", allTime))
            let providerIDs = Set(all.keys)
            report.check(
                "1", "Contacts.app ids round-trip to CN card ids", providerIDs == cnIDs,
                "provider \(providerIDs.count), CN \(cnIDs.count), provider-only \(providerIDs.subtracting(cnIDs).count), "
                    + "CN-only \(cnIDs.subtracting(providerIDs).count)")

            // Bulk, explicit list of every CN card id (> threshold → bulk + filter).
            report.say("\n## Bulk read: readAll(cardIDs: <every CN card id>)")
            let (listed, listedTime) = try run.session.timed { try $0.readAll(cardIDs: cnIDs.sorted()) }
            report.say(String(format: "read %d of %d cards in %.2fs", listed.count, cnIDs.count, listedTime))
            report.check(
                "2", "every CN card id seen", Set(listed.keys) == cnIDs,
                "missing \(cnIDs.subtracting(listed.keys).count)")
            let listedParity = S14Text.parity(listed, all)
            report.check("2", "same notes as readAll(nil) (hashes)", listedParity.isEqual, listedParity.detail)

            // Parity with the S12 NSAppleScript reader.
            report.say("\n## Parity with the S12 NSAppleScript bulk read (per-card SHA-256)")
            let scripting = try run.scripting()
            let (script, scriptTime) = try S14Text.measure { try S14Text.appleScriptBulk(scripting) }
            report.say(String(format: "NSAppleScript: %d cards in %.2fs", script.count, scriptTime))
            let scriptParity = S14Text.parity(all, script)
            report.check("3", "provider bulk == NSAppleScript bulk (ids)", Set(all.keys) == Set(script.keys),
                "provider \(all.count), NSAppleScript \(script.count)")
            report.check("3", "provider bulk == NSAppleScript bulk (note hashes)", scriptParity.isEqual,
                scriptParity.detail)
            report.say("  digest provider:      \(S14Text.digest(all))")
            report.say("  digest NSAppleScript: \(S14Text.digest(script))")

            // Per-card path: ≤ 40 ids, one event each, plus an id that does not exist.
            report.say("\n## Per-card read: readAll(cardIDs: <\(max(1, min(sample, 39))) random + 1 bogus>)")
            let picks = Array(cnIDs.shuffled().prefix(max(1, min(sample, 39))))
            let bogus = "ZZ-SPIKE-S14-NO-SUCH-CARD-\(UUID().uuidString):ABPerson"
            let wanted = picks + [bogus]
            let (some, someTime) = try run.session.timed { try $0.readAll(cardIDs: wanted) }
            report.say(
                String(
                    format: "read %d of %d ids in %.2fs (%.1f ms per id)", some.count, wanted.count, someTime,
                    someTime * 1000 / Double(wanted.count)))
            report.check("4", "every sampled card returned", picks.allSatisfy { some[$0] != nil },
                "\(picks.filter { some[$0] != nil }.count)/\(picks.count)")
            let sampleParity = S14Text.parity(some.filter { $0.key != bogus }, all.filter { picks.contains($0.key) })
            report.check("4", "per-card notes == bulk notes (hashes)", sampleParity.isEqual, sampleParity.detail)
            report.check("4", "unknown id is absent (unknown), not empty", some[bogus] == nil,
                some[bogus] == nil ? "absent" : "present")

            // > threshold but not every card: bulk read, filtered.
            let fortyOne = Array(cnIDs.shuffled().prefix(41))
            if fortyOne.count == 41 {
                let (filtered, filteredTime) = try run.session.timed { try $0.readAll(cardIDs: fortyOne) }
                let filteredParity = S14Text.parity(filtered, all.filter { fortyOne.contains($0.key) })
                report.check(
                    "5", "41 ids (bulk + filter) == bulk notes", Set(filtered.keys) == Set(fortyOne)
                        && filteredParity.isEqual,
                    String(format: "%d returned in %.2fs; %@", filtered.count, filteredTime, filteredParity.detail))
            }
        }
    }

    // MARK: - write

    struct Write: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write notes through the production provider to S14 scratch cards (guarded); dry run without --yes.",
            discussion: """
                Without --yes nothing is created and no Apple Event is sent. With --yes: creates (if missing) \
                "ZZ Spike S14 Notes <id>" in iCloud, and an iCloud + Google "ZZ Spike S14 Linked <id>" pair when \
                no linked harness pair (S14, else S13) exists; then runs the five cases and writes \
                results/s14-write-<date>.md.
                """)

        @OptionGroup var containerOptions: ContainerOptions

        @Flag(help: "Create the scratch cards and perform the writes.")
        var yes = false

        func run() throws {
            try runReporting {
                let run = S14Run(title: "s14-notes write")
                defer {
                    if run.attempted {
                        run.writeReport(name: "s14-write-\(Stamp.file()).md", title: "S14 write \(Stamp.iso())")
                    }
                }
                try run.body { try write(run) }
                if run.report.counts[.fail, default: 0] > 0 { throw ExitCode(1) }
            }
        }

        // MARK: plan

        private func write(_ run: S14Run) throws {
            let report = run.report
            let store = try Access.authorizedStore()
            let scan = try HarnessScan.run(store)
            let solo = scan.harness(spike: S14Notes.spike).filter {
                Harness.marker($0).flatMap(Harness.kindTag) == "solo"
            }
            let pair = try S14Pair.findLinked(store, scan: scan)
            let s14PairCards = scan.harness(spike: S14Notes.spike).filter {
                ["icloud", "google"].contains(Harness.marker($0).flatMap(Harness.kindTag))
            }
            let createPair = pair == nil && s14PairCards.isEmpty
            var icloud: CNContainer?
            var google: CNContainer?
            if solo.isEmpty || createPair { icloud = try containerOptions.resolve(.icloud, in: store) }
            if createPair { google = try containerOptions.resolve(.google, in: store) }
            let short = Stamp.short()

            var plan: [String] = []
            if let card = solo.first {
                plan.append("use S14 solo card \"\(Harness.displayName(card))\" identifier=\(card.identifier)")
            } else {
                plan.append("create \"ZZ Spike S14 Notes \(short)\" in iCloud container \(icloud!.identifier) (SafeWriter)")
            }
            if let pair {
                plan.append(
                    "use linked \(pair.spike) harness pair \"\(Harness.displayName(pair.cards[0]))\": "
                        + pair.cards.map(\.identifier).joined(separator: ", ")
                        + (pair.spike == S13Writes.spike ? " (its notes are restored afterwards)" : ""))
            } else if createPair {
                plan.append(
                    "create \"ZZ Spike S14 Linked \(short)\" in iCloud \(icloud!.identifier) and Google "
                        + "\(google!.identifier) (same name + email); case 4 is SKIPPED until Contacts links them")
            } else {
                plan.append("S14 pair exists but is not linked yet: case 4 is SKIPPED (wait ~15 min or link by hand)")
            }
            plan += [
                "every provider.write: re-verify each target on CNContactStore AND in Contacts.app (name prefix + "
                    + "marker, spike tag s14\(pair?.spike == S13Writes.spike ? "; s13 for the reused pair" : "")); "
                    + "refuse otherwise",
                "case 1: multi-line Unicode note (quotes, backslashes, emoji, CRLF) → read back via provider and "
                    + "NSAppleScript, exact",
                "case 2: ~49,000-character note → exact",
                "case 3: clear (nil) → reads back nil/empty",
                "case 4: one provider.write with the same note for both linked cards → both read back",
                "case 5: an injection-shaped id that exists nowhere → per-card failure, nothing changes",
                "then: case-1 note left on the solo card for an off-device check; CN identifiers, fields, history "
                    + "and every other card's note (hashes) compared before/after",
            ]
            guard confirmPlan("s14-notes write", plan, yes: yes) else { return }
            run.attempted = true

            // MARK: create scratch cards

            let writer = SafeWriter(store: store)
            var soloID = solo.first?.identifier
            if soloID == nil, let icloud {
                let (card, marker) = Harness.newCard(spike: S14Notes.spike, kind: "solo", suffix: "Notes \(short)")
                soloID = try S14Pair.create(store, writer, card, marker: marker, kind: "solo", container: icloud)
                report.say("created S14 solo card identifier=\(soloID!)")
            }
            if createPair, let icloud, let google {
                let email = "zz-spike-s14-\(short.lowercased())@example.invalid"
                for (kind, container) in [(AccountKind.icloud, icloud), (AccountKind.google, google)] {
                    let (card, marker) = Harness.newCard(
                        spike: S14Notes.spike, kind: kind.rawValue, suffix: "Linked \(short)")
                    card.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
                    let id = try S14Pair.create(store, writer, card, marker: marker, kind: kind.rawValue, container: container)
                    report.say("created S14 \(kind.rawValue) pair card identifier=\(id)")
                }
            }
            guard let soloID else { throw SpikeError("No S14 solo card.") }

            // MARK: provider session

            defer { run.finishLifecycle() }
            guard try run.start(requestPermission: false) else { return }
            let scripting = try run.scripting()
            let guardCheck = S14NotesGuard(store: store, scripting: scripting)

            report.say("\n## Contacts.app sees the solo card")
            let visible = try run.waitUntilVisible(soloID)
            report.check("0", "solo card resolves in Contacts.app", visible, soloID)
            guard visible else { return }

            // Baseline.
            let pairIDs = pair?.cards.map(\.identifier) ?? []
            let targets = [soloID] + pairIDs
            let cnBefore = try S12Notes.Probe.cnIDs(store, unify: false)
            let rowsBefore = try S14Snapshot.rows(store, targets)
            let unifiedBefore = try pair.map { try S14Pair.unifiedID(store, $0.cards[0].identifier) }
            let token = store.currentHistoryToken
            let notesBefore = try run.session.call { try $0.readAll(cardIDs: nil) }
            report.say("baseline: \(cnBefore.count) cards, \(notesBefore.count) notes read, \(targets.count) target card(s)")
            try? FileManager.default.removeItem(atPath: S14Notes.injectionProbeFile)

            let cases = S14Cases(run: run, guardCheck: guardCheck, scripting: scripting)
            let unicode = S14Text.unicodeNote(Stamp.iso())

            try cases.exact("1", "multi-line Unicode note (CRLF, quotes, backslashes, emoji)", soloID, unicode)
            try cases.exact("2", "~49k-character note", soloID, S14Text.longNote())
            try cases.clear("3", soloID)
            if let pair {
                try cases.linked("4", pair)
            } else {
                report.check("4", "linked pair write", .skip, "no linked harness pair yet; re-run once linked")
            }
            try cases.bogus("5", allCardIDs: cnBefore)
            try cases.exact("6", "leave the case-1 note on the solo card (off-device check)", soloID, unicode)

            // MARK: CN side after

            report.say("\n## CNContactStore after the provider writes")
            Thread.sleep(forTimeInterval: 1)
            let rowsAfter = try S14Snapshot.rows(store, targets)
            for id in targets {
                guard let before = rowsBefore[id] else { continue }
                guard let after = rowsAfter[id] else {
                    report.check("7", "card \(id) still resolves (identifier unchanged)", false, "not found")
                    continue
                }
                report.check("7", "card \(id) identifier unchanged and still a harness card", after.harness)
                let diffs = RowDiff.align(before.rows, after.rows).filter(\.changed)
                report.check(
                    "7", "card \(id) other fields unchanged", diffs.isEmpty,
                    diffs.map { "\($0.field): \($0.before?.value ?? "∅") -> \($0.after?.value ?? "∅")" }
                        .joined(separator: "; "))
            }
            if let pair, let unifiedBefore {
                let unifiedAfter = try S14Pair.unifiedID(store, pair.cards[0].identifier)
                report.check("7", "linked pair: unified id unchanged", unifiedAfter == unifiedBefore,
                    "\(unifiedBefore) -> \(unifiedAfter)")
            }
            let cnAfter = try S12Notes.Probe.cnIDs(store, unify: false)
            report.check(
                "7", "no card added or removed", cnAfter == cnBefore,
                "before \(cnBefore.count), after \(cnAfter.count)")
            do {
                let history = try store.c2mspike_history(
                    since: token, excludingAuthors: [], unify: false, includeGroups: false)
                let byCard = Dictionary(grouping: history.events.compactMap { event in
                    S3History.contactID(event).map { ($0, S3History.eventName(event)) }
                }, by: \.0)
                report.say("change history since the baseline token (unify=false): \(history.events.count) events")
                for id in targets {
                    report.say("  \(id): \(byCard[id]?.map(\.1).joined(separator: ", ") ?? "no events")")
                }
                report.check("7", "history events on target cards", targets.contains { byCard[$0] != nil })
                let others = byCard.keys.filter { !targets.contains($0) }
                report.check(
                    "7", "history events only on target cards", others.isEmpty ? .pass : .warn,
                    others.isEmpty ? "" : "\(others.count) other card(s) (concurrent sync or edits?)")
            } catch {
                report.check("7", "change history readable", .warn, describe(error))
            }
            let notesAfter = try run.session.call { try $0.readAll(cardIDs: nil) }
            let untouched = notesBefore.filter { !targets.contains($0.key) }
            let changed = untouched.keys.filter { S14Text.hash(notesAfter[$0] ?? nil) != S14Text.hash(untouched[$0]!) }
            report.check(
                "7", "every other card's note unchanged (hashes)", changed.isEmpty ? .pass : .warn,
                changed.isEmpty
                    ? "\(untouched.count) cards"
                    : "\(changed.count) changed (concurrent edits?): \(changed.sorted().prefix(5).joined(separator: ", "))")
            report.check(
                "7", "injection payload never ran", !FileManager.default.fileExists(atPath: S14Notes.injectionProbeFile),
                S14Notes.injectionProbeFile)

            report.say(
                """

                Verify off-device (1–5 min): iCloud.com and iPhone → the S14 solo card shows the case-1 note
                (emoji, quotes, line breaks).\(pair == nil ? "" : " The linked pair's notes: see case 4.")
                Then: c2m-spike cleanup --spike s14 --yes
                """)
        }
    }
}

// MARK: - Run context

/// Report, provider session and Contacts.app lifecycle for one command.
final class S14Run {
    let report = S13Report()
    let session: S14Session
    private var appBefore = ContactsAppState.now()
    private var appAfterStart: ContactsAppState?
    private var scriptingInstance: ContactsScripting?
    /// Something was written or tried (the report is worth keeping).
    var attempted = false

    /// `session`: S16 passes one over a shared `ContactsAppSession` (the card writer's).
    init(title: String, session: S14Session = S14Session()) {
        self.session = session
        report.say("c2m-spike \(title)  \(Stamp.iso())")
    }

    /// Runs `body`; a thrown error becomes a FAIL row (and is rethrown).
    func body(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as ExitCode {
            throw error
        } catch {
            report.check("!", "aborted", false, describe(error))
            throw error
        }
    }

    /// The S12 NSAppleScript reader (main thread only), for parity and the guard.
    func scripting() throws -> ContactsScripting {
        if let scriptingInstance { return scriptingInstance }
        let made = try ContactsScripting()
        scriptingInstance = made
        return made
    }

    /// Permission and availability through the provider. Returns false (after
    /// a FAIL row) when notes cannot be used.
    func start(requestPermission: Bool) throws -> Bool {
        appBefore = ContactsAppState.now()
        report.say("\n## Permission and availability")
        report.say("Contacts.app before: \(appBefore)")
        let permission = session.provider.currentPermission()
        let afterPermission = ContactsAppState.now()
        report.check(
            "0", "currentPermission() launches nothing", afterPermission.running == appBefore.running,
            "\(permission.rawValue)")
        if !appBefore.running {
            report.check("0", "currentPermission() is unknown while Contacts.app is not running", permission == .unknown,
                permission.rawValue)
        }
        var availability = try session.call { $0.availability() }
        appAfterStart = ContactsAppState.now()
        report.say("availability(): \(S14Text.text(availability))")
        report.say("Contacts.app after availability(): \(appAfterStart!)")
        if requestPermission, availability == .scripting(.notDetermined) {
            report.say("requestPermission(): the macOS \"control Contacts\" prompt may appear now")
            availability = try session.call { $0.requestPermission() }
            report.say("requestPermission(): \(S14Text.text(availability))")
        }
        if !appBefore.running, let after = appAfterStart, after.running {
            report.check("0", "Contacts.app launched hidden, not frontmost", after.hidden && !after.active, "\(after)")
        }
        let usable = availability == .scripting(.granted)
        report.check("0", "availability() == scripting(granted)", usable, S14Text.text(availability))
        if !usable {
            report.say(
                """
                Notes are not usable. Allow it in System Settings ▸ Privacy & Security ▸ Automation ▸ <terminal> ▸ \
                Contacts, or run `c2m-spike s14-notes check --request-permission` once to get the prompt.
                """)
        }
        return usable
    }

    /// Resolves once Contacts.app answers for `id` (a just-created card may lag).
    func waitUntilVisible(_ id: String, timeout: TimeInterval = 20) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let read = try session.call { try $0.readAll(cardIDs: [id]) }
            if read[id] != nil { return true }
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// `finishSession()` and what it did to Contacts.app.
    func finishLifecycle() {
        report.say("\n## finishSession()")
        let beforeFinish = ContactsAppState.now()
        do {
            try session.call { $0.finishSession() }
        } catch {
            report.check("L", "finishSession()", false, describe(error))
            return
        }
        let launchedByProvider = !appBefore.running && (appAfterStart?.running ?? false)
        var after = ContactsAppState.now()
        if launchedByProvider {
            let deadline = Date().addingTimeInterval(10)
            while after.running, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                after = ContactsAppState.now()
            }
        }
        report.say("Contacts.app before finishSession(): \(beforeFinish); after: \(after)")
        if launchedByProvider {
            if beforeFinish.hidden && !beforeFinish.active {
                report.check("L", "launched by the provider → quit by finishSession()", !after.running, "\(after)")
            } else {
                report.check(
                    "L", "launched by the provider but now in use → left running", after.running ? .pass : .warn,
                    "\(beforeFinish) -> \(after)")
            }
        } else if appBefore.running {
            report.check("L", "Contacts.app was already running → left running", after.running, "\(after)")
        } else {
            report.check("L", "Contacts.app never launched", .info, "\(after)")
        }
    }

    func writeReport(name: String, title: String) {
        report.say("\n## Summary: \(report.summary)")
        report.say(report.table.render())
        do {
            let url = try report.write(name, title: title)
            print("\nwrote \(url.path)")
        } catch {
            stderrLine("could not write the report: \(describe(error))")
        }
    }
}

/// The production provider, called off the main thread (as the app does)
/// while the main run loop keeps turning (NSWorkspace / NSRunningApplication).
final class S14Session: Sendable {
    let provider: ScriptingNotesProvider

    init(provider: ScriptingNotesProvider = ScriptingNotesProvider()) {
        self.provider = provider
    }

    func call<T: Sendable>(_ body: @escaping @Sendable (ScriptingNotesProvider) throws -> T) throws -> T {
        let provider = self.provider
        let box = S14ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = Result { try body(provider) }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return try box.result!.get()
    }

    func timed<T: Sendable>(_ body: @escaping @Sendable (ScriptingNotesProvider) throws -> T) throws -> (T, Double) {
        let start = Date()
        let value = try call(body)
        return (value, Date().timeIntervalSince(start))
    }
}

/// Hands a result from the worker thread to the main thread (ordered by the semaphore).
final class S14ResultBox<T>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

/// Contacts.app process state (fresh query each time).
struct ContactsAppState: CustomStringConvertible {
    var running: Bool
    var hidden: Bool
    var active: Bool

    static func now() -> ContactsAppState {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: ContactsScriptingEvents.bundleID)
            .filter { !$0.isTerminated }
        return ContactsAppState(
            running: !apps.isEmpty, hidden: !apps.isEmpty && apps.allSatisfy(\.isHidden),
            active: apps.contains(where: \.isActive))
    }

    var description: String { running ? "running (hidden \(hidden), frontmost \(active))" : "not running" }
}

// MARK: - Guard

/// The only way S14 reaches `provider.write`. Nothing is written by the checks.
struct S14NotesGuard {
    let store: CNContactStore
    let scripting: ContactsScripting

    /// Every id must be a harness card of an allowed spike on CNContactStore
    /// (fresh fetch, unified results off) AND, in Contacts.app, a person with
    /// the same id, the `ZZ Spike ` prefix and the same marker URL.
    func checkTargets(_ ids: [String], allowedSpikes: Set<String>) throws {
        guard !ids.isEmpty else { throw SpikeError("SAFETY: no target ids.") }
        for id in ids {
            guard let card = try fetchUnderlying(store, id: id, keys: []) else {
                throw SpikeError("SAFETY: card \(id) not found in CNContactStore; refusing the whole write.")
            }
            guard Harness.isHarness(card), let marker = Harness.marker(card) else {
                throw SpikeError("SAFETY: card \(id) is not a harness card (name prefix + marker); refusing the whole write.")
            }
            guard let tag = Harness.spikeTag(marker), allowedSpikes.contains(tag) else {
                throw SpikeError(
                    "SAFETY: card \(id) is a harness card of spike \(Harness.spikeTag(marker) ?? "?"), not "
                        + "\(allowedSpikes.sorted().joined(separator: "/")); refusing the whole write.")
            }
            let identity: ContactsScripting.Identity
            do {
                identity = try scripting.identity(of: id)
            } catch {
                throw SpikeError("SAFETY: Contacts.app cannot resolve person \(id) (\(describe(error))); refusing.")
            }
            guard identity.id == id, identity.looksLikeHarness, identity.urls.contains(marker) else {
                throw SpikeError(
                    "SAFETY: Contacts.app person \(id) does not show the harness name prefix and marker; refusing.")
            }
        }
    }

    /// The bogus id of case 5 must exist nowhere: not a CN card id, not in
    /// the full CN id list, and `person id <it>` must not resolve in Contacts.app.
    func checkNonexistent(_ id: String, allCardIDs: Set<String>) throws {
        guard !allCardIDs.contains(id), try fetchUnderlying(store, id: id, keys: []) == nil else {
            throw SpikeError("SAFETY: bogus id \(id) exists in CNContactStore; refusing.")
        }
        do {
            _ = try scripting.identity(of: id)
        } catch let error as ContactsScripting.ScriptError where error.isNoSuchObject {
            return
        } catch {
            throw SpikeError("SAFETY: could not prove bogus id absent in Contacts.app (\(describe(error))); refusing.")
        }
        throw SpikeError("SAFETY: bogus id \(id) resolves to a Contacts.app person; refusing.")
    }
}

// MARK: - Write cases

struct S14Cases {
    let run: S14Run
    let guardCheck: S14NotesGuard
    let scripting: ContactsScripting

    private var report: S13Report { run.report }

    /// Guard, then the production write. The guard throws before anything is sent.
    func guardedWrite(_ notes: [String: String?], allowedSpikes: Set<String> = [S14Notes.spike]) throws
        -> NotesWriteResult
    {
        try guardCheck.checkTargets(notes.keys.sorted(), allowedSpikes: allowedSpikes)
        return try run.session.call { try $0.write(notes) }
    }

    /// Reads one card through the provider (per-card path) and NSAppleScript.
    private func readBack(_ id: String) throws -> (provider: String??, script: String?) {
        let provider = try run.session.call { try $0.readAll(cardIDs: [id]) }
        return (provider[id], try scripting.note(of: id))
    }

    private func checkRead(_ step: String, _ label: String, written: String, read: String??) {
        guard let read else {
            report.check(step, "\(label): card seen", false, "absent from the read")
            return
        }
        let (outcome, detail) = S14Text.fidelity(written, read)
        report.check(step, label, outcome, detail)
    }

    func exact(_ step: String, _ name: String, _ id: String, _ text: String) throws {
        report.say("\n## Case \(step): \(name)")
        let (result, elapsed) = try S14Text.measure { try guardedWrite([id: text]) }
        report.check(
            step, "provider.write reports written", result.written == [id] && result.failed.isEmpty,
            String(format: "%.0f ms; failed: %@", elapsed * 1000, result.failed.description))
        let (provider, script) = try readBack(id)
        checkRead(step, "provider read-back == written (\(text.count) chars)", written: text, read: provider)
        checkRead(step, "NSAppleScript read-back == written", written: text, read: .some(script))
    }

    func clear(_ step: String, _ id: String) throws {
        report.say("\n## Case \(step): clear the note (nil)")
        let result = try guardedWrite([id: nil])
        report.check(step, "provider.write reports written", result.written == [id] && result.failed.isEmpty,
            "failed: \(result.failed)")
        let (provider, script) = try readBack(id)
        let providerEmpty = provider.map { ($0 ?? "").isEmpty } ?? false
        report.check(step, "provider reads nil/empty", providerEmpty,
            provider == nil ? "absent" : provider! == nil ? "nil" : "\(provider!!.count) chars")
        report.check(step, "NSAppleScript reads missing value/empty", (script ?? "").isEmpty,
            script == nil ? "missing value" : "\(script!.count) chars")
    }

    func linked(_ step: String, _ pair: S14Pair) throws {
        let ids = pair.cards.map(\.identifier)
        let allowed: Set<String> = [S14Notes.spike, pair.spike]
        report.say("\n## Case \(step): linked \(pair.spike) pair, one provider.write for both cards")
        for card in pair.cards { report.say("  \(Harness.marker(card).flatMap(Harness.kindTag) ?? "?") \(card.identifier)") }
        try guardCheck.checkTargets(ids, allowedSpikes: allowed)
        let original = try run.session.call { try $0.readAll(cardIDs: ids) }
        let sizes = ids.map { id -> String in
            guard let note = original[id] else { return "absent" }
            return note.map { "\($0.count) chars" } ?? "nil"
        }
        report.say("  notes before: " + sizes.joined(separator: ", "))
        let text = "c2m-spike S14 linked note \(Stamp.iso())\nsame text on both cards ✓ “quoted” \\ end"
        let both: [String: String?] = Dictionary(uniqueKeysWithValues: ids.map { ($0, Optional(text)) })
        let result = try guardedWrite(both, allowedSpikes: allowed)
        report.check(step, "provider.write reports both written", Set(result.written) == Set(ids) && result.failed.isEmpty,
            "written \(result.written.count), failed \(result.failed)")
        for id in ids {
            let (provider, script) = try readBack(id)
            checkRead(step, "\(id): provider read-back", written: text, read: provider)
            checkRead(step, "\(id): NSAppleScript read-back", written: text, read: .some(script))
        }
        guard pair.spike == S13Writes.spike else { return }
        // Put the S13 pair back as it was.
        let restore = ids.filter { original[$0] != nil }.map { ($0, original[$0]!) }
        guard !restore.isEmpty else {
            report.check(step, "S13 pair notes restored", .fail, "original notes unknown (cards not read)")
            return
        }
        let restored = try guardedWrite(Dictionary(uniqueKeysWithValues: restore), allowedSpikes: allowed)
        let after = try run.session.call { try $0.readAll(cardIDs: ids) }
        let same = restore.allSatisfy { S14Text.hash(after[$0.0] ?? nil) == S14Text.hash($0.1) }
        report.check(step, "S13 pair notes restored", same && restored.failed.isEmpty, "failed: \(restored.failed)")
    }

    func bogus(_ step: String, allCardIDs: Set<String>) throws {
        report.say("\n## Case \(step): injection-shaped id that exists nowhere")
        let id =
            "ZZ-SPIKE-S14-NO-SUCH-CARD-\(UUID().uuidString):ABPerson\" & (do shell script \"touch "
            + "\(S14Notes.injectionProbeFile)\") & \"\\\"; save; --"
        report.say("  id: \(id)")
        try guardCheck.checkNonexistent(id, allCardIDs: allCardIDs)
        let read = try run.session.call { try $0.readAll(cardIDs: [id]) }
        report.check(step, "provider read: absent (unknown), not empty", read[id] == nil)
        let result = try run.session.call { try $0.write([id: "c2m-spike S14 must never land"]) }
        report.check(
            step, "provider.write: per-card failure, nothing written", result.written.isEmpty && result.failed[id] != nil,
            result.failed[id] ?? "no failure reported")
        report.check(
            step, "failure is \"no such object\" (-1728)", result.failed[id]?.contains("-1728") == true ? .pass : .warn,
            result.failed[id] ?? "")
    }
}

// MARK: - Cards

/// A linked pair of harness cards (all members harness cards of one spike).
struct S14Pair {
    var spike: String
    var cards: [CNContact]

    /// Prefers an S14 pair, then the S13 linked pair.
    static func findLinked(_ store: CNContactStore, scan: HarnessScan) throws -> S14Pair? {
        let idKey = [CNContactIdentifierKey as any CNKeyDescriptor]
        var groups: [String: [CNContact]] = [:]
        for spike in [S14Notes.spike, S13Writes.spike] {
            for card in scan.harness(spike: spike) {
                let unified = try catchingObjC {
                    try store.unifiedContact(withIdentifier: card.identifier, keysToFetch: idKey)
                }
                groups[unified.identifier, default: []].append(card)
            }
        }
        let writer = SafeWriter(store: store)
        var found: [S14Pair] = []
        for (unifiedID, cards) in groups.sorted(by: { $0.key < $1.key }) where cards.count >= 2 {
            let tags = Set(cards.compactMap { Harness.marker($0).flatMap(Harness.spikeTag) })
            guard tags.count == 1, let spike = tags.first else { continue }
            let unified = try catchingObjC { try store.unifiedContact(withIdentifier: unifiedID, keysToFetch: idKey) }
            let members = try memberIDs(of: unified, in: store)
            guard Set(members) == Set(cards.map(\.identifier)) else {
                print("skipping linked group \(unifiedID): it has non-harness members")
                continue
            }
            for id in members { _ = try writer.verifiedCard(id, keys: []) }
            found.append(S14Pair(spike: spike, cards: cards.sorted { $0.identifier < $1.identifier }))
        }
        return found.first { $0.spike == S14Notes.spike } ?? found.first
    }

    static func unifiedID(_ store: CNContactStore, _ cardID: String) throws -> String {
        try catchingObjC {
            try store.unifiedContact(withIdentifier: cardID, keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor])
        }.identifier
    }

    static func create(
        _ store: CNContactStore, _ writer: SafeWriter, _ card: CNMutableContact, marker: String, kind: String,
        container: CNContainer
    ) throws -> String {
        try writer.add(card, to: container.identifier)
        guard let saved = try Harness.locate(store, marker: marker) else {
            throw SpikeError("Saved \(kind) card but could not find it again by marker.")
        }
        try Ledger.append(
            LedgerEntry(
                spike: S14Notes.spike, kind: kind, identifier: saved.identifier, marker: marker,
                containerID: container.identifier, createdAt: Stamp.iso()))
        return saved.identifier
    }
}

/// CN field rows of target cards (no note key).
enum S14Snapshot {
    struct Card {
        var rows: [FieldRow]
        var harness: Bool
    }

    static func rows(_ store: CNContactStore, _ ids: [String]) throws -> [String: Card] {
        var result: [String: Card] = [:]
        for id in ids {
            if let card = try fetchUnderlying(store, id: id, keys: Snapshot.keys) {
                result[id] = Card(rows: Snapshot.rows(of: card), harness: Harness.isHarness(card))
            }
        }
        return result
    }
}

// MARK: - Text, hashes, parity

enum S14Text {
    /// Multi-line, CRLF (plus one bare LF), quotes, backslashes, emoji, RTL.
    static func unicodeNote(_ stamp: String) -> String {
        [
            "c2m-spike S14 note \(stamp)",
            "\"double\" 'single' “curly” ‘quotes’ «guillemets»",
            "back\\slash \\n literal \\\" escaped-quote tab:\tend",
            "emoji 👩‍👩‍👧‍👦 🇯🇵 🏳️‍🌈 ✓ — é (e\u{301}) ñ 日本語 עברית العربية",
            "script-ish: \" & (count every person) & \" ; end tell --",
            "",
            "after a blank line",
        ].joined(separator: "\r\n") + "\nLF-only last line"
    }

    /// Deterministic ~49,000 characters (S12's longest real note: 49,152).
    static func longNote(target: Int = 49_000) -> String {
        var text = ""
        var line = 0
        while text.count < target {
            text += String(format: "%05d ", line) + "lorem ipsum dolor sit amet ✓ é 日本 “q” \\ end\n"
            line += 1
        }
        var trimmed = String(text.prefix(target))
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        return trimmed
    }

    static func isNonEmpty(_ note: String?) -> Bool {
        !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hash(_ note: String?) -> String {
        note.map { "t:" + sha256Hex($0) } ?? "nil"
    }

    /// One digest over sorted "id hash" lines (safe to print).
    static func digest(_ notes: [String: String?]) -> String {
        String(sha256Hex(notes.keys.sorted().map { "\($0) \(hash(notes[$0] ?? nil))" }.joined(separator: "\n")).prefix(16))
    }

    struct Parity {
        var onlyLeft: Int
        var onlyRight: Int
        var differ: [String]
        var same: Int

        var isEqual: Bool { onlyLeft == 0 && onlyRight == 0 && differ.isEmpty }
        var detail: String {
            "same \(same), differ \(differ.count)\(differ.isEmpty ? "" : " (\(differ.sorted().prefix(5).joined(separator: ", ")))"), "
                + "only-left \(onlyLeft), only-right \(onlyRight)"
        }
    }

    static func parity(_ left: [String: String?], _ right: [String: String?]) -> Parity {
        var result = Parity(onlyLeft: 0, onlyRight: 0, differ: [], same: 0)
        for (id, note) in left {
            guard let other = right[id] else {
                result.onlyLeft += 1
                continue
            }
            if hash(note) == hash(other) { result.same += 1 } else { result.differ.append(id) }
        }
        result.onlyRight = right.keys.filter { left[$0] == nil }.count
        return result
    }

    /// The S12 NSAppleScript bulk read (ids, notes, ids again).
    static func appleScriptBulk(_ scripting: ContactsScripting) throws -> [String: String?] {
        for _ in 0..<3 {
            let ids = try scripting.allIDs()
            let notes = try scripting.allNotes()
            guard try scripting.allIDs() == ids, ids.count == notes.count else { continue }
            var result: [String: String?] = [:]
            for (id, note) in zip(ids, notes) { result[id] = .some(note) }
            return result
        }
        throw SpikeError("Contacts changed during every NSAppleScript bulk read (3 attempts).")
    }

    /// Exact = same UTF-8 bytes. Only synthetic (harness) text is ever shown.
    static func fidelity(_ written: String, _ read: String?) -> (S13Report.Outcome, String) {
        guard let read else { return (.fail, "read nil (missing value)") }
        if written.utf8.elementsEqual(read.utf8) { return (.pass, "exact (\(read.utf8.count) UTF-8 bytes)") }
        let endings = "written CR \(count("\r", written)) LF \(count("\n", written)); "
            + "read CR \(count("\r", read)) LF \(count("\n", read))"
        if written == read { return (.warn, "canonically equal but bytes differ (Unicode normalization); \(endings)") }
        if AppleNoteText.body(fromNote: written) == AppleNoteText.body(fromNote: read) {
            return (.warn, "equal after line-ending/trailing-whitespace normalization; \(endings)")
        }
        let prefix = zip(written.unicodeScalars, read.unicodeScalars).prefix { $0 == $1 }.count
        return (.fail, "differs at scalar \(prefix); lengths \(written.count) vs \(read.count); \(endings)")
    }

    private static func count(_ scalar: Unicode.Scalar, _ text: String) -> Int {
        text.unicodeScalars.filter { $0 == scalar }.count
    }

    static func text(_ availability: NotesAvailability) -> String {
        switch availability {
        case .entitlement: "entitlement"
        case .scripting(let permission): "scripting(\(permission.rawValue))"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }

    static func measure<T>(_ body: () throws -> T) throws -> (T, Double) {
        let start = Date()
        let value = try body()
        return (value, Date().timeIntervalSince(start))
    }
}
