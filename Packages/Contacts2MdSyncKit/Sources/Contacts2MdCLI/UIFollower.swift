public import Foundation
internal import SyncEngine
internal import SyncTriggers

// Following another device (architecture §11, M6; docs/ui.md §3, §14): the
// Overview line that says who leads and what it still has to apply, or why
// this Mac could not check.

extension UILiveState {
    /// `true` while another device leads (as last reported).
    public var isFollowing: Bool { leaderName != nil }

    /// The device that leads, while another device leads.
    var leaderName: String? {
        if case .waitingForDevice(let name, _)? = problem { return name }
        return nil
    }

    /// The Overview line while another device leads (`nil` otherwise):
    /// `Mac B leads; it still has 3 changes to apply`, `… nothing left to
    /// apply`, or the failed check. `reviewTotal` is the Needs Review count
    /// (`UIReviewCounts.total`): answers made here are carried out by the leader.
    public func follower(reviewTotal: Int = 0, now: Date = Date()) -> UIFollowerLine? {
        guard let name = leaderName else { return nil }
        switch followerCheck {
        case .checked(let summary)?:
            // Held Apple changes (`apple_writes` off, over the limit) wait for
            // approval; the leader does not apply them.
            let changes = summary.changeCount
            let text =
                changes == 0
                ? "\(name) leads; it has nothing left to apply"
                : "\(name) leads; it still has \(changes) \(changes == 1 ? "change" : "changes") to apply"
            let review =
                reviewTotal > 0
                ? "\(reviewTotal) \(reviewTotal == 1 ? "item needs" : "items need") review; "
                    + "answers made here are carried out by \(name)."
                : "Review answers made here are carried out by \(name)."
            return UIFollowerLine(
                text: text, detail: "As of \(UIFormat.relativeDay(summary.finishedAt, now: now)). " + review,
                isError: false)
        case .failed(let message)?:
            return UIFollowerLine(
                text: "\(name) leads; this Mac could not check what is left", detail: message, isError: true)
        case nil:
            return UIFollowerLine(
                text: "\(name) leads syncing this folder", detail: "This Mac follows: it checks but writes nothing.",
                isError: false)
        }
    }
}

/// The Overview's "following" line (another device leads).
public struct UIFollowerLine: Hashable, Sendable {
    public var text: String
    public var detail: String
    /// The check failed (shown in red).
    public var isError: Bool

    /// Creates a line.
    public init(text: String, detail: String, isError: Bool) {
        self.text = text
        self.detail = detail
        self.isError = isError
    }
}

extension UIFollowerLine {
    /// The Overview's following line: from the coordinator's state while
    /// live sync is hosted (`live`) and it has seen the leader, else from
    /// the stored lease (`status`), which knows who leads (until its lease
    /// expires) but not what is left to apply.
    public static func current(
        live: UILiveState?, status: StoredStatus?, reviewTotal: Int = 0, now: Date = Date()
    ) -> UIFollowerLine? {
        if let line = live?.follower(reviewTotal: reviewTotal, now: now) { return line }
        guard let status, status.leaseRole == .follower, let holder = status.leaseHolder, holder.expiresAt > now
        else { return nil }
        let name = holder.deviceName
        let detail =
            status.lastExport == nil
            ? "This Mac has not synced this folder yet, and nothing retries it: run the first sync again once "
                + "\(name) stops leading, or use Take Over."
            : "This Mac follows: Check for Changes shows what is left; review answers made here are carried out "
                + "by \(name)."
        return UIFollowerLine(text: "\(name) leads syncing this folder", detail: detail, isError: false)
    }
}
