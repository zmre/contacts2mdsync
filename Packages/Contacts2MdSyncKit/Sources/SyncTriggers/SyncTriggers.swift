public import Foundation
public import SyncEngine

// Live sync triggers (architecture §10 "Triggers while the app is running").
//
// `SyncCoordinator` (an actor) turns trigger events into serialized,
// debounced, coalesced sync runs. Runs are executed by a `SyncRunner`
// (`Contacts2MdCLI.VaultSyncRunner` for real: the same `VaultSession` path
// the CLI uses, with the local lock and the vault lease). Trigger sources
// sit behind `SyncTriggerSource` so tests replace them with fakes; nothing
// here imports SwiftUI.

/// Why a run was asked for. Decides full vs incremental (architecture §10).
public enum SyncRunKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// `CNContactStoreDidChange` or an FSEvents file event (debounced).
    case live
    /// FSEvents dropped events (`MustScanSubDirs` / `UserDropped` / `KernelDropped`).
    case rescanVault = "rescan-vault"
    /// App start, after the first sync is done.
    case launch
    /// The Mac woke up (after a delay so iCloud can deliver queued changes).
    case wake
    /// The periodic safety sweep.
    case sweep
    /// Sync Now.
    case manual

    /// How the run reads Apple Contacts: live events and vault rescans use
    /// the history token; catch-up, sweep and manual runs take a full snapshot.
    public var appleMode: AppleReadMode {
        switch self {
        case .live, .rescanVault: .incremental
        case .launch, .wake, .sweep, .manual: .full
        }
    }

    /// Whether requests of this kind wait for the debounce window.
    public var isDebounced: Bool { self == .live || self == .rescanVault }

    /// Higher wins when requests are coalesced (the run is reported as that kind).
    public var priority: Int {
        switch self {
        case .live: 0
        case .rescanVault: 1
        case .sweep: 2
        case .wake: 3
        case .launch: 4
        case .manual: 5
        }
    }

    /// Activity's trigger column (`SessionRecord.trigger`).
    public var displayName: String {
        switch self {
        case .live: "Live"
        case .rescanVault: "Rescan"
        case .launch: "Launch"
        case .wake: "Wake"
        case .sweep: "Sweep"
        case .manual: "Manual"
        }
    }
}

/// One event from a trigger source.
public struct SyncTrigger: Hashable, Sendable {
    public var kind: SyncRunKind
    /// Short human-readable cause (`Contacts changed`, `Work/Jane.md`, …).
    public var reason: String

    /// Creates a trigger.
    public init(_ kind: SyncRunKind, reason: String = "") {
        self.kind = kind
        self.reason = reason
    }
}

/// One coalesced run request handed to the runner.
public struct SyncRunRequest: Hashable, Sendable {
    /// The highest-priority kind among the coalesced triggers.
    public var kind: SyncRunKind
    /// Every kind coalesced into this run.
    public var kinds: Set<SyncRunKind>
    /// `.full` when any coalesced kind needs a full snapshot.
    public var appleMode: AppleReadMode
    /// Events were lost (FSEvents drop flags): the vault must be rescanned.
    /// Every run enumerates the whole vault anyway (FSEvents only triggers
    /// runs, it never supplies the change set), so this is informational.
    public var vaultRescan: Bool
    /// Trigger reasons, oldest first (at most 20).
    public var reasons: [String]
    /// Retries after the local lock was busy.
    public var attempt: Int

    /// A request for one trigger.
    public init(_ trigger: SyncTrigger) {
        kind = trigger.kind
        kinds = [trigger.kind]
        appleMode = trigger.kind.appleMode
        vaultRescan = trigger.kind == .rescanVault
        reasons = trigger.reason.isEmpty ? [] : [trigger.reason]
        attempt = 0
    }

    /// This request with `trigger` coalesced into it.
    public func merging(_ trigger: SyncTrigger) -> SyncRunRequest {
        var merged = self
        if trigger.kind.priority > kind.priority { merged.kind = trigger.kind }
        merged.kinds.insert(trigger.kind)
        if trigger.kind.appleMode == .full { merged.appleMode = .full }
        merged.vaultRescan = vaultRescan || trigger.kind == .rescanVault
        if !trigger.reason.isEmpty, merged.reasons.count < 20 { merged.reasons.append(trigger.reason) }
        return merged
    }

    /// This request coalesced with another (`other`'s retry count is dropped).
    public func merging(_ other: SyncRunRequest) -> SyncRunRequest {
        var merged = self
        if other.kind.priority > kind.priority { merged.kind = other.kind }
        merged.kinds.formUnion(other.kinds)
        if other.appleMode == .full { merged.appleMode = .full }
        merged.vaultRescan = vaultRescan || other.vaultRescan
        merged.reasons = Array((reasons + other.reasons).prefix(20))
        return merged
    }
}

/// What one run did, for status displays and the menu bar.
public struct SyncRunSummary: Hashable, Sendable, Codable {
    public var kind: SyncRunKind
    public var startedAt: Date
    public var finishedAt: Date
    /// `true` when Apple was read with a full snapshot.
    public var appleFull: Bool
    /// `full snapshot (reason)` / `incremental: …`.
    public var appleRead: String
    public var appleCreated = 0
    public var appleUpdated = 0
    public var appleDeleted = 0
    /// Apple changes planned but not written (`apple_writes` off, change limit).
    public var appleHeld = 0
    /// Why Apple changes were held, if they were.
    public var appleHoldReason: String?
    public var markdownCreated = 0
    public var markdownUpdated = 0
    public var markdownTrashed = 0
    /// Other vault writes: images, resolved iCloud conflict versions, the
    /// config file.
    public var otherWrites = 0
    /// Review items that need a decision.
    public var pendingReview = 0
    public var conflicts = 0
    /// Write failures (`path: message`, `title: message`).
    public var failures: [String] = []
    /// Records whose markdown body went into Contacts notes, and Contacts
    /// notes that went into markdown (included in the counts above).
    public var notesToContacts = 0
    public var notesToMarkdown = 0
    /// Notes wanted but skipped this run (no Automation permission, a failed
    /// read), or note writes that failed: the first warning.
    public var notesWarning: String?
    /// A Contacts account is not visible in Contacts (its cards are kept as
    /// last seen): the first one's banner text.
    public var accountWarning: String?

    /// Creates a summary.
    public init(kind: SyncRunKind, startedAt: Date, finishedAt: Date, appleFull: Bool, appleRead: String) {
        self.kind = kind
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.appleFull = appleFull
        self.appleRead = appleRead
    }

    /// Changes on both sides: written by a run, or still to apply as seen
    /// by a follower's check. Held Apple changes are not counted.
    public var changeCount: Int {
        appleCreated + appleUpdated + appleDeleted + markdownCreated + markdownUpdated + markdownTrashed + otherWrites
    }

    /// Anything written on either side.
    public var changedSomething: Bool { changeCount > 0 }

    /// One line: `apple c/u/d 0/1/0  md c/u/d 1/0/0  review 2  held 1`.
    public var line: String {
        var text =
            "apple c/u/d \(appleCreated)/\(appleUpdated)/\(appleDeleted)"
            + "  md c/u/d \(markdownCreated)/\(markdownUpdated)/\(markdownTrashed)  review \(pendingReview)"
        if appleHeld > 0 { text += "  held \(appleHeld)" }
        if notesToContacts + notesToMarkdown > 0 {
            text += "  notes →contacts \(notesToContacts) →md \(notesToMarkdown)"
        }
        if notesWarning != nil { text += "  notes skipped" }
        if accountWarning != nil { text += "  account missing" }
        if !failures.isEmpty { text += "  failures \(failures.count)" }
        return text
    }
}

/// Why a run did not happen (or stopped before writing).
public enum SyncBlockReason: Hashable, Sendable {
    /// Another run on this Mac (CLI, launchd) holds the local lock.
    case localRunInProgress
    /// Another device leads this vault until `until`.
    case leaseHeldElsewhere(deviceName: String, until: Date)
    /// The mass-vanish breaker tripped; nothing was written.
    case breaker(String)
    /// Not configured, no Contacts access, folder unavailable.
    case notRunnable(String)

    /// Human-readable text.
    public var message: String {
        switch self {
        case .localRunInProgress: "another sync is running on this Mac"
        case .leaseHeldElsewhere(let name, _): "\(name) leads syncing for this vault"
        case .breaker(let message): message
        case .notRunnable(let message): message
        }
    }
}

/// The result of one runner call.
public enum SyncRunOutcome: Hashable, Sendable {
    case finished(SyncRunSummary)
    /// Another device leads: this device ran a read-only dry run (nothing
    /// written to the vault or Contacts). `check` says what it found, or
    /// why it could not look (no Contacts access, …).
    case following(LeaseHolder, FollowerCheck)
    case blocked(SyncBlockReason)
    /// An unexpected error (the message).
    case failed(String)
}

/// What a follower's read-only dry run found.
public enum FollowerCheck: Hashable, Sendable {
    /// The dry run worked. Counts are what the leader still has to do, as
    /// seen from here.
    case checked(SyncRunSummary)
    /// The dry run failed (no Contacts access, first sync not done on this
    /// Mac, folder unreadable): the message. The review queue and status
    /// here are not current.
    case failed(String)

    /// The summary of a successful check.
    public var summary: SyncRunSummary? {
        if case .checked(let summary) = self { return summary }
        return nil
    }

    /// The message of a failed check.
    public var error: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Executes one sync run (the coordinator never runs two at once).
public protocol SyncRunner: Sendable {
    /// Runs `request` to completion, reporting phases through `progress`.
    func run(_ request: SyncRunRequest, progress: @escaping @Sendable (SyncPhase) -> Void) async -> SyncRunOutcome

    /// When a run on this device was last planned on a full Apple snapshot
    /// (by any process), for the sweep window.
    func lastFullCompare() async -> Date?
}

/// Delivers trigger events to the coordinator. Implementations must be
/// thread-safe; `start` is called once, `stop` may be called repeatedly.
public protocol SyncTriggerSource: AnyObject, Sendable {
    /// Starts delivering triggers to `emit` (from any thread).
    func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void)
    /// Stops delivering triggers.
    func stop()
}

/// Wall-clock time and sleeping, injectable so tests control time.
public protocol TriggerClock: Sendable {
    var now: Date { get }
    /// Sleeps until `deadline` (returns at once when it has passed). Throws
    /// `CancellationError` when the task is cancelled.
    func sleep(until deadline: Date) async throws
}

/// The real clock.
public struct SystemTriggerClock: TriggerClock {
    /// Creates the clock.
    public init() {}

    public var now: Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
