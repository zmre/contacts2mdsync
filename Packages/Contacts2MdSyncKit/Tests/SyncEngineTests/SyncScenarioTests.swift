import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// Scenario helpers for two-way sync tests.
/// Stamping for a scenario: the suite's mode, or fixed.
enum StampChoice {
    case mode, always, never

    static func fixed(_ value: Bool) -> StampChoice { value ? .always : .never }
}

enum World {
    /// Stamp mode for `exported` when a test does not choose one; the
    /// scenario suites run in both modes (`stamp_contacts` off and on).
    @TaskLocal static var stampMode = false

    static func person(
        _ id: String, _ given: String, _ family: String, accounts: [AccountKind] = [.iCloud], stamp: UUID? = nil,
        groups: [AppleGroup] = [], _ build: (inout CanonicalContact) -> Void = { _ in }
    ) -> AppleContact {
        Fixtures.contact(id, accounts: accounts, groups: groups, stamp: stamp) { contact in
            contact.name = PersonName(given: given, family: family)
            build(&contact)
        }
    }

    /// Ann One (iCloud) with an email, a phone and a job title.
    static func ann(accounts: [AccountKind] = [.iCloud]) -> AppleContact {
        person("ann", "Ann", "One", accounts: accounts) { contact in
            contact.emails = [Labeled("home", "ann@home.example")]
            contact.phones = [Labeled("mobile", "+1 415 555 0100")]
            contact.jobTitle = "Engineer"
        }
    }

    /// A world exported once (first import), ready for two-way runs.
    /// With `distinct`, those contacts (unified ids) are declared different
    /// people before the first export: same-name contacts cluster otherwise.
    static func exported(
        _ contacts: [AppleContact], notes: Bool = false, appleWrites: Bool = true, stamps: StampChoice = .mode,
        distinct: [String] = []
    ) throws -> SyncHarness {
        let stamping =
            switch stamps {
            case .mode: stampMode
            case .always: true
            case .never: false
            }
        let world = SyncHarness(
            contacts: contacts, notesEntitled: notes, appleWrites: appleWrites, stampContacts: stamping)
        if !distinct.isEmpty {
            let refs = contacts.filter { distinct.contains($0.unifiedID) }.map {
                ContactRef(cardIDs: $0.cardIDs, title: $0.unifiedID)
            }
            try DecisionLog.append(
                [Decision(kind: .distinctPeople, createdAt: world.clock.now, device: world.device, contacts: refs)],
                deviceID: world.device.id, fs: world.vault)
        }
        try world.export()
        // The first two-way run settles the merge base (M2 bases → M3 bases).
        let first = try world.sync()
        #expect(first.plan.conflicts.isEmpty, "\(first.plan.conflicts.map(\.summary))")
        return world
    }

    /// The Apple side of the contact holding `cardID`, by card precedence.
    static func apple(_ world: SyncHarness, _ cardID: String) -> CanonicalContact? {
        world.store.contact(withCard: cardID)?.cardMergedContact(keyer: world.keyer)
    }
}

@Suite("Two-way sync: scenarios")
struct SyncScenarioTests {
    @Test("markdown edit goes to Apple; Apple edit goes to markdown; second run is a no-op", arguments: [false, true])
    func basicTwoWay(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            try world.editNote("Inbox/Ann One.md") { $0.jobTitle = "CTO" }
            world.store.editCard("ann:icloud") { $0.emails.append(Labeled("work", "ann@work.example")) }
            let run = try world.sync()
            #expect(run.result?.apple.map(\.fields) == [["job_title"]])
            #expect(World.apple(world, "ann:icloud")?.jobTitle == "CTO")
            #expect(
                try world.note("Inbox/Ann One.md")?.emails.map(\.value) == ["ann@home.example", "ann@work.example"])
            world.vault.resetWrites()
            let second = try world.sync()
            #expect(second.plan.isEmpty, "\(second.plan.apple) \(second.plan.markdown.updates.map(\.changedFields))")
            #expect(world.vault.writes.filter { !$0.hasPrefix(".") }.isEmpty)
            #expect(world.store.unifiedSaveCount == 0)
        }
    }
}
