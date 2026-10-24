import Contacts2MdCLI
import SwiftUI
import SyncEngine

/// Toolbar status: the coordinator's status (Scheduled, Syncing… phase,
/// Waiting for *device*, Paused: safety breaker, Failed), else reading /
/// checking, else Idle or the review count (orange).
struct StatusIndicator: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if let own = ownRun {
                ProgressView().controlSize(.small)
                Text(own)
            } else if let live = model.live.state.display() {
                if live.tone == .busy {
                    ProgressView().controlSize(.small)
                } else {
                    MeaningDot(color: live.tone == .error ? .red : .gray)
                }
                Text(live.text)
            } else {
                switch model.phase {
                case .loading, .checking:
                    ProgressView().controlSize(.small)
                    Text(model.phase == .loading ? "Reading…" : model.runProgress?.text ?? "Checking…")
                case .syncing:
                    ProgressView().controlSize(.small)
                    Text(model.runProgress?.text ?? (model.data?.hasSynced == false ? "Exporting…" : "Syncing…"))
                case .idle:
                    MeaningDot(color: color)
                    Text(text)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
        // Breathing room inside the toolbar's glass capsule.
        .padding(.horizontal, 10)
        .help(help)
    }

    /// The app's own run started by the user (a banner action, Sync Now):
    /// shown before the coordinator's status, from the moment it is asked for.
    private var ownRun: String? {
        guard let feedback = model.runFeedback else { return nil }
        // A plain Sync Now through the coordinator: its status takes over once it runs.
        if model.phase == .idle, !feedback.isWaiting, model.live.state.isRunning { return nil }
        return feedback.statusText
    }

    private var help: String {
        if let own = ownRun, let feedback = model.runFeedback {
            return "\(feedback.action.progressTitle.replacingOccurrences(of: "…", with: "")): \(own)"
        }
        if model.live.state.display() == nil, model.phase != .idle, let progress = model.runProgress {
            return progress.text
        }
        return model.live.state.display()?.detail ?? ""
    }

    private var color: Color {
        if model.errorMessage != nil { return .red }
        return model.counts.total > 0 ? .orange : .gray
    }

    private var text: String {
        if model.errorMessage != nil { return "Error" }
        let total = model.counts.total
        return total > 0 ? "\(total.formatted()) to review" : "Idle"
    }
}
