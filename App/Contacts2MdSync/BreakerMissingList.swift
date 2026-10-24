import Contacts2MdCLI
import SwiftUI
import SyncEngine

/// The notes a tripped breaker counted (the breaker banner's Show Missing).
struct MissingList: View {
    let trip: BreakerTrip
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(trip.paths, id: \.self) { path in
                Text(path).textSelection(.enabled)
            }
            .frame(minHeight: 160, idealHeight: 260)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        trip.side == "apple"
            ? "\(trip.vanished) \(trip.vanished == 1 ? "contact" : "contacts") missing from Contacts"
            : "\(trip.vanished) \(trip.vanished == 1 ? "note" : "notes") missing from the notes folder"
    }

    private var explanation: String {
        trip.side == "apple"
            ? "These notes' contacts were in Contacts at the last sync and are gone now. "
                + "If an account was turned off, turn it back on and Check Again."
            : "These notes were in the folder at the last sync and are gone now. "
                + "If the folder or iCloud Drive is unavailable, fix that and Check Again."
    }
}
