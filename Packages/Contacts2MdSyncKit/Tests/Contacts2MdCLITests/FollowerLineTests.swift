import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import SyncTriggers
import Testing

/// The Overview's follower line follows the lease and counts what the
/// leader will actually apply (M6 follow-ups).
@Suite("M6 follow-ups: the follower line")
struct FollowerLineTests {
    static let now = LeaseFollowUpTests.now

    func holder(_ id: String, _ name: String, expires: TimeInterval = 1200) -> LeaseHolder {
        let lease = VaultLease(
            deviceID: id, deviceName: name, acquiredAt: Self.now, heartbeatAt: Self.now,
            expiresAt: Self.now.addingTimeInterval(expires))
        return LeaseHolder(lease, now: Self.now)
    }

    func checked(_ edit: (inout SyncRunSummary) -> Void = { _ in }) -> FollowerCheck {
        var summary = SyncRunSummary(
            kind: .live, startedAt: Self.now, finishedAt: Self.now, appleFull: false, appleRead: "incremental")
        edit(&summary)
        return .checked(summary)
    }

    @Test("follower dry run with apple_writes off: held Apple changes are not left for the leader to apply")
    func followerHeldChanges() throws {
        let harness = CLIHarness.exported()
        _ = try LeaseFollowUpTests().macB(harness).takeOver()
        harness.editNote("Inbox/Ann One.md", "job_title: Engineer", with: "job_title: CTO")
        let outcome = harness.runner().runNow(SyncRunRequest(SyncTrigger(.live))) { _ in }
        guard case .following(let holder, .checked(let summary)) = outcome else {
            Issue.record("expected a follower check, got \(outcome)")
            return
        }
        #expect(summary.appleHeld == 1 && summary.appleHoldReason == "apple writes disabled")
        #expect(summary.appleUpdated == 0 && summary.changeCount == 0)
        var state = UILiveState()
        state.apply(.following(device: holder, check: .checked(summary)))
        #expect(state.follower(now: harness.clock.now)?.text == "Mac B leads; it has nothing left to apply")
        // The app's own dry run (Check for Changes) counts the same way.
        let planned = try #require(try LeaseFollowUpTests().reader(harness).plan().planned)
        #expect(planned.appleHeld == 1 && planned.changeCount == 0)
    }

    @Test("change counts include images, resolved iCloud versions and the config file")
    func otherWritesCount() {
        var state = UILiveState()
        state.apply(.following(device: holder("mac-b", "Mac B"), check: checked { $0.otherWrites = 1 }))
        #expect(state.follower(now: Self.now)?.text == "Mac B leads; it still has 1 change to apply")
        var summary = SyncRunSummary(
            kind: .live, startedAt: Self.now, finishedAt: Self.now, appleFull: false, appleRead: "")
        #expect(summary.changeCount == 0 && !summary.changedSomething)
        summary.otherWrites = 2
        summary.markdownTrashed = 1
        summary.appleHeld = 4
        #expect(summary.changeCount == 3 && summary.changedSomething)
    }

    @Test("another device takes over: the last check is dropped; the leader stops: no follower line")
    func leaderChanges() {
        var state = UILiveState()
        state.apply(.following(device: holder("mac-b", "Mac B"), check: checked { $0.markdownUpdated = 2 }))
        #expect(state.follower(now: Self.now)?.text == "Mac B leads; it still has 2 changes to apply")
        // A heartbeat sees Mac C lead: Mac B's check says nothing about it.
        #expect(state.apply(.following(device: holder("mac-c", "Mac C"), check: nil)) == .refresh)
        #expect(state.followerCheck == nil)
        #expect(state.follower(now: Self.now)?.text == "Mac C leads syncing this folder")
        // The same leader again keeps its check.
        state.apply(.following(device: holder("mac-c", "Mac C"), check: checked()))
        state.apply(.following(device: holder("mac-c", "Mac C"), check: nil))
        #expect(state.follower(now: Self.now)?.text == "Mac C leads; it has nothing left to apply")
        // Mac C released the lease (the catch-up run may be skipped with live sync off).
        #expect(state.apply(.followingEnded) == .refresh)
        state.apply(.skipped(.launch, reason: "live sync is off"))
        #expect(!state.isFollowing && state.followerCheck == nil)
        #expect(state.follower(now: Self.now) == nil)
        #expect(state.display(now: Self.now) == nil)
    }

    @Test("Check for Changes while following replaces the last check; ignored when not following")
    func recheck() {
        var state = UILiveState()
        var summary = SyncRunSummary(
            kind: .manual, startedAt: Self.now, finishedAt: Self.now, appleFull: true, appleRead: "full")
        summary.markdownCreated = 1
        state.recheck(summary)
        #expect(state.followerCheck == nil)
        state.apply(.following(device: holder("mac-b", "Mac B"), check: .failed("Contacts access was denied")))
        state.recheck(summary)
        let line = state.follower(now: Self.now)
        #expect(line?.text == "Mac B leads; it still has 1 change to apply" && line?.isError == false)
    }

    func followerStatus(_ holder: LeaseHolder, lastExport: Date? = Self.now) -> StoredStatus {
        var status = StoredStatus(lastExport: lastExport, records: 1, pendingReview: 0, pendingAsOf: nil)
        status.leaseRole = .follower
        status.leaseHolder = holder
        return status
    }

    @Test("hosted before the coordinator saw the leader: the stored lease's line; an expired lease shows none")
    func storedLeaseFallback() {
        let status = followerStatus(holder("mac-b", "Mac B"))
        let line = UIFollowerLine.current(live: UILiveState(), status: status, now: Self.now)
        #expect(line?.text == "Mac B leads syncing this folder")
        #expect(line?.detail.hasPrefix("This Mac follows: Check for Changes shows what is left") == true)
        // The coordinator's view wins once it has one.
        var state = UILiveState()
        state.apply(.following(device: holder("mac-b", "Mac B"), check: checked()))
        #expect(
            UIFollowerLine.current(live: state, status: status, now: Self.now)?.text
                == "Mac B leads; it has nothing left to apply")
        // The stored holder's lease ran out: nobody leads (as the banners and Settings say).
        let expired = followerStatus(holder("mac-b", "Mac B", expires: -1))
        #expect(UIFollowerLine.current(live: nil, status: expired, now: Self.now) == nil)
        #expect(UIFollowerLine.current(live: UILiveState(), status: expired, now: Self.now) == nil)
    }

    @Test("error messages: Foundation errors use their localized text, engine errors describe themselves")
    func errorMessages() {
        let cocoa = CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/vault/Inbox"])
        let message = UIFormat.message(for: cocoa)
        #expect(message == cocoa.localizedDescription)
        #expect(!message.contains("NSCocoaErrorDomain") && !message.contains("Code="))
        let posix = POSIXError(.EACCES)
        #expect(UIFormat.message(for: posix) == posix.localizedDescription)
        #expect(UIFormat.message(for: ContactStoreError.accessDenied) == ContactStoreError.accessDenied.description)
    }
}
