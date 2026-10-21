internal import ContactModel
internal import Foundation

/// A record merged into another by a merge-keep decision.
struct MergedRecord {
    /// The record that survives.
    var kept: UUID
    /// Cards carrying the merged record's stamp (the stamp is removed).
    var stampedCards: [String]
}

extension PlanningRun {
    /// A contact carrying several stamps (cards stamped separately, then
    /// linked): bound to the record a merge-keep decision chose, or left
    /// alone with a merge-records review item.
    mutating func resolveSeveralStamps(_ contact: AppleContact, stamps: [UUID]) {
        if let kept = mergeKept(contact, stamps: stamps) {
            boundIDs[contact.unifiedID] = kept
            corroborated.insert(kept)
            for loser in stamps where loser != kept {
                mergedAway[loser] = MergedRecord(
                    kept: kept, stampedCards: contact.cards.filter { $0.stampID == loser }.map(\.id))
            }
            return
        }
        let paths = stamps.flatMap { id in index.entries(withID: id).map(\.path) }.sorted()
        plan.reviews.append(.mergeRecords(contact: ref(contact), ids: stamps, paths: paths))
        skip(contact, "carries several sync stamps (linked cards); pick the surviving note")
        blocked.insert(contact.unifiedID)
    }

    /// The record a merge-keep decision keeps for `contact` (its note's id
    /// must be one of the contact's stamps), or `nil`.
    func mergeKept(_ contact: AppleContact, stamps: [UUID]) -> UUID? {
        guard let path = decisions.mergeKeptPath(for: contact), let id = index.entry(atPath: path)?.syncID,
            stamps.contains(id)
        else { return nil }
        return id
    }

    // MARK: Two-way: merged records

    /// The notes of records merged into another are detached (once) and
    /// their stamps removed from the contact's cards.
    mutating func applyMergeDecisions() {
        for (loser, merge) in mergedAway.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            sync?.removed.insert(loser)
            let keptPath = note(of: merge.kept)?.path ?? merge.kept.uuidString.lowercased()
            if let entry = note(of: loser), entry.contact?.sync.status != SyncMetadata.detached {
                detach(entry, id: loser, reason: "merged into \(keptPath)")
            }
            guard !merge.stampedCards.isEmpty else { continue }
            let change = AppleRecordChange(
                recordID: loser, title: note(of: loser)?.title ?? keptPath, kind: .unstamp,
                operations: merge.stampedCards.map { .removeStamp(cardID: $0) }, fields: [])
            sync?.appleChanges.append(change)
        }
    }
}
