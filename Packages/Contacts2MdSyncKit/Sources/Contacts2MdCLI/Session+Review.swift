internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

extension Session {
    /// `review list`: the pending queue from the last plan/export. Needs no
    /// Contacts access.
    func reviewList() -> CLIExitCode {
        run { root in
            let fs = environment.makeVault(root.url)
            let (_, state) = try configuredState(fs)
            let pending = try state.loadPending()
            let decided = Set(try DecisionLog.readAll(fs).decisions.compactMap(\.itemID))
            let open = pending.items.filter { !decided.contains($0.id) }
            let asOf = pending.computedAt.map(report.timestamp) ?? "never"
            report.info("review   \(open.count) pending as of \(asOf) (run `contacts2md plan` to refresh)")
            for entry in open {
                let choices =
                    entry.item.choices.isEmpty
                    ? "resolve in Contacts.app or the notes folder" : entry.item.choices.joined(separator: " | ")
                report.info("item     \(entry.id)  \(entry.item.summary)")
                report.info("         choices: \(choices)")
            }
            if open.count < pending.items.count {
                report.info(
                    "note     \(pending.items.count - open.count) decided items take effect on the next plan/export")
            }
            return open.contains(where: \.item.needsDecision) ? .needsReview : .success
        }
    }

    /// `review decide <item> <choice>`: appends the decision to this device's log.
    func reviewDecide(itemID: String, choice: String) -> CLIExitCode {
        run { root in
            let fs = environment.makeVault(root.url)
            let (_, state) = try configuredState(fs)
            guard let entry = try state.loadPending().items.first(where: { $0.id == itemID }) else {
                report.error("no pending review item \(itemID) (run `contacts2md plan`, then `review list`)")
                return .usage
            }
            let device = try environment.device()
            let decisions: [Decision]
            do {
                decisions = try entry.item.decisions(for: choice, device: device, at: environment.clock.now)
            } catch {
                report.error(String(describing: error))
                return .usage
            }
            try record(decisions, fs: fs, state: state, device: device)
            report.item("decided", "review", "\(itemID) → \(choice): \(entry.item.summary)")
            report.note("takes effect on the next `contacts2md plan` / `export`")
            return .success
        }
    }

    /// `review adopt-all`: adopt every pending possible match whose note is
    /// claimed by exactly one contact.
    func reviewAdoptAll(minConfidence: Double) -> CLIExitCode {
        run { root in
            let fs = environment.makeVault(root.url)
            let (_, state) = try configuredState(fs)
            let decided = Set(try DecisionLog.readAll(fs).decisions.compactMap(\.itemID))
            let matches = try state.loadPending().items.filter { !decided.contains($0.id) }.compactMap(Match.init)
            let claims = Dictionary(grouping: matches, by: \.path)
            let device = try environment.device()
            var decisions: [Decision] = []
            for match in matches where match.confidence >= minConfidence {
                guard claims[match.path]?.count == 1 else {
                    report.warning(
                        "ambiguous", "\(match.path) matches several contacts — decide it with `review decide`")
                    continue
                }
                decisions += try match.item.decisions(for: "adopt", device: device, at: environment.clock.now)
                report.item("decided", "review", "\(match.item.id) → adopt: \(match.item.summary)")
            }
            try record(decisions, fs: fs, state: state, device: device)
            report.info("summary  \(decisions.count) adoptions recorded; they take effect on the next plan/export")
            return .success
        }
    }

    /// A pending possible match.
    private struct Match {
        let item: ReviewItem
        let path: String
        let confidence: Double

        init?(_ entry: PendingReview) {
            guard case .possibleMatch(_, let path, let confidence, _) = entry.item else { return nil }
            self.item = entry.item
            self.path = path
            self.confidence = confidence
        }
    }

    private func record(
        _ decisions: [Decision], fs: any VaultFS, state: any SyncStateStore, device: DeviceIdentity
    ) throws {
        guard !decisions.isEmpty else { return }
        try DecisionLog.append(decisions, deviceID: device.id, fs: fs)
        try state.saveDecisionMirror(try DecisionLog.readAll(fs).decisions)
    }
}
