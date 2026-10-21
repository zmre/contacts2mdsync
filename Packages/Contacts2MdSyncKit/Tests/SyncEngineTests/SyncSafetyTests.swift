import ContactModel
import Foundation
import MarkdownCodec
import SyncEngine
import SyncTestSupport
import Testing
import VaultIndex

/// A linked iCloud + Google pair (spike S4): a shared email on both cards,
/// a Google-only email, different job titles (iCloud wins by precedence).
func linkedAnn() -> AppleContact {
    var icloud = CanonicalContact(kind: .person, title: "", name: PersonName(given: "Ann", family: "One"))
    icloud.emails = [Labeled("home", "ann@home.example")]
    icloud.jobTitle = "Engineer"
    var google = icloud
    google.emails = [Labeled("home", "ann@home.example"), Labeled("work", "ann@gmail.example")]
    google.jobTitle = "Eng"
    return AppleContact(
        unifiedID: "SYNTH-ann",
        cards: [
            AppleCard(id: "ann:google", containerID: "google", accountKind: .google, values: google),
            AppleCard(id: "ann:icloud", containerID: "icloud", accountKind: .iCloud, values: icloud),
        ],
        contact: google)
}

@Suite("Two-way sync: write targets, echo, unapplyable")
struct WriteTargetTests {
    static let path = "Inbox/Ann One.md"

    @Test(
        "linked cards: edits/deletes go to every card holding the value, additions to iCloud, scalars to both",
        arguments: [false, true])
    func linkedTargets(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([linkedAnn()])
            world.store.setSynthesizeLinkedIDs(true)
            try world.editNote(Self.path) { note in
                note.jobTitle = "Architect"
                note.emails = [Labeled("work", "ann@gmail.example"), Labeled("other", "ann@new.example")]
            }
            try MergeTableTests.syncToFixpoint(world)
            #expect(world.store.unifiedSaveCount == 0)
            let icloud = try #require(world.store.values(ofCard: "ann:icloud"))
            let google = try #require(world.store.values(ofCard: "ann:google"))
            #expect(icloud.jobTitle == "Architect" && google.jobTitle == "Architect")
            #expect(icloud.emails.map(\.value) == ["ann@new.example"])  // shared email removed, addition here
            #expect(google.emails.map(\.value) == ["ann@gmail.example"], "\(google.emails)")
        }
    }

    @Test("server normalization echo converges: no write back, markdown display kept", arguments: [false, true])
    func echo(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            world.store.setNormalizePhonesOnSave(true)
            try world.editNote(Self.path) { $0.phones.append(Labeled("work", "4155550123")) }
            try MergeTableTests.syncToFixpoint(world)
            #expect(World.apple(world, "ann:icloud")?.phones.last?.value == "(415) 555-0123")
            #expect(try world.note(Self.path)?.phones.last?.value == "4155550123")
        }
    }

    @Test("a card that refuses a write is marked unapplyable and not retried (no ping-pong)", arguments: [false, true])
    func unapplyableSecondaryCard(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([linkedAnn()])
            world.store.dropWrites(.google, field: "jobTitle")
            try world.editNote(Self.path) { $0.jobTitle = "Architect" }
            let run = try world.sync()
            #expect(run.result?.newUnapplyable.map(\.cardID) == ["ann:google"])
            let writes = world.store.appliedOperations.count
            for _ in 0..<3 { #expect(try world.sync().plan.isEmpty) }
            #expect(world.store.appliedOperations.count == writes)
            #expect(try world.note(Self.path)?.jobTitle == "Architect")
        }
    }

    @Test(
        "a value the primary card does not keep is not rewritten and not a conflict; a later Apple edit wins",
        arguments: [false, true])
    func unapplyablePrimary(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann()])
            world.store.dropWrites(.iCloud, field: "jobTitle")
            try world.editNote(Self.path) { $0.jobTitle = "Architect" }
            try world.sync()
            let writes = world.store.appliedOperations.count
            let again = try world.sync()
            #expect(again.plan.isEmpty && again.plan.conflicts.isEmpty)
            #expect(world.store.appliedOperations.count == writes)
            world.store.editCard("ann:icloud") { $0.jobTitle = "Director" }
            try world.sync()
            #expect(try world.note(Self.path)?.jobTitle == "Director")
        }
    }

    @Test(
        "a managed tag on a contact without an iCloud/Local card stays in markdown, warned once, no flapping",
        arguments: [false, true])
    func tagWithoutGroupCard(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.person("gil", "Gil", "Google", accounts: [.google])])
            try world.editNote("Inbox/Gil Google.md") { $0.tags = ["family"] }
            let run = try world.sync()
            #expect(run.plan.blocked.count == 1)
            #expect(try world.sync().plan.blocked.isEmpty)
            #expect(try world.note("Inbox/Gil Google.md")?.tags == ["family"])
            #expect(try world.plan().plan.isEmpty)
        }
    }
}

@Suite("Two-way sync: gating, blast radius, breakers")
struct GatingTests {
    @Test("apple_writes disabled (the default): zero Apple writes, no backup, markdown still synced, held reported")
    func gating() throws {
        let world = try World.exported([World.ann()], appleWrites: false)
        try world.editNote("Inbox/Ann One.md") { $0.jobTitle = "Architect" }
        world.store.editCard("ann:icloud") { $0.emails.append(Labeled("work", "ann@work.example")) }
        let run = try world.sync()
        #expect(run.plan.appleHold == .appleWritesDisabled)
        #expect(run.plan.apple.map(\.fields) == [["job_title"]])
        #expect(world.store.appliedBatches.isEmpty && world.store.vCardExportCount == 0)
        #expect(try world.note("Inbox/Ann One.md")?.emails.count == 2)
        // Held again next run (the base keeps the pending change).
        let again = try world.sync()
        #expect(again.plan.appleHold == .appleWritesDisabled && again.plan.apple.count == 1)
        #expect(world.store.appliedBatches.isEmpty)
        // Enabling writes applies it.
        try world.setConfig { $0.appleWrites = true }
        try MergeTableTests.syncToFixpoint(world)
        #expect(World.apple(world, "ann:icloud")?.jobTitle == "Architect")
    }

    @Test("blast radius: more than 25 Apple changes are held (markdown still written); --max-apple-changes allows")
    func blastRadius() throws {
        let people = (1...30).map { World.person("p\($0)", "Person", "Number\($0)") }
        let world = try World.exported(people)
        for number in 1...30 { try world.editNote("Inbox/Person Number\(number).md") { $0.jobTitle = "Staff" } }
        world.store.editCard("p1:icloud") { $0.department = "Ops" }
        let held = try world.sync()
        #expect(held.plan.appleHold == .blastRadius(count: 30, limit: 25))
        #expect(world.store.appliedBatches.isEmpty)
        #expect(try world.note("Inbox/Person Number1.md")?.department == "Ops")
        let allowed = try world.sync(SyncOptions(maxAppleChanges: 30))
        #expect(allowed.result?.apple.count == 30)
    }

    @Test("mass-vanish breaker: contacts vanishing from Apple stop the whole run; nothing written")
    func massVanishApple() throws {
        let people = (1...15).map { World.person("p\($0)", "Person", "Number\($0)") }
        let world = try World.exported(people)
        world.store.replaceContacts([])
        try world.editNote("Inbox/Person Number1.md") { $0.jobTitle = "x" }
        world.vault.resetWrites()
        let run = try world.sync()
        #expect(run.plan.breaker?.side == "apple" && run.plan.breaker?.vanished == 15)
        #expect(run.result == nil)
        #expect(world.vault.writes.filter { !$0.hasPrefix(".") }.isEmpty)
        #expect(try world.sync(SyncOptions(allowMassVanish: true)).plan.breaker == nil)
    }

    @Test("mass-vanish breaker: notes vanishing (folder unmounted) stop the run")
    func massVanishMarkdown() throws {
        let people = (1...15).map { World.person("p\($0)", "Person", "Number\($0)") }
        let world = try World.exported(people)
        for path in world.notePaths { world.vault.remove(path) }
        let run = try world.sync()
        #expect(run.plan.breaker?.side == "markdown")
        #expect(world.store.appliedBatches.isEmpty)
    }

    @Test("small vaults: one deletion never trips the percentage rule")
    func smallVault() {
        let limits = SyncLimits()
        #expect(!limits.tripsMassVanish(vanished: 1, total: 4))
        #expect(!limits.tripsMassVanish(vanished: 2, total: 10))
        #expect(limits.tripsMassVanish(vanished: 3, total: 20))
        #expect(limits.tripsMassVanish(vanished: 11, total: 10_000))
    }
}

@Suite("Two-way sync: deletes")
struct DeleteTests {
    @Test(
        "Apple delete: queued only after two snapshots ≥ 10 min apart; trash moves the note to the Trash",
        arguments: [false, true])
    func appleDeleteTrash(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([World.ann(), World.person("bob", "Bob", "Two")])
            world.store.deleteContact(withCard: "ann:icloud")
            let first = try world.sync()
            #expect(first.plan.markdown.reviews.isEmpty)
            #expect(first.plan.awaitingDeleteConfirmation == ["Ann One"])
            world.advance(minutes: 5)
            #expect(try world.sync().plan.markdown.reviews.isEmpty)
            world.advance(minutes: 6)
            let queued = try world.sync()
            let item = try #require(queued.plan.markdown.reviews.first)
            #expect(item.id.hasPrefix("deleted-") && item.choices == ["trash", "keep", "restore"])
            #expect(world.vault.exists("Inbox/Ann One.md"))
            try world.decide(item.id, "trash")
            let trashed = try world.sync()
            #expect(trashed.result?.trashed.map(\.path) == ["Inbox/Ann One.md"])
            #expect(!world.vault.exists("Inbox/Ann One.md"))
            #expect(try world.state.load().records.count == 1)
            #expect(try world.sync().plan.isEmpty)
        }
    }

    @Test("Apple delete: keep detaches the note; restore re-creates the contact", arguments: [false, true])
    func appleDeleteKeepRestore(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let world = try World.exported([
                World.ann(), World.person("bob", "Bob", "Two") { $0.jobTitle = "Chef" },
                World.person("cy", "Cy", "Three"),
            ])
            world.store.deleteContact(withCard: "ann:icloud")
            world.store.deleteContact(withCard: "bob:icloud")
            try world.sync()
            world.advance(minutes: 11)
            let items = try world.sync().plan.markdown.reviews
            #expect(items.count == 2)
            try world.decide(try #require(items.first { $0.summary.contains("Ann") }).id, "keep")
            try world.decide(try #require(items.first { $0.summary.contains("Bob") }).id, "restore")
            try world.sync()
            #expect(try world.note("Inbox/Ann One.md")?.sync.status == "detached")
            let restored = try #require(world.store.contacts.first { $0.contact.name.given == "Bob" })
            #expect(restored.contact.jobTitle == "Chef")
            #expect(try MergeTableTests.syncToFixpoint(world).plan.isEmpty)
            #expect(world.store.contacts.count == 2)
        }
    }

    @Test("a contact that reappears before confirmation is not deleted", arguments: [false, true])
    func reappears(stamps: Bool) throws {
        try World.$stampMode.withValue(stamps) {
            let ann = World.ann()
            let world = try World.exported([ann])
            world.store.deleteContact(withCard: "ann:icloud")
            try world.sync()
            world.store.add(ann)
            world.advance(minutes: 20)
            let run = try world.sync()
            #expect(run.plan.markdown.reviews.isEmpty)
            #expect(try world.state.loadVanished().isEmpty)
        }
    }

    @Test("Google id churn is never a delete (stamps on or off)", arguments: [false, true])
    func churn(stamps: Bool) throws {
        let world = try World.exported(
            [
                World.person("gil", "Gil", "Google", accounts: [.google]) {
                    $0.emails = [Labeled(nil, "gil@example.com")]
                }
            ],
            stamps: .fixed(stamps))
        world.store.churnGoogleCardIDs()
        world.advance(minutes: 30)
        let run = try world.sync()
        world.advance(minutes: 30)
        let later = try world.sync()
        #expect(run.plan.markdown.reviews.isEmpty && later.plan.markdown.reviews.isEmpty)
        #expect(later.plan.awaitingDeleteConfirmation.isEmpty)
        #expect(world.notePaths == ["Inbox/Gil Google.md"])
    }

    @Test("markdown delete: queued with restore / unlink / delete-contact")
    func markdownDelete() throws {
        let world = try World.exported(
            [World.ann(), World.person("bob", "Bob", "Two"), World.person("cy", "Cy", "Three")], stamps: .fixed(true))
        for path in ["Inbox/Ann One.md", "Inbox/Bob Two.md", "Inbox/Cy Three.md"] { world.vault.remove(path) }
        let queued = try world.sync(SyncOptions(allowMassVanish: true))
        let items = queued.plan.markdown.reviews
        #expect(items.count == 3 && items.allSatisfy { $0.choices == ["restore", "unlink", "delete-contact"] })
        func item(_ name: String) throws -> ReviewItem { try #require(items.first { $0.summary.contains(name) }) }
        try world.decide(try item("Ann").id, "restore")
        try world.decide(try item("Bob").id, "unlink")
        try world.decide(try item("Cy").id, "delete-contact")
        let run = try world.sync()
        #expect(run.result?.apple.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.delete, .unstamp])
        #expect(world.vault.exists("Inbox/Ann One.md"))
        #expect(world.store.contact(withCard: "cy:icloud") == nil)
        #expect(world.store.contact(withCard: "bob:icloud")?.stampIDs.isEmpty == true)
        #expect(try MergeTableTests.syncToFixpoint(world).plan.markdown.reviews.isEmpty)
        #expect(world.notePaths == ["Inbox/Ann One.md"])  // Bob unlinked: never exported again
    }
}

@Suite("Two-way sync: creates, stamps, scope, devices")
struct SyncIdentityTests {
    static let zed =
        "---\ntype: person\ntitle: Zed Zero\nfirst_name: Zed\nlast_name: Zero\nemails:\n  - zed@zero.example\n---\n"

    @Test("markdown-only notes are never pushed unless opted in; then created in iCloud after the create gate")
    func createOptIn() throws {
        let world = try World.exported([World.ann()])
        world.writeNote("People/Zed Zero.md", Self.zed)
        let first = try world.sync()
        #expect(first.plan.apple.isEmpty && world.store.contacts.count == 1)
        #expect(first.plan.markdown.markdownOnly == 1)
        try DecisionLog.append(
            [
                Decision(
                    kind: .createContact, createdAt: world.clock.now, device: world.device, path: "People/Zed Zero.md")
            ],
            deviceID: world.device.id, fs: world.vault)
        let created = try world.sync()
        #expect(created.result?.apple.map(\.kind) == [.create])
        let zed = try #require(world.store.contacts.first { $0.contact.name.given == "Zed" })
        #expect(zed.cards.first?.accountKind == .iCloud)
        #expect(try world.note("People/Zed Zero.md")?.sync.id != nil)
        try MergeTableTests.syncToFixpoint(world)
        #expect(world.store.contacts.count == 2)
    }

    @Test("create gate: a note matching an existing contact is not created (review instead)")
    func createGate() throws {
        let world = try World.exported([World.ann()])
        world.writeNote(
            "People/Annie.md", "---\ntype: person\ntitle: Annie\nemails:\n  - ann@home.example\n---\n")
        try DecisionLog.append(
            [Decision(kind: .createContact, createdAt: world.clock.now, device: world.device, path: "People/Annie.md")],
            deviceID: world.device.id, fs: world.vault)
        let run = try world.sync()
        #expect(run.plan.apple.isEmpty)
        #expect(run.plan.markdown.reviews.contains { $0.id.hasPrefix("match-") })
    }

    @Test("stamping is a separate opt-in; enabling it later stamps bound records (backed up, counted)")
    func stamping() throws {
        let world = try World.exported([World.ann(), World.person("bob", "Bob", "Two")])
        #expect(!world.store.appliedOperations.contains { if case .stamp = $0 { true } else { false } })
        try world.setConfig { $0.stampContacts = true }
        let run = try world.sync()
        #expect(run.plan.apple.map(\.kind) == [.stamp, .stamp])
        #expect(world.store.contacts.allSatisfy { $0.stampIDs.count == 1 })
        #expect(world.store.vCardExportCount == 1)
        #expect(try world.sync().plan.isEmpty)
        // Disabling never removes stamps.
        try world.setConfig { $0.stampContacts = false }
        #expect(try world.sync().plan.isEmpty)
        #expect(world.store.contacts.allSatisfy { $0.stampIDs.count == 1 })
    }

    @Test("several devices without stamps: identity warning (never auto-enabled)")
    func deviceWarning() throws {
        let world = try World.exported([World.ann()])
        try DeviceRecord.write(
            DeviceRecord(deviceID: "device-b", deviceName: "Mac B", lastSync: world.clock.now, summary: ""),
            fs: world.vault)
        let run = try world.sync()
        #expect(run.plan.identityWarning?.contains("2 devices share this vault") == true)
        #expect(run.plan.deviceCount == 2)
        #expect(try !world.config.stampContacts)
        try world.setConfig { $0.stampContacts = true }
        #expect(try world.sync().plan.identityWarning == nil)
    }

    @Test("scope: a contact leaving scope gets its note detached; nothing is deleted")
    func scopeDetach() throws {
        let world = try World.exported([
            World.ann(), World.person("bob", "Bob", "Two", groups: [Fixtures.work]),
        ])
        world.appendConfig("scope:\n  exclude_groups: [Work]\non_leave_scope: detach\n")
        let run = try world.sync()
        #expect(run.plan.markdown.updates.map(\.kind) == [.detach])
        #expect(try world.note("Inbox/Bob Two.md")?.sync.status == "detached")
        #expect(world.store.contacts.count == 2)
        world.store.editCard("bob:icloud") { $0.jobTitle = "Changed" }
        #expect(try world.sync().plan.isEmpty)
        #expect(try world.note("Inbox/Bob Two.md")?.jobTitle == nil)
    }

    @Test("without stamps, a settled Google card id becomes trusted by corroboration")
    func googleConfirmation() throws {
        let world = try World.exported([
            World.person("gil", "Gil", "Google", accounts: [.google]) { $0.emails = [Labeled(nil, "gil@example.com")] }
        ])
        #expect(try world.state.load().records.values.first?.cards.first?.isTrusted == false)
        world.advance(minutes: 11)
        try world.sync()
        #expect(try world.state.load().records.values.first?.cards.first?.isTrusted == true)
    }
}
