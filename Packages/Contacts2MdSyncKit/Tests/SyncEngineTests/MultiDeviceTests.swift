import ContactModel
import Foundation
import SyncEngine
import SyncTestSupport
import Testing

@Suite("Two-way sync: two devices on one vault")
struct MultiDeviceTests {
    @Test(
        "a second device joins without duplicating notes or writing anything, stamps on or off",
        arguments: [false, true])
    func secondDevice(stamps: Bool) throws {
        let first = try World.exported(
            [World.ann(), World.person("bob", "Bob", "Two") { $0.emails = [Labeled(nil, "bob@two.example")] }],
            stamps: .fixed(stamps))
        let second = SyncHarness(
            store: first.store, vault: first.vault, appleWrites: true, stampContacts: stamps,
            device: DeviceIdentity(id: "device-b", name: "Mac B"), clock: first.clock)
        let writes = first.store.appliedOperations.count
        first.vault.resetWrites()
        let joined = try second.sync()
        #expect(joined.plan.markdown.creates.isEmpty && joined.plan.conflicts.isEmpty)
        #expect(first.store.appliedOperations.count == writes)
        #expect(first.notePaths == ["Inbox/Ann One.md", "Inbox/Bob Two.md"])
        #expect((joined.plan.identityWarning != nil) == !stamps)

        // An edit made through either device converges on both.
        try second.editNote("Inbox/Ann One.md") { $0.jobTitle = "Architect" }
        try second.sync()
        #expect(World.apple(first, "ann:icloud")?.jobTitle == "Architect")
        #expect(try first.sync().plan.isEmpty)
        #expect(try second.sync().plan.isEmpty)
    }
}
