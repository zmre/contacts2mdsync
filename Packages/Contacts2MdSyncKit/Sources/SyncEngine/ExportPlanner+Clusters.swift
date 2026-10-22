internal import ContactModel
internal import Foundation

/// Phase 4 of `PlanningRun`: unlinked duplicate clusters (architecture §6).
/// An unresolved cluster yields at most one note; a resolved one yields one
/// note per person the user named (`cluster-resolve`, `distinct-people`,
/// `sync-only`).
extension PlanningRun {
    // MARK: Phase 4: duplicate clusters → at most one note each (per decided person)

    mutating func limitClustersToOneNote() {
        let eligible = contacts.filter {
            !blocked.contains($0.unifiedID) || boundIDs[$0.unifiedID] != nil || decisionExcluded.contains($0.unifiedID)
        }
        let byUnifiedID = Dictionary(eligible.map { ($0.unifiedID, $0) }, uniquingKeysWith: { first, _ in first })
        let clusterInput = eligible.map { contact -> AppleContact in
            var copy = contact
            copy.contact = values(contact)
            return copy
        }
        var roles: [String: ClusterRole] = [:]
        for contact in eligible { roles[contact.unifiedID] = clusterRole(of: contact) }
        // Contacts answering to one reference are the halves of a contact
        // unlinked since the decision: undecided, so the cluster is asked again.
        let owners = Dictionary(grouping: roles) { "\($0.value.decision)#\($0.value.reference)" }
        for entries in owners.values where entries.count > 1 {
            for entry in entries { roles[entry.key] = nil }
        }
        var byGroup: [String: [String]] = [:]
        for contact in eligible {
            guard let key = roles[contact.unifiedID]?.groupKey else { continue }
            byGroup[key, default: []].append(contact.unifiedID)
        }
        let decidedSame: [[String]] = byGroup.keys.sorted().compactMap { key in
            guard let ids = byGroup[key], ids.count > 1 else { return nil }
            return ids
        }
        let clusters = Clustering.clusters(
            of: clusterInput, keyer: planner.keyer, areDistinct: { decisions.areDistinct($0, $1) },
            decidedSame: decidedSame)
        for cluster in clusters {
            // Member numbers (`resolve:1,2/3`) follow the cards, not the
            // volatile unified ids, so they mean the same contacts next run.
            let members = cluster.memberIDs.compactMap { byUnifiedID[$0] }.sorted { $0.sortKey < $1.sortKey }
            if isSettled(cluster, roles: roles) {
                settle(members, roles: roles)
                continue
            }
            // Members left out by a decision never stand in for the cluster.
            let syncable = members.filter { !decisionExcluded.contains($0.unifiedID) }
            let alreadyExported = syncable.contains { notePath(of: $0) != nil }
            let primary =
                alreadyExported ? nil : ExportPlanner.primary(of: syncable.filter { !blocked.contains($0.unifiedID) })
            for member in syncable where boundIDs[member.unifiedID] == nil && member.unifiedID != primary?.unifiedID {
                blocked.insert(member.unifiedID)
                skip(member, "possible duplicate; review before export")
            }
            plan.reviews.append(
                .duplicateCluster(members: describe(members, cluster: cluster, roles: roles), reasons: cluster.reasons))
        }
    }

    /// Every member was decided, and every link joins members answered by
    /// the same decision. A link between members of different decisions (or
    /// to an undecided member) is a signal nobody has reviewed yet.
    func isSettled(_ cluster: DuplicateCluster, roles: [String: ClusterRole]) -> Bool {
        guard cluster.memberIDs.allSatisfy({ roles[$0] != nil }) else { return false }
        return cluster.links.allSatisfy { link in roles[link.first]?.decision == roles[link.second]?.decision }
    }

    /// A decided cluster: each group gets one note (the member that has one,
    /// else the group's primary); excluded members were blocked in phase 3.
    /// A member that is itself held back (a detached note, …) never keeps
    /// the person's note.
    mutating func settle(_ members: [AppleContact], roles: [String: ClusterRole]) {
        let people = Dictionary(grouping: members.filter { roles[$0.unifiedID]?.groupKey != nil }) {
            roles[$0.unifiedID]?.groupKey ?? ""
        }
        for key in people.keys.sorted() {
            let group = people[key] ?? []
            guard group.count > 1 else { continue }
            let candidates = group.filter { !blocked.contains($0.unifiedID) }
            let exported = candidates.first { notePath(of: $0) != nil }
            guard let keeper = exported ?? ExportPlanner.primary(of: candidates) else { continue }
            for member in group where boundIDs[member.unifiedID] == nil && member.unifiedID != keeper.unifiedID {
                guard !blocked.contains(member.unifiedID) else { continue }
                blocked.insert(member.unifiedID)
                skip(
                    member, "same person as \(title(keeper)) (decision); link the cards in Contacts",
                    needsReview: false)
            }
        }
    }

    /// The earlier answer for a member, as shown in review.
    func prior(_ role: ClusterRole?, groupNumbers: [String: Int]) -> ClusterPriorAnswer? {
        guard let role else { return nil }
        if role.isExcluded { return .excluded }
        return role.groupKey.flatMap { groupNumbers[$0] }.map { .person($0) }
    }

    /// Review members with their links and any earlier answer.
    func describe(
        _ members: [AppleContact], cluster: DuplicateCluster, roles: [String: ClusterRole]
    ) -> [ClusterMember] {
        let index = Dictionary(members.enumerated().map { ($1.unifiedID, $0) }, uniquingKeysWith: { first, _ in first })
        var groupNumbers: [String: Int] = [:]
        for member in members {
            if let key = roles[member.unifiedID]?.groupKey, groupNumbers[key] == nil {
                groupNumbers[key] = groupNumbers.count
            }
        }
        return members.map { member in
            let links = cluster.links.compactMap { link -> ClusterLink? in
                if link.first == member.unifiedID, let other = index[link.second] {
                    return ClusterLink(other: other, reasons: link.reasons)
                }
                if link.second == member.unifiedID, let other = index[link.first] {
                    return ClusterLink(other: other, reasons: link.reasons)
                }
                return nil
            }
            let role = roles[member.unifiedID]
            return ClusterMember(
                unifiedID: member.unifiedID, title: title(member), accounts: member.cards.map(\.accountKind),
                path: notePath(of: member), cardIDs: member.cardIDs.sorted(), links: links,
                prior: prior(role, groupNumbers: groupNumbers))
        }
    }
}
