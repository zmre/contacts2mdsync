internal import Foundation
public import SyncEngine

/// A Contacts account that is not visible in Contacts (or came back and is
/// being matched), for the Overview banner, the menu bar and the Forget
/// confirmation (docs/ui.md §3, architecture §9 "Unavailable accounts").
public struct UIAccountBanner: Hashable, Sendable, Identifiable {
    /// The account's container id.
    public var id: String
    /// The review item answering it (`account-missing:<container id>`).
    public var itemID: String
    /// `Google account isn't visible in Contacts — 1,353 cards kept as last seen`.
    public var text: String
    /// When it was last seen, and where to turn it back on.
    public var detail: String
    /// Visible again; its cards are still being matched (no buttons).
    public var isReturning: Bool
    /// The latest answer recorded for it (`wait`, `forget`), if any.
    public var decision: String?
    /// What Forget would do (from the latest check), when known.
    public var preview: AccountMissingReview?

    /// `true` once Forget was chosen (it takes effect on the next sync).
    public var forgetPending: Bool { decision == "forget" }

    /// Banners for `data`: one per unavailable account this Mac tracks.
    public static func banners(_ data: UIVaultData) -> [UIAccountBanner] {
        data.status.unavailableAccounts.map { account in
            let itemID = AccountMissingReview.idPrefix + account.containerID
            let preview = data.pending.items.lazy.compactMap { entry -> AccountMissingReview? in
                guard case .accountMissing(let review) = entry.item, review.containerID == account.containerID else {
                    return nil
                }
                return review
            }.first
            let status = AccountStatus(account: account, frozenRecords: 0, linkedRecords: 0, heldChanges: 0)
            let decision = data.decisions.last { $0.itemID == itemID && $0.createdAt >= account.since }?.choice
            let seen = "Last seen \(UIFormat.relativeDay(account.lastSeen))."
            return UIAccountBanner(
                id: account.containerID, itemID: itemID, text: status.banner,
                detail: status.isReturning
                    ? "Its cards are matched to your notes as they come back; nothing is created twice."
                    : "\(seen) Nothing in your notes changes while it is away. \(status.hint).",
                isReturning: status.isReturning, decision: decision, preview: preview)
        }
    }
}
