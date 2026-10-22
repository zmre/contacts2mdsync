import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import SyncTriggers
import Testing
import VaultIndex

/// M6 follow-ups: exports respect the vault lease, a follower's failed dry
/// run is reported, and the app's lease, follower and iCloud-version adapters.
@Suite("M6 follow-ups: export lease, follower failures, lease and version UI")
struct LeaseFollowUpTests {
    static let macB = DeviceIdentity(id: "device-b", name: "Mac B")
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func macB(_ harness: CLIHarness) -> LeaseManager {
        LeaseManager(fs: harness.vault, device: Self.macB, clock: harness.clock, settle: 0)
    }

    func reader(_ harness: CLIHarness) -> UIVaultReader {
        var environment = harness.environment()
        environment.trigger = "GUI"
        return UIVaultReader(root: URL(filePath: "/vault"), environment: environment)
    }

    /// Notes and config in the vault (the lease and device files aside).
    func written(_ harness: CLIHarness) -> [String] {
        harness.vault.paths.filter { $0.hasSuffix(".md") || $0 == VaultConfig.path }
    }

    // MARK: - contacts2md export --yes

    @Test("export --yes while another device leads: note, exit 0, nothing written")
    func exportFollows() throws {
        let harness = CLIHarness(store: smallStore())
        _ = try macB(harness).acquire(otherDevicesKnown: false)
        let run = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        #expect(run.out.contains("note     following Mac B: it leads syncing for this vault until"))
        #expect(run.out.contains("export skipped (nothing written)"))
        #expect(written(harness).isEmpty)
        #expect(harness.backups.isEmpty)
        #expect(macB(harness).read()?.deviceID == Self.macB.id)
        // A dry run (no --yes) still shows the plan.
        #expect(harness.run(["export", "--root", "/vault"]).out.contains("create   md     Inbox/Ann One.md"))
    }

    @Test("export --yes with no lease takes it (and keeps it); --take-over takes it from another device")
    func exportTakesLease() throws {
        let harness = CLIHarness(store: smallStore())
        let run = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(run.code == 0, "\(run.out)\(run.err)")
        let lease = try #require(macB(harness).read())
        #expect(lease.deviceName == "Test Mac" && lease.releasedAt == nil)
        #expect(!written(harness).isEmpty)

        let other = CLIHarness(store: smallStore())
        _ = try macB(other).acquire(otherDevicesKnown: false)
        #expect(other.run(["export", "--root", "/vault", "--take-over"]).code == 64)  // needs --yes
        let taken = other.run(["export", "--root", "/vault", "--yes", "--take-over"])
        #expect(taken.code == 0, "\(taken.out)\(taken.err)")
        #expect(macB(other).read()?.deviceName == "Test Mac")
        #expect(written(other).contains("Inbox/Ann One.md"))
    }

    @Test("export --yes on an exported vault led elsewhere writes nothing")
    func reexportFollows() throws {
        let harness = CLIHarness.exported()
        _ = try macB(harness).takeOver()
        harness.store.editCard("bob:icloud") { $0.jobTitle = "Chef" }
        harness.vault.resetWrites()
        let run = harness.run(["export", "--root", "/vault", "--yes"])
        #expect(run.code == 0)
        #expect(run.out.contains("note     following Mac B"))
        #expect(harness.vault.writes.isEmpty)
    }

    // MARK: - The app's first export

    @Test("first export in the app while another device leads: lease outcome, follow banner, nothing written")
    func appFirstExportFollows() throws {
        let harness = CLIHarness(store: smallStore())
        _ = try macB(harness).acquire(otherDevicesKnown: false)
        let reader = reader(harness)
        let outcome = try reader.sync()
        guard case .leaseHeldElsewhere(let lease) = outcome else {
            Issue.record("expected the lease outcome, got \(outcome)")
            return
        }
        #expect(lease.deviceName == "Mac B")
        #expect(written(harness).isEmpty)
        #expect(throws: ExportBlocked.self) { try reader.export() }
        #expect(written(harness).isEmpty)

        // Not synced on this Mac: the outcome raises the follow banner.
        let notSynced = StoredStatus(lastExport: nil, records: 0, pendingReview: 0, pendingAsOf: nil)
        let banners = UIBanner.banners(
            status: notSynced, plan: nil, outcome: outcome, deviceID: harness.device.id, now: harness.clock.now)
        #expect(banners == [.leaderElsewhere(name: "Mac B", expires: lease.expiresAt, stale: false)])
        #expect(banners.first?.message.hasPrefix("Mac B is syncing this folder; this Mac will follow.") == true)
        #expect(banners.first?.id == "lease")

        // Take Over: the first export runs and this Mac leads.
        let taken = try reader.sync(UISyncRequest(takeOver: true))
        #expect(taken.summary?.wasExport == true)
        #expect(macB(harness).read()?.deviceName == "Test Mac")
        #expect(try reader.read()?.hasSynced == true)
    }

    @Test("a configured vault this Mac never synced, led elsewhere: the follow banner, from the stored lease")
    func joiningMacBanner() throws {
        let harness = CLIHarness.exported()
        let joining = CLIHarness(
            store: harness.store, vault: harness.vault, device: DeviceIdentity(id: "device-c", name: "Mac C"))
        let reader = reader(joining)
        guard case .leaseHeldElsewhere = try reader.sync() else {
            Issue.record("Test Mac leads after its export: Mac C must not write")
            return
        }
        let data = try #require(try reader.read())
        #expect(!data.hasSynced)
        let banners = UIBanner.banners(
            status: data.status, plan: nil, outcome: nil, deviceID: data.device.id, now: joining.clock.now)
        guard case .leaderElsewhere(let name, _, _)? = banners.first else {
            Issue.record("expected the follow banner, got \(banners)")
            return
        }
        #expect(name == "Test Mac")
        let line = try #require(UIFollowerLine.current(live: nil, status: data.status, now: joining.clock.now))
        #expect(line.text == "Test Mac leads syncing this folder")
        #expect(
            line.detail
                == "This Mac has not synced this folder yet, and nothing retries it: run the first sync again once "
                + "Test Mac stops leading, or use Take Over.")
    }

    // MARK: - Follower dry run failures

    @Test("follower dry run without Contacts access: following with the failure, nothing written")
    func followerFailure() throws {
        let harness = CLIHarness.exported()
        _ = try macB(harness).takeOver()
        harness.store.denyAccess()
        harness.vault.resetWrites()
        let outcome = harness.runner().runNow(SyncRunRequest(SyncTrigger(.live))) { _ in }
        guard case .following(let holder, .failed(let message)) = outcome else {
            Issue.record("expected a failed follower check, got \(outcome)")
            return
        }
        #expect(holder.deviceName == "Mac B")
        #expect(message == ContactStoreError.accessDenied.description)
        #expect(harness.vault.writes.isEmpty)
    }

    @Test("UILiveState: the follower line shows what the leader still has to apply, or the failed check")
    func followerLine() {
        var state = UILiveState()
        let lease = VaultLease(
            deviceID: "mac-b", deviceName: "Mac B", acquiredAt: Self.now, heartbeatAt: Self.now,
            expiresAt: Self.now.addingTimeInterval(1200))
        let holder = LeaseHolder(lease, now: Self.now)
        #expect(state.follower(now: Self.now) == nil)
        var summary = SyncRunSummary(
            kind: .live, startedAt: Self.now, finishedAt: Self.now, appleFull: false, appleRead: "incremental")
        summary.markdownUpdated = 2
        summary.appleUpdated = 1
        #expect(state.apply(.following(device: holder, check: .checked(summary))) == .refresh)
        let line = state.follower(reviewTotal: 1, now: Self.now)
        #expect(line?.text == "Mac B leads; it still has 3 changes to apply")
        #expect(line?.isError == false)
        #expect(line?.detail.hasSuffix(". 1 item needs review; answers made here are carried out by Mac B.") == true)
        #expect(
            state.follower(reviewTotal: 2, now: Self.now)?.detail.hasSuffix(
                ". 2 items need review; answers made here are carried out by Mac B.") == true)
        #expect(
            state.follower(now: Self.now)?.detail.hasSuffix(". Review answers made here are carried out by Mac B.")
                == true)
        #expect(state.display(now: Self.now)?.text == "Waiting for Mac B")
        // A heartbeat noticing the leader keeps the last check.
        state.apply(.following(device: holder, check: nil))
        #expect(state.follower(now: Self.now)?.text == "Mac B leads; it still has 3 changes to apply")

        state.apply(.following(device: holder, check: .failed("Contacts access was denied")))
        let failed = state.follower(now: Self.now)
        #expect(failed?.isError == true)
        #expect(failed?.text == "Mac B leads; this Mac could not check what is left")
        #expect(failed?.detail == "Contacts access was denied")
        let display = state.display(now: Self.now)
        #expect(display?.text == "Following Mac B: check failed")
        #expect(display?.tone == .error)
        #expect(
            display?.detail?.hasSuffix("This Mac could not check what is left to sync: Contacts access was denied")
                == true)

        // Nothing left to do.
        state.apply(
            .following(
                device: holder,
                check: .checked(
                    SyncRunSummary(
                        kind: .live, startedAt: Self.now, finishedAt: Self.now, appleFull: false, appleRead: ""))))
        #expect(state.follower(now: Self.now)?.text == "Mac B leads; it has nothing left to apply")

        // This Mac synced itself: no longer following.
        state.apply(.finished(summary))
        #expect(state.follower(now: Self.now) == nil)
        #expect(state.followerCheck == nil)
        #expect(UIFollowerLine.current(live: state, status: nil, now: Self.now) == nil)
    }
}

/// Settings ▸ Advanced ▸ Sync lease and iCloud versions in Duplicates (M6 follow-ups).
@Suite("M6 follow-ups: lease settings and iCloud versions in the app")
struct LeaseSettingsUITests {
    static let macB = LeaseFollowUpTests.macB
    static let now = LeaseFollowUpTests.now

    func macB(_ harness: CLIHarness) -> LeaseManager { LeaseFollowUpTests().macB(harness) }

    func reader(_ harness: CLIHarness) -> UIVaultReader { LeaseFollowUpTests().reader(harness) }

    // MARK: - Settings ▸ Advanced ▸ Sync lease

    func status(lease: VaultLease?, devices: [DeviceRecord] = []) -> StoredStatus {
        var status = StoredStatus(lastExport: Self.now, records: 1, pendingReview: 0, pendingAsOf: nil)
        status.lease = lease
        status.devices = devices
        return status
    }

    @Test("lease info: leader, stale follower, vacant; other devices; live status overrides the stored one")
    func leaseInfo() {
        let mine = VaultLease(
            deviceID: "mac-a", deviceName: "Mac A", acquiredAt: Self.now, heartbeatAt: Self.now,
            expiresAt: Self.now.addingTimeInterval(1200))
        let devices = [
            DeviceRecord(deviceID: "mac-a", deviceName: "Mac A", lastSync: Self.now, summary: "a"),
            DeviceRecord(
                deviceID: "mac-c", deviceName: "Mac C", lastSync: Self.now.addingTimeInterval(-7200), summary: "c"),
            DeviceRecord(
                deviceID: "mac-b", deviceName: "Mac B", lastSync: Self.now.addingTimeInterval(-60), summary: "b"),
        ]
        let leader = UILeaseInfo(
            status: status(lease: mine, devices: devices), live: nil, deviceID: "mac-a", now: Self.now)
        #expect(leader.role == .leader && leader.roleText == "This Mac leads syncing" && leader.holder == "This Mac")
        #expect(leader.canRelease && !leader.canTakeOver && !leader.isStale)
        #expect(leader.heartbeat != nil && leader.expires != nil)
        #expect(leader.otherDevices.map(\.name) == ["Mac B", "Mac C"])
        #expect(leader.otherDevices.allSatisfy { !$0.isLeader })

        let theirs = VaultLease(
            deviceID: "mac-b", deviceName: "Mac B", acquiredAt: Self.now,
            heartbeatAt: Self.now.addingTimeInterval(-11 * 60),
            expiresAt: Self.now.addingTimeInterval(600))
        let follower = UILeaseInfo(
            status: status(lease: theirs, devices: devices), live: nil, deviceID: "mac-a", now: Self.now)
        #expect(follower.role == .follower && follower.holder == "Mac B")
        #expect(follower.isStale && follower.roleText == "Following Mac B (no heartbeat for over 10 minutes)")
        #expect(follower.canTakeOver && !follower.canRelease)
        #expect(follower.otherDevices.first { $0.name == "Mac B" }?.isLeader == true)

        var released = mine
        released.releasedAt = Self.now
        released.expiresAt = Self.now
        let vacant = UILeaseInfo(status: status(lease: released), live: nil, deviceID: "mac-a", now: Self.now)
        #expect(vacant.role == .vacant && vacant.roleText == "No device leads" && vacant.holder == nil)
        #expect(vacant.heartbeat == nil && !vacant.canRelease && !vacant.canTakeOver)
        #expect(vacant.otherDevices.isEmpty)

        // The coordinator just took over: its status wins over the stored follower view.
        let live = LeaseStatus(lease: mine, deviceID: "mac-a", now: Self.now)
        let afterTakeOver = UILeaseInfo(status: status(lease: theirs), live: live, deviceID: "mac-a", now: Self.now)
        #expect(afterTakeOver.role == .leader)
        // A later reload saw a newer heartbeat than the coordinator's last check.
        var later = mine
        later.heartbeatAt = Self.now.addingTimeInterval(300)
        let reloaded = UILeaseInfo(status: status(lease: later), live: live, deviceID: "mac-a", now: Self.now)
        #expect(reloaded.heartbeat == UIFormat.relativeDay(later.heartbeatAt, now: Self.now))
    }

    @Test("Release Lease from the app (live sync not running) frees the lease for other devices")
    func releaseFromApp() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        #expect(try reader.leaseStatus().role == .leader)
        let status = try reader.releaseLease()
        #expect(status.role == .vacant)
        guard case .acquired = try macB(harness).acquire(otherDevicesKnown: true) else {
            Issue.record("a released lease is free for any device")
            return
        }
        #expect(try reader.leaseStatus().role == .follower)
    }

    // MARK: - iCloud conflict versions in Duplicates

    @Test("iCloud versions: a Duplicates group with the current contents and each version; keep-current / keep-other:N")
    func fileVersions() throws {
        let conflict = FileVersionConflict(
            path: "Inbox/Ann One.md", title: "Ann One", recordID: UUID(), currentSHA256: "cur",
            versions: [
                FileVersionInfo(
                    sha256: "v1", modifiedAt: Self.now.addingTimeInterval(-60), deviceName: "Mac B",
                    differences: ["job_title", "emails"]),
                FileVersionInfo(sha256: "v2", modifiedAt: nil, deviceName: nil, differences: []),
            ])
        let entry = PendingReview(item: .fileVersionConflict(conflict), firstSeen: Self.now)
        let note = UINoteSummaryFixture.ann
        let group = try #require(UIDuplicateGroup(entry, plan: nil, notes: [note.path: note]))
        #expect(group.kind == .fileVersions)
        #expect(group.title == "Ann One" && group.counts == "2 other versions")
        #expect(group.reasons.first == "iCloud kept 2 conflicting versions of Inbox/Ann One.md")
        #expect(group.actions == [.ignoreForNow])
        #expect(group.cards.map(\.heading) == ["Current", "Version 1 · Mac B", "Version 2"])
        #expect(group.cards[0].path == "Inbox/Ann One.md" && group.cards[0].source == .fileVersion(index: nil))
        #expect(group.cards[1].lines.first == "From Mac B")
        #expect(group.cards[1].lines.contains { $0.hasPrefix("Modified ") })
        #expect(group.cards[1].lines.last == "Differs: job_title, emails")
        #expect(group.cards[2].lines == ["From another device", "Differs in formatting only"])
        let actions = group.cards.compactMap(\.action)
        #expect(actions == [.keepCurrentVersion, .keepOtherVersion(index: 0), .keepOtherVersion(index: 1)])
        let answers = actions.compactMap { $0.decision(itemID: group.id) }
        #expect(
            answers.map { answer -> String in
                if case .choice(_, let choice) = answer { return choice }
                return ""
            } == ["keep-current", "keep-other:1", "keep-other:2"])
        for choice in ["keep-current", "keep-other:1", "keep-other:2"] { #expect(entry.item.choices.contains(choice)) }
        let decision = try #require(
            try entry.item.decisions(for: "keep-other:1", device: Self.macB, at: Self.now).first)
        #expect(decision.kind == .fileVersionKeep && decision.version == "v1")
        #expect(group.keepVersionMessage(.keepCurrentVersion).hasPrefix("Inbox/Ann One.md stays as it is on this Mac"))
        #expect(group.keepVersionMessage(.keepOtherVersion(index: 0)).contains("replaced with Version 1 · Mac B"))
    }

    @Test("iCloud versions in the review queues count as duplicates")
    func fileVersionsQueue() throws {
        let harness = CLIHarness.exported()
        let reader = reader(harness)
        let state = try harness.stateStore()
        let conflict = FileVersionConflict(
            path: "Inbox/Ann One.md", title: "Ann One", recordID: nil, currentSHA256: "cur",
            versions: [FileVersionInfo(sha256: "v1", deviceName: "Mac B", differences: ["text"])])
        try state.savePending(
            try state.loadPending().replacing(with: [.fileVersionConflict(conflict)], at: harness.clock.now))
        let queues = UIReviewQueues(data: try #require(try reader.read()))
        #expect(queues.duplicates.map(\.kind) == [.fileVersions])
        #expect(queues.counts.duplicates == 1)
        #expect(queues.duplicates.first?.reasons.last == "nothing is lost until you keep one")
    }
}

/// A note summary for adapter tests.
enum UINoteSummaryFixture {
    static var ann: UINoteSummary {
        UINoteSummary(
            path: "Inbox/Ann One.md", title: "Ann One", kind: .person, syncID: UUID(), organization: nil,
            jobTitle: nil, emails: ["ann@example.com"], phones: [], tags: [], isDataless: false)
    }
}
