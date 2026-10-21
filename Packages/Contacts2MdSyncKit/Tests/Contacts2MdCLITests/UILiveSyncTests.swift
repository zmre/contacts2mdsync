import ContactModel
import Contacts2MdCLI
import Foundation
import SyncEngine
import SyncTestSupport
import SyncTriggers
import Testing
import VaultIndex

/// Live sync in the app: coordinator status → toolbar / menu bar, pause,
/// safety-check choices, the background schedule, Activity from live runs.
@Suite("UI live sync adapters")
struct UILiveSyncTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func summary(_ kind: SyncRunKind = .live) -> SyncRunSummary {
        SyncRunSummary(
            kind: kind, startedAt: Self.now, finishedAt: Self.now.addingTimeInterval(2), appleFull: false,
            appleRead: "incremental")
    }

    // MARK: - Status

    @Test("idle shows nothing; scheduled and running show their kind and phase")
    func activityDisplay() {
        var state = UILiveState()
        #expect(state.display(now: Self.now) == nil)
        #expect(state.apply(.scheduled(.live, startsAt: Self.now.addingTimeInterval(3))) == .none)
        #expect(
            state.display(now: Self.now) == UILiveDisplay(text: "Scheduled", detail: "Live sync in 3 s", tone: .idle))
        state.apply(.running(.manual, nil))
        #expect(state.isRunning)
        #expect(state.display(now: Self.now)?.text == "Syncing…")
        #expect(state.display(now: Self.now)?.detail == "Sync Now sync in progress")
        state.apply(.running(.manual, .scanning))
        #expect(state.display(now: Self.now)?.text == "Syncing… reading")
        #expect(state.display(now: Self.now)?.tone == .busy)
        state.apply(.running(.sweep, .writing))
        #expect(state.display(now: Self.now)?.text == "Syncing… writing")
    }

    @Test("a finished run asks for a refresh and clears the last problem")
    func finished() {
        var state = UILiveState()
        state.apply(.running(.live, .planning))
        #expect(state.apply(.blocked(.breaker("214 contacts disappeared"))) == .refresh)
        state.apply(.idle)
        #expect(
            state.display(now: Self.now)
                == UILiveDisplay(
                    text: "Paused: safety breaker", detail: "214 contacts disappeared", tone: .error))
        #expect(state.apply(.finished(summary())) == .refresh)
        state.apply(.idle)
        #expect(state.display(now: Self.now) == nil)
        #expect(state.lastSummary == summary())
        #expect(!state.isRunning)
    }

    @Test("blocked and failed runs stay visible after the coordinator goes idle")
    func problems() {
        var state = UILiveState()
        let until = Self.now.addingTimeInterval(600)
        #expect(state.apply(.blocked(.leaseHeldElsewhere(deviceName: "Mac B", until: until))) == .refresh)
        state.apply(.idle)
        #expect(state.display(now: Self.now)?.text == "Waiting for Mac B")
        #expect(state.display(now: Self.now)?.tone == .paused)
        // The lock retry: no refresh, shown until the retry runs.
        #expect(state.apply(.blocked(.localRunInProgress)) == .none)
        state.apply(.scheduled(.live, startsAt: Self.now.addingTimeInterval(30)))
        #expect(state.display(now: Self.now)?.text == "Scheduled")
        state.apply(.idle)
        #expect(state.display(now: Self.now)?.text == "Waiting for another sync")
        state.apply(.blocked(.notRunnable("no Contacts access")))
        #expect(
            state.display(now: Self.now)
                == UILiveDisplay(
                    text: "Can't sync", detail: "no Contacts access", tone: .error))
        #expect(state.apply(.failed("disk full")) == .none)
        #expect(state.display(now: Self.now) == UILiveDisplay(text: "Failed", detail: "disk full", tone: .error))
        // Skipped triggers (sweep window, live off) change nothing.
        state.apply(.skipped(.sweep, reason: "full compare 3 min ago"))
        #expect(state.display(now: Self.now)?.text == "Failed")
    }

    @Test("menu bar headline: live status first, then sync time and review count")
    func headline() {
        var state = UILiveState()
        let today = Self.now.addingTimeInterval(-60)
        #expect(state.headline(lastSync: nil, reviewTotal: 0, now: Self.now) == "Not synced on this Mac yet")
        #expect(state.headline(lastSync: today, reviewTotal: 0, now: Self.now).hasPrefix("✓ In sync · Today "))
        #expect(state.headline(lastSync: today, reviewTotal: 3, now: Self.now).hasPrefix("3 to review · synced Today "))
        state.apply(.running(.live, .writing))
        #expect(state.headline(lastSync: today, reviewTotal: 3, now: Self.now) == "Syncing… writing")
    }

    @Test("following another device (M6): shown as Waiting for that device, review data refreshed")
    func following() {
        var state = UILiveState()
        let lease = VaultLease(
            deviceID: "mac-b", deviceName: "Mac B", acquiredAt: Self.now, heartbeatAt: Self.now,
            expiresAt: Self.now.addingTimeInterval(1200))
        #expect(state.apply(.following(device: LeaseHolder(lease, now: Self.now), check: nil)) == .refresh)
        state.apply(.idle)
        #expect(state.display(now: Self.now)?.text == "Waiting for Mac B")
    }

    // MARK: - Pause

    @Test("pause: live sync off until the date, sweep kept; menu line")
    func pause() throws {
        let calendar = Calendar(identifier: .gregorian)
        let saved = TriggerSettings(liveSync: true, sweepInterval: 7200)
        let hour = UILivePause.oneHour.until(from: Self.now, calendar: calendar)
        #expect(hour == Self.now.addingTimeInterval(3600))
        let tomorrow = UILivePause.untilTomorrow.until(from: Self.now, calendar: calendar)
        #expect(tomorrow == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Self.now)))
        #expect(tomorrow > Self.now)

        let paused = UILiveSettings.effective(saved, pausedUntil: hour, now: Self.now)
        #expect(paused == TriggerSettings(liveSync: false, sweepInterval: 7200))
        #expect(UILiveSettings.isPaused(saved, pausedUntil: hour, now: Self.now))
        #expect(UILiveSettings.line(saved, pausedUntil: hour, now: Self.now).hasPrefix("Live sync paused until "))
        // Expired pause: the saved settings again.
        #expect(UILiveSettings.effective(saved, pausedUntil: Self.now, now: Self.now) == saved)
        #expect(UILiveSettings.line(saved, pausedUntil: nil, now: Self.now) == "Live sync on")
        // Live sync off in Settings: not "paused".
        let off = TriggerSettings(liveSync: false)
        #expect(!UILiveSettings.isPaused(off, pausedUntil: hour, now: Self.now))
        #expect(UILiveSettings.line(off, pausedUntil: hour, now: Self.now) == "Live sync off")
    }

    // MARK: - Settings

    @Test("safety check choices map to the sweep interval")
    func sweepChoices() {
        #expect(
            UISweepChoice.standard.map(\.title)
                == ["Every hour", "Every 2 hours", "Every 4 hours", "Every 6 hours", "Off"])
        #expect(UISweepChoice(interval: TriggerSettings().sweepInterval) == .hours(2))
        #expect(UISweepChoice(interval: nil) == .off)
        #expect(UISweepChoice.hours(4).interval == 14400)
        #expect(UISweepChoice.off.interval == nil)
        // Round trip through TriggerSettings (clamped to 1–6 h).
        for choice in UISweepChoice.standard {
            let settings = TriggerSettings(liveSync: true, sweepInterval: choice.interval)
            #expect(UISweepChoice(interval: settings.sweepInterval) == choice)
        }
        // A hand-edited 3 h interval stays selectable.
        let odd = UISweepChoice(interval: 3 * 3600)
        #expect(UISweepChoice.choices(including: odd).map(\.title).contains("Every 3 hours"))
        #expect(UISweepChoice.choices(including: .hours(2)) == UISweepChoice.standard)
    }

    @Test("settings saved by the app are what the coordinator loads")
    func settingsStore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ui-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TriggerSettingsStore(directory: directory)
        #expect(store.load() == TriggerSettings())
        let changed = TriggerSettings(liveSync: false, sweepInterval: UISweepChoice.off.interval)
        try store.save(changed)
        #expect(store.load() == changed)
        let text = try String(contentsOf: directory.appending(path: "triggers.json"), encoding: .utf8)
        #expect(text.contains("\"live_sync\" : false"))
        #expect(text.contains("\"sweep_interval_seconds\" : null"))
    }

    @Test("background schedule: nix installs use the nix-darwin module; others the bundled agents")
    func backgroundInstall() {
        #expect(UIBackgroundSync.install(bundlePath: "/nix/store/abc-contacts2mdsync/Applications/X.app") == .nix)
        #expect(UIBackgroundSync.install(bundlePath: "/Applications/Nix Apps/Contacts2MdSync.app") == .nix)
        #expect(UIBackgroundSync.install(bundlePath: "/Applications/Contacts2MdSync.app") == .standalone)
        #expect(UIBackgroundSync.plistName(hours: 2) == "com.zmre.contacts2mdsync.sync-2h.plist")
        #expect(UIBackgroundSync.title(hours: 1) == "Every hour")
        #expect(UIBackgroundSync.nixSnippet.contains("programs.contacts2mdsync.schedule"))
    }

    @Test("the bundled launchd agents match the schedule choices")
    func bundledAgents() throws {
        // App/LaunchAgents, copied into Contents/Library/LaunchAgents by project.yml.
        let folder = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../App/LaunchAgents").standardized
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasSuffix(".plist") }.sorted()
        #expect(files == UIBackgroundSync.intervals.map(UIBackgroundSync.plistName).sorted())
        for hours in UIBackgroundSync.intervals {
            let data = try Data(contentsOf: folder.appending(path: UIBackgroundSync.plistName(hours: hours)))
            let plist = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            #expect(plist["Label"] as? String == UIBackgroundSync.label(hours: hours))
            #expect(plist["StartInterval"] as? Int == UIBackgroundSync.startInterval(hours: hours))
            #expect(plist["BundleProgram"] as? String == "Contents/MacOS/Contacts2MdSync")
            let arguments = try #require(plist["ProgramArguments"] as? [String])
            #expect(Array(arguments.dropFirst()) == UIBackgroundSync.arguments)
            #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.zmre.contacts2mdsync"])
        }
    }
}
