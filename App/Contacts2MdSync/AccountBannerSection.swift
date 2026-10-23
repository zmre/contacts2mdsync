import Contacts2MdCLI
import SwiftUI
import SyncEngine

/// Overview banner for a Contacts account that is not visible in Contacts
/// (docs/ui.md §3 "Unavailable accounts"): its cards are kept as last seen.
/// Keep Waiting records `wait`; Forget This Account… shows what would be
/// removed and records `forget` (applied by the next sync).
struct AccountBannerSection: View {
    let model: AppModel
    let banner: UIAccountBanner
    @State private var confirmingForget = false

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.text).fontWeight(.semibold)
                    Text(banner.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if banner.forgetPending {
                        Text("Forget chosen: the next sync removes it.").font(.caption).foregroundStyle(.orange)
                    }
                }
            } icon: {
                Image(
                    systemName: banner.isReturning
                        ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.questionmark"
                )
                .foregroundStyle(banner.isReturning ? Color.accentColor : .orange)
            }
            if !banner.isReturning, !banner.forgetPending {
                HStack {
                    Spacer()
                    Button("Keep Waiting") {
                        Task { await model.decide([.choice(itemID: banner.itemID, choice: "wait")]) }
                    }
                    .disabled(banner.decision == "wait" || banner.preview == nil)
                    .help("Keep its cards as last seen until the account is back (the default)")
                    Button("Forget This Account…") { confirmingForget = true }
                        .disabled(banner.preview == nil)
                        .help(
                            banner.preview == nil ? "Check for changes first" : "Remove it from your notes on purpose")
                }
            }
        }
        .sheet(isPresented: $confirmingForget) {
            if let preview = banner.preview {
                ForgetAccountSheet(preview: preview) {
                    confirmingForget = false
                    Task { await model.decide([.choice(itemID: banner.itemID, choice: "forget")]) }
                } cancel: {
                    confirmingForget = false
                }
            }
        }
    }
}

/// What forgetting an account changes: counts and examples, before anything happens.
private struct ForgetAccountSheet: View {
    let preview: AccountMissingReview
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forget \(preview.label)?").font(.title3.weight(.semibold))
            Text(
                "Only do this if you removed the account on purpose. Nothing happens until the next sync, "
                    + "and no note is deleted without your confirmation."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !preview.frozenTitles.isEmpty {
                LabeledContent("Contacts only in this account") {
                    Text(preview.frozenTitles.count.formatted()).monospacedDigit()
                }
                Text(
                    "They move to Pending Deletions; each note stays until you confirm. For example: "
                        + preview.frozenTitles.prefix(5).joined(separator: ", ")
                        + (preview.frozenTitles.count > 5 ? ", …" : "")
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Notes losing values only this account held") {
                Text(preview.removals.count.formatted()).monospacedDigit()
            }
            if !preview.removals.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.removals.prefix(50), id: \.path) { removal in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(removal.title)
                                Text(removal.values.joined(separator: " · ")).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if preview.removals.count > 50 {
                            Text("and \(preview.removals.count - 50) more").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Forget Account", role: .destructive, action: confirm)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
