internal import ContactModel
internal import Foundation
internal import VaultIndex

/// Phase 5 of `PlanningRun`: unbound contacts against notes nobody is bound
/// to — adoption of hand-written notes, relocation of orphaned records, and
/// the create gate (architecture §6, cascade steps 3–6).
extension PlanningRun {
    // MARK: Phase 5: unbound contacts vs unbound notes (adoption, relocation, create gate)

    mutating func matchUnboundContacts() {
        let (adoptable, ignored) = adoptableNotes()
        plan.ignoredCandidates = ignored
        let candidateIndex = CandidateIndex(entries: adoptable, keyer: planner.keyer)
        let unbound = contacts.filter { boundIDs[$0.unifiedID] == nil && !blocked.contains($0.unifiedID) }
        let scored = score(unbound, against: candidateIndex)
        var taken = Set<Int>()
        for contact in unbound {
            let matches = scored.byContact[contact.unifiedID] ?? []
            // A recorded adopt decision wins.
            if let forced = adoptionByDecision(contact, candidateIndex), !taken.contains(forced) {
                bind(contact, to: candidateIndex.candidates[forced].entry, detail: "adopted (decision)")
                taken.insert(forced)
                continue
            }
            guard let best = matches.first(where: { !$0.score.advisory }) else {
                warnSharedEmail(contact, matches, candidateIndex)
                continue
            }
            let entry = candidateIndex.candidates[best.index].entry
            let strongRivals = matches.filter {
                $0.index != best.index && !$0.score.advisory && $0.score.confidence >= MatchScore.gateThreshold
            }
            let unique = strongRivals.isEmpty && (scored.byNote[best.index] ?? []) == [contact.unifiedID]
            let isRelocation = entry.syncID.map { records[$0] != nil } ?? false
            let isDetached = entry.syncID.map(detachedIDs.contains) ?? false
            if !taken.contains(best.index), best.score.confidence >= MatchScore.adoptThreshold, unique, !isDetached,
                isRelocation || plan.autoAdopt
            {
                let reasons = best.score.reasons.joined(separator: ", ")
                bind(contact, to: entry, detail: isRelocation ? "relinked (\(reasons))" : "adopted (\(reasons))")
                taken.insert(best.index)
            } else {
                proposeOrWarn(contact, best, candidateIndex)
            }
        }
        let adoptedCandidates = taken.filter { candidateIndex.candidates[$0].entry.syncID == nil }.count
        plan.markdownOnly = adoptable.filter { $0.syncID == nil }.count - adoptedCandidates
    }

    /// Contact notes nobody is bound to: hand-written ones (no id) and
    /// orphaned ones (an id no contact claims this run). Also counts the
    /// markdown-only notes a decision ignores.
    func adoptableNotes() -> (notes: [VaultEntry], ignored: Int) {
        let boundRecordIDs = Set(boundIDs.values)
        var ignored = 0
        let notes = index.contacts.filter { entry in
            guard !ignoredCopies.contains(entry.path) else { return false }
            if let id = entry.syncID, boundRecordIDs.contains(id) || pausedIDs.contains(id) { return false }
            if decisions.isIgnored(path: entry.path, syncID: entry.syncID) {
                if entry.syncID == nil { ignored += 1 }
                return false
            }
            return true
        }
        return (notes, ignored)
    }

    /// Cascade scores per contact (best first) and, per note, the contacts
    /// matching it at or above the create gate.
    func score(
        _ unbound: [AppleContact], against candidates: CandidateIndex
    ) -> (byContact: [String: [(index: Int, score: MatchScore)]], byNote: [Int: [String]]) {
        var byContact: [String: [(index: Int, score: MatchScore)]] = [:]
        var byNote: [Int: [String]] = [:]
        for contact in unbound {
            let profile = MatchProfile(apple: values(contact), keyer: planner.keyer)
            let matches = candidates.matches(for: profile).filter {
                !decisions.isDistinct(contact, fromNoteAt: candidates.candidates[$0.index].entry.path)
            }
            byContact[contact.unifiedID] = matches
            for match in matches where match.score.confidence >= MatchScore.gateThreshold {
                byNote[match.index, default: []].append(contact.unifiedID)
            }
        }
        return (byContact, byNote)
    }

    /// The candidate an adopt decision assigns to `contact`, if any.
    func adoptionByDecision(_ contact: AppleContact, _ candidates: CandidateIndex) -> Int? {
        candidates.candidates.indices.first { index in
            decisions.adoption(ofNoteAt: candidates.candidates[index].entry.path)?.matches(contact) == true
        }
    }

    mutating func bind(_ contact: AppleContact, to entry: VaultEntry, detail: String) {
        let id = entry.syncID ?? planner.ids.next()
        boundIDs[contact.unifiedID] = id
        adoptions[contact.unifiedID] = (entry, detail)
    }

    /// Only advisory matches (an email shared with someone whose name
    /// differs): the contact is exported as usual, with a warning.
    mutating func warnSharedEmail(
        _ contact: AppleContact, _ matches: [(index: Int, score: MatchScore)], _ candidates: CandidateIndex
    ) {
        for match in matches where match.score.advisory {
            let entry = candidates.candidates[match.index].entry
            plan.warnings.append(
                "\"\(title(contact))\" shares an email with \(entry.path), but the names differ "
                    + "(\(match.score.reasons.last ?? "")); treated as different people")
        }
    }

    /// Any match blocks creation (≥ 0.5 per the create gate; name-only too,
    /// because the note is unbound and probably the same person).
    mutating func proposeOrWarn(
        _ contact: AppleContact, _ match: (index: Int, score: MatchScore), _ candidates: CandidateIndex
    ) {
        let entry = candidates.candidates[match.index].entry
        proposedPaths.insert(entry.path)
        plan.reviews.append(
            .possibleMatch(
                contact: ref(contact), path: entry.path, confidence: match.score.confidence,
                reasons: match.score.reasons))
        skip(contact, "may already exist as \(entry.path)")
        blocked.insert(contact.unifiedID)
    }
}
