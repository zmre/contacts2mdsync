public import Foundation
import SyncTriggers

// Following another device (architecture §11, M6; docs/ui.md §3, §14): the
// Overview line that says who leads and what it still has to apply, or why
// this Mac could not check.

extension UILiveState {
    /// The Overview line while another device leads (`nil` otherwise):
    /// `Mac B leads; it still has 3 changes to apply`, `… nothing left to
    /// apply`, or the failed check.
    public func follower(now: Date = Date()) -> UIFollowerLine? {
        guard case .waitingForDevice(let name, _)? = problem else { return nil }
        switch followerCheck {
        case .checked(let summary)?:
            let changes =
                summary.appleCreated + summary.appleUpdated + summary.appleDeleted + summary.markdownCreated
                + summary.markdownUpdated + summary.markdownTrashed
            let text =
                changes == 0
                ? "\(name) leads; it has nothing left to apply"
                : "\(name) leads; it still has \(changes.formatted()) \(changes == 1 ? "change" : "changes") to apply"
            let review =
                summary.pendingReview > 0
                ? "\(summary.pendingReview.formatted()) review \(summary.pendingReview == 1 ? "item" : "items") "
                    + "answered here are carried out by \(name)."
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
    /// live sync is hosted (`live`), else from the stored lease (`status`),
    /// which knows who leads but not what is left to apply.
    public static func current(live: UILiveState?, status: StoredStatus?, now: Date = Date()) -> UIFollowerLine? {
        if let live { return live.follower(now: now) }
        guard let status, status.leaseRole == .follower, let holder = status.leaseHolder else { return nil }
        let detail =
            status.lastExport == nil
            ? "This Mac has not synced this folder yet; its first sync waits until \(holder.deviceName) stops leading."
            : "This Mac follows: Check for Changes shows what is left; review answers made here are carried out "
                + "by \(holder.deviceName)."
        return UIFollowerLine(text: "\(holder.deviceName) leads syncing this folder", detail: detail, isError: false)
    }
}
