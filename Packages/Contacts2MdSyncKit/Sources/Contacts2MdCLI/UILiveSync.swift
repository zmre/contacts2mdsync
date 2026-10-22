public import Foundation
public import SyncEngine
public import SyncTriggers

// Live sync in the app (architecture §10 "Hosting in the app"; docs/ui.md
// §1 toolbar, §9 Settings ▸ General, §10 menu bar): what the coordinator's
// status stream means for the toolbar and menu bar, the effective trigger
// settings while live sync is paused, the safety-check choices, and the
// background (launchd) schedule. Pure values; the app owns the coordinator.

/// The coordinator's status folded into what the app shows.
///
/// `SyncCoordinator` reports a blocked or failed run and then goes `idle`
/// at once, so the latest status alone would hide "Waiting for Mac B" a
/// moment after it appears. This keeps the last problem until a run
/// finishes, and the last finished run's summary.
public struct UILiveState: Hashable, Sendable {
    /// What the coordinator is doing right now.
    public enum Activity: Hashable, Sendable {
        case idle
        /// A run of this kind starts at the date (debounce, lock retry).
        case scheduled(SyncRunKind, startsAt: Date)
        /// A run is in progress (`nil` phase: just started).
        case running(SyncRunKind, SyncPhase?)
    }

    /// Why the last run did not happen or did not finish.
    public enum Problem: Hashable, Sendable {
        /// Another device leads syncing this folder until `until`.
        case waitingForDevice(name: String, until: Date)
        /// The mass-vanish breaker stopped the run; nothing was written.
        case breaker(String)
        /// Another run on this Mac (CLI, launchd) holds the lock; retried.
        case localRunInProgress
        /// Not configured, no Contacts access, folder unavailable.
        case notRunnable(String)
        /// An unexpected error.
        case failed(String)
    }

    /// What applying a status asks of the app.
    public enum Effect: Hashable, Sendable {
        case none
        /// Re-read stored data and run a dry run (review queue, banners).
        case refresh
    }

    public private(set) var activity: Activity = .idle
    public private(set) var problem: Problem?
    /// The last run that finished (written or not).
    public private(set) var lastSummary: SyncRunSummary?
    /// While another device leads: what this Mac's last read-only check
    /// found (what the leader still has to apply), or why it failed.
    public private(set) var followerCheck: FollowerCheck?
    /// The leading device the check is about (`LeaseHolder.deviceID`).
    private var leaderID: String?

    /// Creates an idle state.
    public init() {}

    /// `true` while a run is in progress.
    public var isRunning: Bool {
        if case .running = activity { return true }
        return false
    }

    /// Folds one status update in.
    @discardableResult
    public mutating func apply(_ status: SyncCoordinatorStatus) -> Effect {
        switch status {
        case .idle:
            activity = .idle
        case .scheduled(let kind, let startsAt):
            activity = .scheduled(kind, startsAt: startsAt)
        case .running(let kind, let phase):
            activity = .running(kind, phase)
        case .finished(let summary):
            activity = .idle
            lastSummary = summary
            problem = nil
            followerCheck = nil
            leaderID = nil
            return .refresh
        case .following(let holder, let check):
            activity = .idle
            return follow(holder, check: check)
        case .followingEnded:
            return stopFollowing()
        case .blocked(let reason):
            activity = .idle
            return block(reason)
        case .failed(let message):
            activity = .idle
            problem = .failed(message)
        case .skipped:
            break
        }
        return .none
    }

    /// M6: another device leads; a run was a read-only dry run (a
    /// heartbeat that noticed the leader carries no check). A check made
    /// while another device led says nothing about this one.
    private mutating func follow(_ holder: LeaseHolder, check: FollowerCheck?) -> Effect {
        if holder.deviceID != leaderID { followerCheck = nil }
        leaderID = holder.deviceID
        problem = .waitingForDevice(name: holder.deviceName, until: holder.expiresAt)
        if let check { followerCheck = check }
        return .refresh
    }

    /// The leader's lease lapsed or this Mac took it (the run that follows
    /// reports itself; it may be skipped with live sync off).
    private mutating func stopFollowing() -> Effect {
        if isFollowing { problem = nil }
        followerCheck = nil
        leaderID = nil
        return .refresh
    }

    /// A dry run made outside the coordinator (Check for Changes, after a
    /// review answer) while another device leads: it replaces the last
    /// check, so the follower line counts what is left from it.
    public mutating func recheck(_ summary: SyncRunSummary) {
        guard isFollowing else { return }
        followerCheck = .checked(summary)
    }

    /// A blocked run: remembered until a run finishes. The lock retry is
    /// the coordinator's business; anything else may change the banners.
    private mutating func block(_ reason: SyncBlockReason) -> Effect {
        switch reason {
        case .localRunInProgress:
            problem = .localRunInProgress
            return .none
        case .leaseHeldElsewhere(let name, let until):
            // No device id here: another name is another leader.
            if leaderName != name {
                followerCheck = nil
                leaderID = nil
            }
            problem = .waitingForDevice(name: name, until: until)
        case .breaker(let message): problem = .breaker(message)
        case .notRunnable(let message): problem = .notRunnable(message)
        }
        return .refresh
    }

    /// The toolbar / menu bar status, or `nil` when idle with nothing to
    /// report (the app then shows Idle or the review count).
    public func display(now: Date = Date()) -> UILiveDisplay? {
        switch activity {
        case .running(let kind, let phase):
            let text = phase.map { "Syncing… \(Self.phaseText($0))" } ?? "Syncing…"
            return UILiveDisplay(text: text, detail: "\(Self.kindText(kind)) sync in progress", tone: .busy)
        case .scheduled(let kind, let startsAt):
            let seconds = max(0, Int(startsAt.timeIntervalSince(now).rounded()))
            return UILiveDisplay(
                text: "Scheduled", detail: "\(Self.kindText(kind)) sync in \(seconds) s", tone: .idle)
        case .idle:
            break
        }
        switch problem {
        case .waitingForDevice(let name, let until)?:
            let detail = "\(name) is syncing this folder; its turn ends by \(UIFormat.relativeDay(until, now: now))."
            if let error = followerCheck?.error {
                return UILiveDisplay(
                    text: "Following \(name): check failed",
                    detail: detail + " This Mac could not check what is left to sync: \(error)", tone: .error)
            }
            return UILiveDisplay(text: "Waiting for \(name)", detail: detail, tone: .paused)
        case .breaker(let message)?:
            return UILiveDisplay(text: "Paused: safety breaker", detail: message, tone: .error)
        case .localRunInProgress?:
            return UILiveDisplay(
                text: "Waiting for another sync", detail: "Another sync is running on this Mac; retrying shortly.",
                tone: .paused)
        case .notRunnable(let message)?:
            return UILiveDisplay(text: "Can't sync", detail: message, tone: .error)
        case .failed(let message)?:
            return UILiveDisplay(text: "Failed", detail: message, tone: .error)
        case nil:
            return nil
        }
    }

    /// The menu bar's first line (docs/ui.md §10): the live status while
    /// there is one, else `✓ In sync · Today 10:42 AM`, `3 to review · …`
    /// or `Not synced on this Mac yet`.
    public func headline(lastSync: Date?, reviewTotal: Int, now: Date = Date()) -> String {
        if let display = display(now: now) { return display.text }
        guard let lastSync else { return "Not synced on this Mac yet" }
        let when = UIFormat.relativeDay(lastSync, now: now)
        return reviewTotal > 0 ? "\(reviewTotal.formatted()) to review · synced \(when)" : "✓ In sync · \(when)"
    }

    /// `reading`, `writing`, …
    static func phaseText(_ phase: SyncPhase) -> String {
        switch phase {
        case .waitingForLock: "waiting"
        case .scanning: "reading"
        case .planning: "planning"
        case .writing: "writing"
        }
    }

    /// `Live`, `Sync Now`, … (the Activity trigger, with Manual as Sync Now).
    static func kindText(_ kind: SyncRunKind) -> String {
        kind == .manual ? "Sync Now" : kind.displayName
    }
}

/// One status line: text, tooltip and dot color.
public struct UILiveDisplay: Hashable, Sendable {
    /// The dot color: gray idle, accent busy, gray-pause waiting, red error.
    public enum Tone: Hashable, Sendable {
        case idle
        case busy
        case paused
        case error
    }

    public var text: String
    public var detail: String?
    public var tone: Tone

    /// Creates a display.
    public init(text: String, detail: String? = nil, tone: Tone) {
        self.text = text
        self.detail = detail
        self.tone = tone
    }
}

// MARK: - Pause (menu bar ▸ Pause Live Sync)

/// How long Pause Live Sync lasts (docs/ui.md §10: 1 hr · Day).
public enum UILivePause: String, CaseIterable, Hashable, Sendable, Identifiable {
    case oneHour
    case untilTomorrow

    public var id: Self { self }

    /// Menu title.
    public var title: String {
        switch self {
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        }
    }

    /// When live sync resumes: an hour from `now`, or the start of the next day.
    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .untilTomorrow:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86400)
        }
    }
}

/// The trigger settings in effect and how to describe them.
public enum UILiveSettings {
    /// The saved settings with live sync off while a pause lasts. The sweep
    /// keeps running (it is a safety net, not a live trigger), and Sync Now
    /// always works.
    public static func effective(_ settings: TriggerSettings, pausedUntil: Date?, now: Date) -> TriggerSettings {
        guard let pausedUntil, pausedUntil > now else { return settings }
        var effective = settings
        effective.liveSync = false
        return effective
    }

    /// `true` while a pause is in effect (and live sync is on in Settings).
    public static func isPaused(_ settings: TriggerSettings, pausedUntil: Date?, now: Date) -> Bool {
        settings.liveSync && (pausedUntil.map { $0 > now } ?? false)
    }

    /// `Live sync on`, `Live sync off`, `Live sync paused until 3:42 PM`.
    public static func line(_ settings: TriggerSettings, pausedUntil: Date?, now: Date) -> String {
        guard settings.liveSync else { return "Live sync off" }
        if let pausedUntil, pausedUntil > now {
            return "Live sync paused until \(UIFormat.relativeDay(pausedUntil, now: now))"
        }
        return "Live sync on"
    }
}

// MARK: - Safety check (Settings ▸ General)

/// One choice of the Safety check picker: a full compare every N hours, or off.
public enum UISweepChoice: Hashable, Sendable, Identifiable {
    case hours(Int)
    case off

    /// The standard choices (architecture §10: 1–6 h, default 2 h, or off).
    public static let standard: [UISweepChoice] = [.hours(1), .hours(2), .hours(4), .hours(6), .off]

    /// The choice for a stored interval (rounded to whole hours).
    public init(interval: TimeInterval?) {
        guard let interval else {
            self = .off
            return
        }
        self = .hours(max(1, Int((interval / 3600).rounded())))
    }

    public var id: String { title }

    /// `TriggerSettings.sweepInterval`.
    public var interval: TimeInterval? {
        switch self {
        case .hours(let hours): TimeInterval(hours) * 3600
        case .off: nil
        }
    }

    /// `Every hour`, `Every 2 hours`, `Off`.
    public var title: String {
        switch self {
        case .hours(1): "Every hour"
        case .hours(let hours): "Every \(hours) hours"
        case .off: "Off"
        }
    }

    /// The standard choices, plus `current` when it is not one of them
    /// (`triggers.json` edited by hand), in order.
    public static func choices(including current: UISweepChoice) -> [UISweepChoice] {
        guard !standard.contains(current), case .hours(let hours) = current else { return standard }
        var hourly = standard.compactMap { choice -> Int? in
            if case .hours(let value) = choice { return value }
            return nil
        }
        hourly.append(hours)
        return hourly.sorted().map { .hours($0) } + [.off]
    }
}

// MARK: - Background sync (launchd)

/// The background schedule: a launchd agent that runs the app binary with
/// `sync --quiet` while the app is closed (architecture §15 "Scheduling").
///
/// Bundled agents (`Contents/Library/LaunchAgents/<plistName>`) have a fixed
/// `StartInterval`, so there is one per choice; the app registers one of
/// them with `SMAppService.agent(plistName:)` and unregisters the others.
/// nix-darwin installs use `programs.contacts2mdsync.schedule` instead.
public enum UIBackgroundSync {
    /// How the app was installed.
    public enum Install: Hashable, Sendable {
        /// From the nix store (nix-darwin, `nix build`): the schedule is
        /// declared in the nix-darwin module.
        case nix
        /// Anywhere else: the app registers its bundled agent.
        case standalone
    }

    /// Hours between background syncs the app offers.
    public static let intervals: [Int] = [1, 2, 4, 6]

    /// The launchd label of the agent for `hours`.
    public static func label(hours: Int) -> String { "com.zmre.contacts2mdsync.sync-\(hours)h" }

    /// The bundled plist for `hours` (`SMAppService.agent(plistName:)`).
    public static func plistName(hours: Int) -> String { label(hours: hours) + ".plist" }

    /// `StartInterval` of the agent for `hours`.
    public static func startInterval(hours: Int) -> Int { hours * 3600 }

    /// The arguments every agent passes to the app binary.
    public static let arguments = ["sync", "--quiet"]

    /// nix when the bundle lives in the nix store or nix-darwin's app folder.
    public static func install(bundlePath: String) -> Install {
        let markers = ["/nix/store/", "/Applications/Nix Apps/", "/Applications/Home Manager Apps/"]
        return markers.contains { bundlePath.contains($0) } ? .nix : .standalone
    }

    /// What nix-darwin users add to their configuration.
    public static let nixSnippet = """
        programs.contacts2mdsync.schedule = {
          enable = true;
          interval = 3600;  # seconds
        };
        """

    /// `Every hour`, `Every 2 hours`.
    public static func title(hours: Int) -> String { hours == 1 ? "Every hour" : "Every \(hours) hours" }
}
