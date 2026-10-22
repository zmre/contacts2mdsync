public import Foundation
public import SyncEngine
internal import VaultIndex

// MARK: - Onboarding step 4: review duplicates (docs/ui.md §2)

/// The duplicate clusters the first preview found, as Duplicates groups,
/// so onboarding can show the cluster partition before the first sync.
/// Skipping is allowed: until a cluster is answered it yields one note
/// (architecture §6 "Unlinked duplicate clusters").
public enum UIOnboardingDuplicates {
    /// Cluster groups of a preview (contact details from its own snapshot).
    public static func groups(_ prepared: PreparedExport, now: Date) -> [UIDuplicateGroup] {
        let summary = UIPlanSummary(prepared, computedAt: now)
        let notes = Dictionary(
            prepared.index.entries.filter(\.isContactNote).map { ($0.path, UINoteSummary($0)) },
            uniquingKeysWith: { first, _ in first })
        return prepared.plan.reviews.compactMap { item in
            guard case .duplicateCluster = item else { return nil }
            return UIDuplicateGroup(PendingReview(item: item, firstSeen: now), plan: summary, notes: notes)
        }
    }
}

extension UIVaultReader {
    /// Records answers to items of a preview made before the folder is
    /// configured (onboarding): appended to this device's decision log in
    /// the folder, like `review decide`. The next preview and the first
    /// export apply them. Returns the number of log entries written.
    @discardableResult
    public func recordPreview(_ answers: [UIReviewDecision], items: [ReviewItem]) throws -> Int {
        let device = try environment.device()
        let now = environment.clock.now
        var decisions: [Decision] = []
        for answer in answers {
            guard case .choice(let itemID, let choice) = answer else { continue }
            guard let item = items.first(where: { $0.id == itemID }) else { throw UIReviewError.itemNotFound(itemID) }
            decisions += try item.decisions(for: choice, device: device, at: now)
        }
        guard !decisions.isEmpty else { return 0 }
        try DecisionLog.append(decisions, deviceID: device.id, fs: environment.makeVault(root))
        return decisions.count
    }
}
