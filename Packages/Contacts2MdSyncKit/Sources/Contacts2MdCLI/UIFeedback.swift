public import Foundation
public import SyncEngine

// Immediate feedback for what the user just asked for (docs/ui.md §3, §9,
// §12): a banner button turns into "Resuming…" with a spinner the moment
// it is clicked, the toolbar shows the run's phase as soon as it has one,
// and a vault switch shows its new position (with "Saving…") while the
// config write is in flight. Nothing waits for a lock, the coordinator or
// a recount before it shows.

/// A user action that starts work: Sync Now and the banner actions.
public enum UIUserAction: String, Hashable, Sendable {
    case syncNow
    case resumeAnyway
    case applyAnyway
    case takeOver
    case checkAgain
    case turnOnAppleWrites

    /// What its button says while it runs: `Resuming…`, `Applying…`, …
    public var progressTitle: String {
        switch self {
        case .syncNow: "Syncing…"
        case .resumeAnyway: "Resuming…"
        case .applyAnyway: "Applying…"
        case .takeOver: "Taking Over…"
        case .checkAgain: "Checking…"
        case .turnOnAppleWrites: "Turning On…"
        }
    }

    /// The banner (`UIBanner.id`) whose button shows the progress.
    public var bannerID: String? {
        switch self {
        case .syncNow: nil
        case .resumeAnyway, .checkAgain: "breaker"
        case .applyAnyway: "blast-radius"
        case .takeOver: "lease"
        case .turnOnAppleWrites: "apple-writes"
        }
    }
}

/// The app's own run as the toolbar and the banner button show it.
public struct UIRunFeedback: Hashable, Sendable {
    public var action: UIUserAction
    /// The run's phase once it reported one.
    public var phase: SyncPhase?
    /// Waiting for a sync already running on this Mac (the live coordinator,
    /// a check, or the command line) before this one can start.
    public var isWaiting: Bool

    /// Feedback for `action`, shown at once.
    public init(_ action: UIUserAction, phase: SyncPhase? = nil, isWaiting: Bool = false) {
        self.action = action
        self.phase = phase
        self.isWaiting = isWaiting
    }

    public static let waitingText = SyncPhase.waitingForLock.text

    /// Toolbar status: the phase (with counts) once known, else the action.
    public var statusText: String {
        if isWaiting || phase == .waitingForLock { return Self.waitingText }
        return phase?.text ?? action.progressTitle
    }

    /// The banner button while it runs.
    public var buttonTitle: String { isWaiting || phase == .waitingForLock ? "Waiting…" : action.progressTitle }
}

/// A vault switch change in flight (`apple_writes`, `stamp_contacts`).
public struct UIPendingOptions: Hashable, Sendable {
    public var requested: UIVaultOptions

    /// Creates a pending change.
    public init(_ requested: UIVaultOptions) { self.requested = requested }

    /// What the switches show: the requested position while it is being
    /// saved, else what is stored.
    public static func displayed(stored: UIVaultOptions?, pending: UIPendingOptions?) -> UIVaultOptions? {
        pending?.requested ?? stored
    }
}

/// A count shown in a confirmation before a fresh dry run finished:
/// "24 changes are waiting (as of Today 10:42 AM)".
public struct UICountFreshness: Hashable, Sendable {
    /// When the count was computed (`nil`: never).
    public var computedAt: Date?
    /// A dry run is refreshing it now.
    public var isUpdating: Bool

    /// Creates the freshness of a count.
    public init(computedAt: Date?, isUpdating: Bool) {
        self.computedAt = computedAt
        self.isUpdating = isUpdating
    }

    /// `as of Today 10:42 AM` (empty without a date).
    public func asOf(now: Date = Date()) -> String {
        computedAt.map { "as of \(UIFormat.relativeDay($0, now: now))" } ?? ""
    }
}
