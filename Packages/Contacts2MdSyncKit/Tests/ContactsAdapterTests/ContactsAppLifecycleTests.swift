import ContactsAdapter
import Foundation
import Testing

/// Contacts.app's lifecycle around a notes session: launched hidden when
/// needed (and kept hidden, spike S14), quit afterwards only when this
/// provider launched it and the user is not using it.
@Suite("Contacts.app scripting: launch, hide and quit")
struct ContactsAppLifecycleTests {
    static let people = ScriptingNotesProviderTests.people

    @Test("Contacts.app: launched hidden when needed, quit afterwards only if we launched it and it is unused")
    func lifecycle() throws {
        let app = FakeContactsApp(people: Self.people, running: false)
        let scripting = provider(app)
        _ = try scripting.readAll(cardIDs: nil)
        #expect(app.state.withLock { $0.launches } == 1)
        scripting.finishSession()
        #expect(app.state.withLock { $0.quits } == 1)

        let inUse = FakeContactsApp(people: Self.people, running: false)
        let second = provider(inUse)
        _ = try second.readAll(cardIDs: nil)
        inUse.state.withLock { $0.hidden = false }  // the user brought it forward
        second.finishSession()
        #expect(inUse.state.withLock { $0.quits } == 0)

        let already = FakeContactsApp(people: Self.people, running: true)
        let third = provider(already)
        _ = try third.readAll(cardIDs: nil)
        third.finishSession()
        #expect(already.state.withLock { ($0.launches, $0.quits) } == (0, 0))

        let keep = FakeContactsApp(people: Self.people, running: false)
        let fourth = provider(keep, quitWhenDone: false)
        _ = try fourth.readAll(cardIDs: nil)
        fourth.finishSession()
        #expect(keep.state.withLock { $0.quits } == 0)
    }

    @Test("S14: a launch that comes up visible is hidden again (polled), and after the first event; then quit")
    func hiddenFromLaunch() throws {
        let app = FakeContactsApp(people: Self.people, running: false)
        app.state.withLock {
            $0.launchVisible = true
            $0.hidesNeeded = 3  // macOS reports hidden only after a few tries
        }
        let scripting = provider(app)
        _ = try scripting.readAll(cardIDs: nil)
        #expect(app.state.withLock { ($0.hidden, $0.hides) } == (true, 3))
        scripting.finishSession()
        #expect(app.state.withLock { $0.quits } == 1)

        // Shown again by the first event: hidden once more, still quit afterwards.
        let flashing = FakeContactsApp(people: Self.people, running: false)
        flashing.state.withLock { $0.showOnFirstEvent = true }
        let second = provider(flashing)
        _ = try second.readAll(cardIDs: nil)
        #expect(flashing.state.withLock { $0.hidden })
        second.finishSession()
        #expect(flashing.state.withLock { $0.quits } == 1)
    }

    @Test("a Contacts.app the user opened is never hidden or quit")
    func userWindowLeftAlone() throws {
        let app = FakeContactsApp(people: Self.people, running: true)
        app.state.withLock { $0.hidden = false }
        let scripting = provider(app)
        _ = try scripting.readAll(cardIDs: nil)
        scripting.finishSession()
        #expect(app.state.withLock { ($0.hides, $0.quits, $0.hidden) } == (0, 0, false))
    }
}
