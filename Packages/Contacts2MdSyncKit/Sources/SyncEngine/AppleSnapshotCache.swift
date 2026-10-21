internal import ContactModel
internal import Foundation

/// The persisted Apple mirror: the snapshot without image bytes, image
/// hashes, and the history token it is current as of. Stored compressed in
/// the device state's `meta` table.
struct AppleSnapshotCache: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var token: Data?
    var savedAt: Date
    var settingsKey: String
    var contacts: [AppleContact]
    var imageHashes: [String: String]
    var containers: [AppleContainer]
    var groups: [AppleGroup]
    var notesAvailable: Bool

    init(
        snapshot: AppleSnapshot, token: Data?, imageHashes: [String: String], masked: Set<String>,
        settingsKey: String, savedAt: Date
    ) {
        version = Self.currentVersion
        self.token = token
        self.savedAt = savedAt
        self.settingsKey = settingsKey
        contacts = snapshot.contacts.map { contact in
            var stripped = contact
            stripped.imageData = nil
            // A masked image is known (hashed), not unavailable.
            if contact.cards.contains(where: { masked.contains($0.id) }) { stripped.imageUnavailable = false }
            return stripped
        }
        self.imageHashes = imageHashes
        containers = snapshot.containers
        groups = snapshot.groups
        notesAvailable = snapshot.notesAvailable
    }

    func encoded() throws -> Data {
        let json = try JSONEncoder().encode(self)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) -> AppleSnapshotCache? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data,
            let cache = try? JSONDecoder().decode(AppleSnapshotCache.self, from: json),
            cache.version == currentVersion
        else { return nil }
        return cache
    }
}
