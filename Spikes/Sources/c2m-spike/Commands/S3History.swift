import ArgumentParser
import Contacts
import Foundation
import SpikeShim

/// S3: change-history via the ObjC shim. Counts by event type only (no PII).
struct S3History: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s3-history",
        abstract: "S3: change-history enumeration, token persistence, excludedTransactionAuthors.",
        discussion: """
            Default: fetch with a nil token (DropEverything + full snapshot), print counts, save token.
            --since: fetch from Spikes/results/token.bin and save the new token.
            --bogus-token: fetch with garbage bytes to observe the invalid-token error (604?).
            --author NAME --yes: edit an S3 scratch card with transactionAuthor=NAME and verify that
              excludedTransactionAuthors=[NAME] hides it, plus a control edit without author.
            """)

    @Flag(help: "Start from the saved token instead of nil.")
    var since = false

    @Flag(help: "Use a garbage token to provoke an invalid-token error.")
    var bogusToken = false

    @Option(help: "Run the transactionAuthor exclusion test with this author string.")
    var author: String?

    @Flag(inversion: .prefixedNo, help: "shouldUnifyResults on the fetch request.")
    var unify = true

    @Flag(help: "includeGroupChanges on the fetch request.")
    var includeGroups = false

    @OptionGroup var containerOptions: ContainerOptions

    @Flag(help: "Allow the --author test to create/edit its scratch card.")
    var yes = false

    static var tokenURL: URL { get throws { try Paths.result("token.bin") } }

    func run() throws {
        try runReporting {
            let store = try Access.authorizedStore()
            if let author {
                try authorTest(store, author: author)
                return
            }
            var token: Data?
            var mode = "nil token"
            if bogusToken {
                token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                mode = "bogus token"
            } else if since {
                let url = try Self.tokenURL
                guard let saved = try? Data(contentsOf: url) else {
                    throw SpikeError("No saved token at \(url.path). Run `s3-history` without --since first.")
                }
                token = saved
                mode = "saved token (\(saved.count) bytes)"
            }
            print("s3-history  \(Stamp.iso())  start=\(mode) unify=\(unify) includeGroups=\(includeGroups)")
            let started = Date()
            do {
                let result = try store.c2mspike_history(
                    since: token, excludingAuthors: [], unify: unify, includeGroups: includeGroups)
                let elapsed = Date().timeIntervalSince(started)
                Self.printCounts(result.events)
                print(String(format: "elapsed: %.2fs", elapsed))
                if let newToken = result.currentHistoryToken {
                    print("new token: \(newToken.count) bytes, same as start: \(newToken == token)")
                    if !bogusToken {
                        try newToken.write(to: try Self.tokenURL, options: .atomic)
                        print("saved token -> \(try Self.tokenURL.path)")
                    }
                } else {
                    print("new token: nil")
                }
            } catch {
                let ns = error as NSError
                print("FETCH FAILED: \(describe(error))")
                if ns.domain == CNErrorDomain {
                    print("CNError code \(ns.code) (603 = history token expired, 604 = invalid anchor/token)")
                }
            }
        }
    }

    static func eventName(_ event: CNChangeHistoryEvent) -> String {
        NSStringFromClass(type(of: event)).replacingOccurrences(of: "CNChangeHistory", with: "")
    }

    static func printCounts(_ events: [CNChangeHistoryEvent]) {
        let counts = Dictionary(grouping: events, by: eventName).mapValues(\.count)
        print("events: \(events.count)")
        for (name, count) in counts.sorted(by: { $0.key < $1.key }) { print("  \(name): \(count)") }
    }

    /// Identifier of the contact an event refers to, if any.
    static func contactID(_ event: CNChangeHistoryEvent) -> String? {
        switch event {
        case let e as CNChangeHistoryAddContactEvent: return e.contact.identifier
        case let e as CNChangeHistoryUpdateContactEvent: return e.contact.identifier
        case let e as CNChangeHistoryDeleteContactEvent: return e.contactIdentifier
        default: return nil
        }
    }

    private func authorTest(_ store: CNContactStore, author: String) throws {
        let scan = try HarnessScan.run(store)
        let existing = scan.harness(spike: "s3").first
        let target = try existing == nil ? containerOptions.resolve(.icloud, in: store) : nil
        var plan: [String] = []
        if let existing {
            plan.append("reuse scratch card \"\(Harness.displayName(existing))\" identifier=\(existing.identifier)")
        } else if let target {
            plan.append("create scratch card \"ZZ Spike S3 …\" in iCloud container \(target.identifier)")
        }
        plan += [
            "edit 1: set jobTitle with transactionAuthor=\"\(author)\"",
            "fetch history since pre-edit token, with and without excludedTransactionAuthors=[\"\(author)\"]",
            "edit 2 (control): set jobTitle with no author; fetch again excluding \"\(author)\"",
        ]
        guard confirmPlan("s3-history --author", plan, yes: yes) else { return }

        let writer = SafeWriter(store: store)
        var cardID: String
        if let existing {
            cardID = existing.identifier
        } else {
            let (card, marker) = Harness.newCard(spike: "s3", kind: "icloud", suffix: "History \(Stamp.short())")
            try writer.add(card, to: target!.identifier)
            guard let located = try Harness.locate(store, marker: marker) else {
                throw SpikeError("Created S3 card but could not find it again by marker.")
            }
            cardID = located.identifier
            try Ledger.append(
                LedgerEntry(
                    spike: "s3", kind: "icloud", identifier: cardID, marker: marker, containerID: target!.identifier,
                    createdAt: Stamp.iso()))
            print("created S3 card identifier=\(cardID)")
        }

        func eventsFor(_ token: Data?, excluding: [String]) throws -> (all: Int, ours: Int) {
            let result = try store.c2mspike_history(
                since: token, excludingAuthors: excluding, unify: unify, includeGroups: false)
            return (result.events.count, result.events.filter { Self.contactID($0) == cardID }.count)
        }

        let tokenBefore = store.currentHistoryToken
        print("pre-edit token: \(tokenBefore.map { "\($0.count) bytes" } ?? "nil")")
        var authored = writer
        authored.author = author
        try authored.update(cardID, keys: [CNContactJobTitleKey as any CNKeyDescriptor]) {
            $0.jobTitle = "S3 authored \(Stamp.iso())"
        }
        let plain = try eventsFor(tokenBefore, excluding: [])
        let excluded = try eventsFor(tokenBefore, excluding: [author])
        print(
            "after authored edit: unfiltered events=\(plain.all) (ours \(plain.ours)); excluding author events=\(excluded.all) (ours \(excluded.ours))"
        )

        try writer.update(cardID, keys: [CNContactJobTitleKey as any CNKeyDescriptor]) {
            $0.jobTitle = "S3 control \(Stamp.iso())"
        }
        let control = try eventsFor(tokenBefore, excluding: [author])
        print("after control edit: excluding author events=\(control.all) (ours \(control.ours))")

        let filterWorks = plain.ours > 0 && excluded.ours == 0
        let controlVisible = control.ours > 0
        print("RESULT: excludedTransactionAuthors hides authored edit: \(filterWorks ? "YES" : "NO")")
        print("RESULT: unauthored control edit still visible when excluding: \(controlVisible ? "YES" : "NO")")
        print("(Coalescing note: if the control shows ours=1, the two edits may have been merged into one event.)")
    }
}
