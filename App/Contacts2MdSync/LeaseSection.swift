import Contacts2MdCLI
import SwiftUI

/// Settings ▸ Advanced ▸ Sync lease (architecture §11): who leads syncing
/// this folder, the leader's heartbeat, staleness, the other devices, and
/// Take Over / Release Lease (both confirmed).
struct LeaseSection: View {
    let model: AppModel
    @State private var confirming: LeaseAction?

    private enum LeaseAction: Identifiable {
        case takeOver(device: String)
        case release

        var id: String {
            switch self {
            case .takeOver: "take-over"
            case .release: "release"
            }
        }
    }

    var body: some View {
        if let info = model.leaseInfo {
            LabeledContent("Sync lease") {
                HStack(spacing: 6) {
                    MeaningDot(color: info.isStale ? .orange : info.role == .leader ? .green : .gray)
                    Text(info.roleText)
                }
            }
            .help("Several devices sharing one folder take turns: the leader writes, the others only check.")
            .confirmationDialog(
                title, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming
            ) { action in
                switch action {
                case .takeOver:
                    Button("Take Over") { Task { await model.takeOver() } }
                case .release:
                    Button("Release Lease") { Task { await model.releaseLease() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(message(action))
            }
            if let heartbeat = info.heartbeat {
                LabeledContent("Last heartbeat") {
                    Text(heartbeat).monospacedDigit().foregroundStyle(info.isStale ? .orange : .secondary)
                }
            }
            if let expires = info.expires {
                LabeledContent("Turn ends") { Text(expires).monospacedDigit().foregroundStyle(.secondary) }
            }
            if info.canTakeOver || info.canRelease {
                HStack {
                    Spacer()
                    if info.canTakeOver, let holder = info.holder {
                        Button("Take Over…") { confirming = .takeOver(device: holder) }
                            .disabled(!model.canSync)
                    }
                    if info.canRelease {
                        Button("Release Lease…") { confirming = .release }
                    }
                }
            }
            if info.otherDevices.isEmpty {
                LabeledContent("Other devices") { Text("None").foregroundStyle(.secondary) }
            } else {
                ForEach(info.otherDevices) { device in
                    LabeledContent {
                        Text("last sync \(device.lastSync)").monospacedDigit().foregroundStyle(.secondary)
                    } label: {
                        Text(device.name + (device.isLeader ? " (leads)" : ""))
                        Text(device.summary)
                    }
                }
            }
        }
    }

    private func message(_ action: LeaseAction) -> String {
        switch action {
        case .takeOver(let device):
            "Only take over if \(device) is off or stuck. This Mac waits about a minute so other devices see "
                + "the change, then syncs."
        case .release:
            "Another device may lead at once. While live sync runs on this Mac, its next sync takes the lease "
                + "again unless another device does first."
        }
    }

    private var title: String {
        switch confirming {
        case .takeOver(let device): "Take over syncing from \(device)?"
        case .release: "Release the sync lease?"
        case nil: ""
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }
}
