import ArgumentParser
import Contacts
import Foundation

/// S12: read/write the Contacts note through Contacts.app's AppleScript
/// dictionary instead of CNContactNoteKey (which needs the notes entitlement).
/// Read-only output is counts and timings only: note text and names are never
/// printed, except the synthetic note this tool writes to a scratch card.
struct S12Notes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s12-notes",
        abstract: "S12: Contacts notes via Apple Events to Contacts.app (no notes entitlement).",
        subcommands: [Probe.self, Write.self])

    static let spike = "s12"

    // MARK: - probe

    struct Probe: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only: bulk id+note fetch timing, per-person timing, id format vs CNContact ids.",
            discussion: """
                Sends Apple Events to Contacts.app (launching it if needed). The first run triggers the macOS \
                prompt "<terminal> wants to control Contacts". Prints counts and timings only.
                """)

        @Option(help: "Number of individual `note of person id X` calls to time.")
        var sample = 20

        @Flag(help: "Quit Contacts.app afterwards if this run launched it.")
        var quitIfLaunched = false

        func run() throws {
            try runReporting {
                print("c2m-spike s12-notes probe  \(Stamp.iso())")
                let store = try Access.authorizedStore()

                // CNContactStore side first (no Apple Events yet).
                let underlying = try Self.cnIDs(store, unify: false)
                let unified = try Self.cnIDs(store, unify: true)
                print("CNContactStore: underlying cards=\(underlying.count) unified contacts=\(unified.count)")

                let wasRunning = ContactsScripting.isContactsRunning
                print("Contacts.app running before: \(wasRunning ? "yes" : "no")")
                let pre = ContactsScripting.automationStatus()
                print("Automation permission (pre-check, no prompt): \(pre.meaning)")

                let scripting = try ContactsScripting()
                defer {
                    let nowRunning = ContactsScripting.isContactsRunning
                    print(
                        "Contacts.app running after: \(nowRunning ? "yes" : "no") (launched by this run: \(!wasRunning && nowRunning ? "yes" : "no"))"
                    )
                    if quitIfLaunched && !wasRunning && nowRunning {
                        ContactsScripting.quitContacts()
                        print("Contacts.app: terminate requested (--quit-if-launched)")
                    }
                }

                // Warm-up: launches Contacts and triggers the Automation prompt,
                // so the bulk timings below exclude both.
                let (count, warm) = try timed { try withPermissionHelp { try scripting.personCount() } }
                print(
                    String(
                        format: "warm-up `count every person`: %d people in %.2fs (includes launch/prompt)", count, warm
                    ))
                let post = ContactsScripting.automationStatus()
                print("Automation permission (after warm-up): \(post.meaning)")

                let (ids, idTime) = try timed { try scripting.allIDs() }
                let (notes, noteTime) = try timed { try scripting.allNotes() }
                print("\n## Bulk fetch")
                print(String(format: "`id of every person`:   %d ids   in %.2fs", ids.count, idTime))
                print(String(format: "`note of every person`: %d notes in %.2fs", notes.count, noteTime))
                print(String(format: "bulk total: %.2fs", idTime + noteTime))
                if ids.count != notes.count {
                    print("WARNING: id and note lists differ in length; the address book changed between calls?")
                }
                let nonEmpty = notes.filter { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let missing = notes.filter { $0 == nil }.count
                print(
                    "people=\(ids.count) non-empty notes=\(nonEmpty.count) empty/whitespace-only=\(notes.count - nonEmpty.count - missing) missing value=\(missing)"
                )
                let lengths = nonEmpty.map { $0!.count }.sorted()
                if let maxLength = lengths.last {
                    print("non-empty note length (chars): median=\(lengths[lengths.count / 2]) max=\(maxLength)")
                }
                let multiline = nonEmpty.filter { $0!.contains("\n") || $0!.contains("\r") }.count
                print("non-empty notes containing line breaks: \(multiline)")

                print("\n## Per-person fetch (`note of person id X`)")
                let picks = Array(ids.shuffled().prefix(max(0, sample)))
                var times: [Double] = []
                var failures: [String: Int] = [:]
                for id in picks {
                    do {
                        let (_, t) = try timed { try scripting.note(of: id) }
                        times.append(t)
                    } catch {
                        failures[describe(error), default: 0] += 1
                    }
                }
                if !times.isEmpty {
                    let sorted = times.sorted()
                    let mean = times.reduce(0, +) / Double(times.count)
                    print(
                        String(
                            format: "%d calls: min=%.1fms median=%.1fms max=%.1fms mean=%.1fms", times.count,
                            sorted.first! * 1000, sorted[sorted.count / 2] * 1000, sorted.last! * 1000, mean * 1000))
                    print(
                        String(
                            format: "extrapolated per-person read of %d people: %.1fs (vs bulk %.2fs)", ids.count,
                            mean * Double(ids.count), noteTime))
                }
                for (error, n) in failures { print("per-person failures: \(n) x \(error)") }

                Self.compareIDs(ids, underlying: underlying, unified: unified)
            }
        }

        static func cnIDs(_ store: CNContactStore, unify: Bool) throws -> Set<String> {
            var ids = Set<String>()
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor])
            request.unifyResults = unify
            try store.enumerateContacts(with: request) { contact, _ in ids.insert(contact.identifier) }
            return ids
        }

        /// Counts only. "linked" unified ids are the synthesized ones (not a card id).
        static func compareIDs(_ asIDs: [String], underlying: Set<String>, unified: Set<String>) {
            let asSet = Set(asIDs)
            let linkedUnified = unified.subtracting(underlying)
            var both = 0
            var cardOnly = 0
            var unifiedOnly = 0
            var neither = 0
            for id in asSet {
                switch (underlying.contains(id), unified.contains(id)) {
                case (true, true): both += 1
                case (true, false): cardOnly += 1
                case (false, true): unifiedOnly += 1
                case (false, false): neither += 1
                }
            }
            print("\n## AppleScript `id` vs CNContact identifiers")
            print("AppleScript ids: \(asIDs.count) (distinct \(asSet.count))")
            print(
                "format: ends with \":ABPerson\"=\(asSet.filter { $0.hasSuffix(":ABPerson") }.count) bare UUID=\(asSet.filter { UUID(uuidString: $0) != nil }.count) other=\(asSet.filter { !$0.hasSuffix(":ABPerson") && UUID(uuidString: $0) == nil }.count)"
            )
            print(
                "CN: underlying=\(underlying.count) unified=\(unified.count) linked (synthesized unified id)=\(linkedUnified.count)"
            )
            print("AS id = card id AND unified id (unlinked card):       \(both)")
            print("AS id = underlying card id only (member of a link):  \(cardOnly)")
            print("AS id = synthesized unified id only (linked contact): \(unifiedOnly)")
            print("AS id matches neither:                                \(neither)")
            print("CN unified contacts with no AS id:   \(unified.subtracting(asSet).count)")
            print("CN underlying cards with no AS id:   \(underlying.subtracting(asSet).count)")
            print(
                "linked contacts with an AS id equal to their unified id: \(linkedUnified.intersection(asSet).count)/\(linkedUnified.count)"
            )
            print(
                """
                Reading: AS persons == CN unified contacts when unifiedOnly ≈ linked count and cardOnly = 0;
                AS persons == underlying cards when cardOnly ≈ 2 x linked count and unifiedOnly = 0.
                """)
        }
    }

    // MARK: - write

    struct Write: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Write a note via AppleScript to a harness scratch card (or a linked harness pair with --linked).",
            discussion: """
                Without --linked: uses (or creates, in iCloud) a "ZZ Spike S12 Notes …" card.
                With --linked: uses a linked pair of harness cards (S12 or S4); if none exists, creates an \
                iCloud + Google S12 pair with the same name so Contacts links them automatically, then asks \
                you to re-run once they are linked. Dry run without --yes.
                """)

        @Flag(help: "Target a linked iCloud+Google harness pair instead of a single card.")
        var linked = false

        @OptionGroup var containerOptions: ContainerOptions

        @Flag(help: "Perform the creation and the write.")
        var yes = false

        func run() throws {
            try runReporting {
                print("c2m-spike s12-notes write\(linked ? " --linked" : "")  \(Stamp.iso())")
                let store = try Access.authorizedStore()
                let scan = try HarnessScan.run(store)
                if linked {
                    try runLinked(store, scan: scan)
                } else {
                    try runSingle(store, scan: scan)
                }
            }
        }

        // MARK: single card

        private func runSingle(_ store: CNContactStore, scan: HarnessScan) throws {
            let solo = scan.harness(spike: S12Notes.spike).filter {
                Harness.marker($0).flatMap(Harness.kindTag) == "solo"
            }
            guard let card = solo.first else {
                let icloud = try containerOptions.resolve(.icloud, in: store)
                let plan = [
                    "create \"ZZ Spike S12 Notes <id>\" in iCloud container \(icloud.identifier) (marker kind solo)",
                    "then re-run `c2m-spike s12-notes write` (dry run) and `--yes` to write the note",
                ]
                guard confirmPlan("s12-notes write: create scratch card", plan, yes: yes) else { return }
                let (new, marker) = Harness.newCard(
                    spike: S12Notes.spike, kind: "solo", suffix: "Notes \(Stamp.short())")
                let created = try createCard(store, new, marker: marker, kind: "solo", container: icloud)
                print("created S12 card identifier=\(created)")
                print("NEXT: c2m-spike s12-notes write          (dry run)\n      c2m-spike s12-notes write --yes")
                return
            }
            if solo.count > 1 { print("note: \(solo.count) S12 solo cards; using \(card.identifier)") }
            let unified = try catchingObjC {
                try store.unifiedContact(withIdentifier: card.identifier, keysToFetch: [])
            }
            let members = try memberIDs(of: unified, in: store)
            if members.count > 1 { print("note: the S12 solo card is linked to \(members.count - 1) other card(s)") }
            try writeTest(store, cards: [card], expectedName: Harness.displayName(card))
        }

        // MARK: linked pair

        private func runLinked(_ store: CNContactStore, scan: HarnessScan) throws {
            if let pair = try findLinkedPair(store, scan: scan) {
                try writeTest(store, cards: pair, expectedName: Harness.displayName(pair[0]))
                return
            }
            let s12Pair = scan.harness(spike: S12Notes.spike).filter {
                ["icloud", "google"].contains(Harness.marker($0).flatMap(Harness.kindTag))
            }
            if !s12Pair.isEmpty {
                print(
                    """
                    Found \(s12Pair.count) S12 pair card(s), but no linked harness pair yet.
                    Contacts links same-name iCloud/Google cards automatically (S4/S9: ~15 min after sync).
                    Wait, or in Contacts.app select both "ZZ Spike S12 Linked …" cards > Card > Link Selected Cards.
                    Then re-run: c2m-spike s12-notes write --linked [--yes]
                    """)
                return
            }
            let icloud = try containerOptions.resolve(.icloud, in: store)
            let google = try containerOptions.resolve(.google, in: store)
            let short = Stamp.short()
            let email = "zz-spike-s12-\(short.lowercased())@example.invalid"
            let plan = [
                "create \"ZZ Spike S12 Linked \(short)\" in iCloud container \(icloud.identifier)",
                "create \"ZZ Spike S12 Linked \(short)\" in Google container \(google.identifier) (same name + email \(email), so Contacts can auto-link)",
                "no note written in this step; re-run with --linked once the pair is linked",
            ]
            guard confirmPlan("s12-notes write --linked: create pair", plan, yes: yes) else { return }
            for (kind, container) in [(AccountKind.icloud, icloud), (AccountKind.google, google)] {
                let (card, marker) = Harness.newCard(
                    spike: S12Notes.spike, kind: kind.rawValue, suffix: "Linked \(short)")
                card.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
                let id = try createCard(store, card, marker: marker, kind: kind.rawValue, container: container)
                print("created \(kind.rawValue) identifier=\(id)")
            }
            print(
                """

                NEXT: wait ~15 min for sync + automatic linking (or link by hand in Contacts.app), then:
                  c2m-spike s12-notes write --linked          (dry run; shows whether linked)
                  c2m-spike s12-notes write --linked --yes
                """)
        }

        /// A unified contact with ≥ 2 members, all of them harness cards.
        /// Prefers S12 pairs, then S4. Returns the member cards (iCloud first).
        private func findLinkedPair(_ store: CNContactStore, scan: HarnessScan) throws -> [CNContact]? {
            let idKey = [CNContactIdentifierKey as any CNKeyDescriptor]
            var groups: [String: [CNContact]] = [:]
            for card in scan.harness {
                let unified = try catchingObjC {
                    try store.unifiedContact(withIdentifier: card.identifier, keysToFetch: idKey)
                }
                groups[unified.identifier, default: []].append(card)
            }
            let writer = SafeWriter(store: store)
            var candidates: [[CNContact]] = []
            for (unifiedID, cards) in groups where cards.count >= 2 {
                let unified = try catchingObjC {
                    try store.unifiedContact(withIdentifier: unifiedID, keysToFetch: idKey)
                }
                let members = try memberIDs(of: unified, in: store)
                guard Set(members) == Set(cards.map(\.identifier)) else {
                    print("skipping linked group \(unifiedID): it has non-harness members")
                    continue
                }
                for id in members { _ = try writer.verifiedCard(id, keys: []) }
                candidates.append(cards)
            }
            func rank(_ cards: [CNContact]) -> Int {
                cards.allSatisfy { Harness.marker($0).flatMap(Harness.spikeTag) == S12Notes.spike } ? 0 : 1
            }
            guard let best = candidates.min(by: { rank($0) < rank($1) }) else { return nil }
            return best.sorted { kindOrder($0) < kindOrder($1) }
        }

        private func kindOrder(_ card: CNContact) -> Int {
            switch Harness.marker(card).flatMap(Harness.kindTag) {
            case "icloud": return 0
            case "google": return 1
            default: return 2
            }
        }

        private func createCard(
            _ store: CNContactStore, _ card: CNMutableContact, marker: String, kind: String, container: CNContainer
        ) throws -> String {
            try SafeWriter(store: store).add(card, to: container.identifier)
            guard let saved = try Harness.locate(store, marker: marker) else {
                throw SpikeError("Saved \(kind) card but could not find it again by marker.")
            }
            try Ledger.append(
                LedgerEntry(
                    spike: S12Notes.spike, kind: kind, identifier: saved.identifier, marker: marker,
                    containerID: container.identifier, createdAt: Stamp.iso()))
            return saved.identifier
        }

        // MARK: the write test (single card or linked pair)

        private func label(_ card: CNContact) -> String {
            "\(Harness.marker(card).flatMap(Harness.spikeTag) ?? "?")/\(Harness.marker(card).flatMap(Harness.kindTag) ?? "?") card"
        }

        private func writeTest(_ store: CNContactStore, cards: [CNContact], expectedName: String) throws {
            let writer = SafeWriter(store: store)
            let ids = cards.map(\.identifier)
            let markers = Set(cards.compactMap(Harness.marker))
            let before = try ids.map { try writer.verifiedCard($0, keys: Snapshot.keys) }
            let unifiedBefore = try catchingObjC {
                try store.unifiedContact(
                    withIdentifier: ids[0], keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor])
            }
            print("target: \(cards.count == 1 ? "single card" : "linked pair") \"\(expectedName)\"")
            for card in cards { print("  \(label(card)) identifier=\(card.identifier)") }
            print("  unified id=\(unifiedBefore.identifier)")
            // Every card behind the unified contact must be a harness card:
            // AppleScript may address the unified person, not one card.
            let membersBefore = try memberIDs(of: unifiedBefore, in: store)
            for id in membersBefore { _ = try writer.verifiedCard(id, keys: []) }
            print("  unified members: \(membersBefore.count) (all harness cards)")

            let wasRunning = ContactsScripting.isContactsRunning
            print("Contacts.app running before: \(wasRunning ? "yes" : "no")")
            let scripting = try ContactsScripting()

            // Resolve the AppleScript person.
            let given = cards[0].givenName
            let family = cards[0].familyName
            let byName = try withPermissionHelp { try scripting.ids(firstName: given, lastName: family) }
            print("AppleScript persons named \"\(expectedName)\": \(byName.count)")
            print("  ids: \(byName)")
            var probeIDs = ids
            if !probeIDs.contains(unifiedBefore.identifier) { probeIDs.append(unifiedBefore.identifier) }
            for id in probeIDs {
                do {
                    let identity = try scripting.identity(of: id)
                    print("  `person id <\(id)>` resolves -> AS id \(identity.id)")
                } catch let error as ContactsScripting.ScriptError {
                    print("  `person id <\(id)>` -> \(error)")
                }
            }

            let target: String
            if byName.count == 1 {
                target = byName[0]
            } else if let unifiedHit = byName.first(where: { $0 == unifiedBefore.identifier }) {
                target = unifiedHit
            } else if let cardHit = byName.first(where: { $0 == ids[0] }) {
                target = cardHit
            } else {
                throw SpikeError(
                    "Could not pick a unique AppleScript person for the harness card(s) (\(byName.count) by name). Not writing."
                )
            }
            print("AppleScript target person id: \(target)")
            try verifyASTarget(scripting, target, markers: markers)

            let noteBefore = try scripting.note(of: target)
            print("note before (AppleScript): \(noteBefore.map { "\($0.count) chars" } ?? "missing value")")
            let noteKeyReadable = Self.cnNoteReadable(store, id: ids[0])
            print(
                "CNContactStore can read CNContactNoteKey on this card: \(noteKeyReadable ? "yes" : "no (expected without entitlement)")"
            )

            let text = "c2m-spike S12 note \(Stamp.iso())\nsecond line: unicode é ✓ 日本 — \"quotes\" & <angle>"
            let plan = [
                "re-verify every underlying card (CNContactStore) and the AppleScript person (name prefix + marker URL)",
                "AppleScript: set note of person id \"\(target)\" to <\(text.count)-char synthetic text>; save",
                "re-read via AppleScript; compare CN fields, identifiers and change history before/after",
            ]
            guard confirmPlan("s12-notes write", plan, yes: yes) else { return }

            let tokenBefore = store.currentHistoryToken

            // Immediately before writing: both sides again.
            for id in ids { _ = try writer.verifiedCard(id, keys: []) }
            let members = try memberIDs(of: unifiedBefore, in: store)
            for id in members { _ = try writer.verifiedCard(id, keys: []) }
            try verifyASTarget(scripting, target, markers: markers)

            print("\n## Write")
            do {
                let (_, elapsed) = try timed { try scripting.setNote(of: target, to: text) }
                print(String(format: "set note + save: OK in %.0fms", elapsed * 1000))
            } catch {
                print("set note FAILED: \(describe(error))")
                if let e = error as? ContactsScripting.ScriptError, e.isPermissionDenied {
                    print(ContactsScripting.permissionHelp)
                }
                throw ExitCode(1)
            }

            let reread = try scripting.note(of: target)
            print("re-read via AppleScript: \(reread == text ? "MATCHES written text" : "DIFFERS")")
            if let reread, reread != text {
                print("  re-read value (synthetic): \(reread.debugDescription)")
                print("  line endings: CR=\(reread.contains("\r")) LF=\(reread.contains("\n"))")
            }
            for id in ids where id != target {
                do {
                    let value = try scripting.note(of: id)
                    print(
                        "  `note of person id <\(id)>`: \(value == text ? "written text" : value == nil ? "missing value" : "other text (\(value!.count) chars)")"
                    )
                } catch {
                    print("  `note of person id <\(id)>`: \(describe(error))")
                }
            }

            print("\n## CNContactStore view after the AppleScript write")
            Thread.sleep(forTimeInterval: 1)
            let after = try ids.map { try writer.verifiedCard($0, keys: Snapshot.keys) }
            for (old, new) in zip(before, after) {
                let diffs = RowDiff.align(Snapshot.rows(of: old), Snapshot.rows(of: new)).filter(\.changed)
                print(
                    "\(label(old)): identifier unchanged=\(old.identifier == new.identifier) other fields changed=\(diffs.count)"
                )
                for d in diffs { print("  \(d.field): \(d.before?.value ?? "∅") -> \(d.after?.value ?? "∅")") }
            }
            for card in cards {
                if let marker = Harness.marker(card), let located = try Harness.locate(store, marker: marker) {
                    print("\(label(card)) found by marker under same id: \(located.identifier == card.identifier)")
                }
            }
            let unifiedAfter = try catchingObjC {
                try store.unifiedContact(
                    withIdentifier: ids[0], keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor])
            }
            print("unified id unchanged: \(unifiedAfter.identifier == unifiedBefore.identifier)")

            // Which underlying card(s) changed, per change history (not unified).
            do {
                let history = try store.c2mspike_history(
                    since: tokenBefore, excludingAuthors: [], unify: false, includeGroups: false)
                let byCard = Dictionary(
                    grouping: history.events.compactMap { e in
                        S3History.contactID(e).map { ($0, S3History.eventName(e)) }
                    }, by: \.0)
                print("change history since pre-write token (unify=false): \(history.events.count) events")
                for card in cards {
                    let names = byCard[card.identifier]?.map(\.1) ?? []
                    print("  \(label(card)): \(names.isEmpty ? "no events" : names.joined(separator: ", "))")
                }
                let others = byCard.keys.filter { !ids.contains($0) }.count
                print("  other contacts with events: \(others) (unrelated activity or sync)")
            } catch {
                print("change history fetch failed: \(describe(error))")
            }

            print(
                """

                Verify off-device (after 1-5 min of sync):
                  - iCloud.com > Contacts > "\(expectedName)": is the note there?
                  \(cards.count > 1 ? "- contacts.google.com > \"\(expectedName)\": is the note there (Google calls it Notes)?\n  " : "")- iPhone Contacts: same card, Notes field.
                Then: c2m-spike cleanup --spike s12 [--yes]
                """)
        }

        /// AppleScript-side safety check: name prefix plus one of the expected
        /// harness marker URLs on the person we are about to write.
        private func verifyASTarget(_ scripting: ContactsScripting, _ id: String, markers: Set<String>) throws {
            let identity = try scripting.identity(of: id)
            guard identity.id == id, identity.looksLikeHarness, identity.urls.contains(where: markers.contains) else {
                throw SpikeError(
                    "SAFETY: AppleScript person \(id) is not the harness card (name prefix + expected marker URL). Refusing to write."
                )
            }
        }

        /// Whether an un-entitled fetch exposes CNContactNoteKey (S2 behavior).
        static func cnNoteReadable(_ store: CNContactStore, id: String) -> Bool {
            let key = CNContactNoteKey as any CNKeyDescriptor
            guard let card = try? fetchUnderlying(store, id: id, keys: [key]) else { return false }
            return card.isKeyAvailable(CNContactNoteKey)
        }
    }
}

/// Runs `body` and returns its result with elapsed seconds.
private func timed<T>(_ body: () throws -> T) throws -> (T, Double) {
    let clock = ContinuousClock()
    var result: T?
    let duration = try clock.measure { result = try body() }
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    return (result!, seconds)
}

/// Adds the Automation instructions when an Apple Event is refused (-1743).
private func withPermissionHelp<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as ContactsScripting.ScriptError where error.isPermissionDenied {
        throw SpikeError("\(error)\n\(ContactsScripting.permissionHelp)", exitCode: 3)
    } catch let error as ContactsScripting.ScriptError {
        throw SpikeError("\(error)")
    }
}
