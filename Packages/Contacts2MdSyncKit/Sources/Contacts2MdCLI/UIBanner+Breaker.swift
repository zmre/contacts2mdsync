internal import SyncEngine
internal import VaultIndex

extension UIBanner {
    /// "Sync paused: 22 notes disappeared from the notes folder since the
    /// last sync (e.g. Jane Doe.md, John Roe.md, …). Is the folder
    /// available? Nothing was written."
    static func breakerMessage(_ trip: BreakerTrip) -> String {
        let apple = trip.side == "apple"
        let noun = apple ? (trip.vanished == 1 ? "contact" : "contacts") : (trip.vanished == 1 ? "note" : "notes")
        let names = trip.paths.prefix(2).map { path in
            apple ? VaultPath.stem(of: path) : String(path.split(separator: "/").last ?? Substring(path))
        }
        let more = trip.paths.count > names.count ? ", …" : ""
        let examples = names.isEmpty ? "" : " (e.g. \(names.joined(separator: ", "))\(more))"
        return apple
            ? "Sync paused: \(trip.vanished) \(noun) disappeared from Contacts since the last sync\(examples). "
                + "Is iCloud signed in? Nothing was written."
            : "Sync paused: \(trip.vanished) \(noun) disappeared from the notes folder since the last sync"
                + "\(examples). Is the folder available? Nothing was written."
    }
}
