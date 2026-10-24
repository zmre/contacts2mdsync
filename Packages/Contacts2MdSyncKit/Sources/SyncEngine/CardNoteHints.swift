public import ContactModel
internal import Foundation

/// What a run knows about cards' notes, for `AppleWriteBatch.cardNotes`
/// (card id → has a note; architecture §6 "Write routing"). A card whose
/// note was not read is left out (unknown); unknown is never "no note".
public enum CardNoteHints {
    /// The notes of `cardIDs` among `contacts` read with their notes. A
    /// contact whose notes are unknown (`notesUnknown`) is left out.
    public static func from(_ contacts: [AppleContact], cardIDs: Set<String>) -> [String: Bool] {
        var notes: [String: Bool] = [:]
        for contact in contacts where contact.notesUnknown != true {
            for card in contact.cards where cardIDs.contains(card.id) {
                guard let values = contact.values(of: card) else { continue }
                notes[card.id] = !(values.body ?? "").isEmpty
            }
        }
        return notes
    }

    /// The notes of `cardIDs` in `snapshot`, only when it was read with notes
    /// (the entitlement or the notes bridge); else nothing is known.
    public static func from(_ snapshot: AppleSnapshot, cardIDs: Set<String>) -> [String: Bool] {
        snapshot.notesAvailable ? from(snapshot.contacts, cardIDs: cardIDs) : [:]
    }

    /// The outcome of `NotesProvider.readAll`: a card absent from the read is unknown.
    public static func from(read: [String: String?]) -> [String: Bool] {
        read.mapValues { !($0 ?? "").isEmpty }
    }

    /// The notes of `cardIDs` in this device's Apple mirror (`meta.apple_cache`),
    /// when the mirror was saved by a run that read notes. The mirror may be
    /// a little old: a stale "no note" costs one refused save and a retry
    /// through Contacts.app, a stale "has a note" one scripted write.
    public static func fromMirror(in state: any SyncStateStore, cardIDs: Set<String>) -> [String: Bool] {
        guard !cardIDs.isEmpty, let data = try? state.metadata(AppleChangeTracker.cacheKey),
            let cache = AppleSnapshotCache.decode(data), cache.notesAvailable
        else { return [:] }
        return from(cache.contacts, cardIDs: cardIDs)
    }
}
