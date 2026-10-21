import ArgumentParser
import Contacts
import Foundation

/// Which account a scratch card targets.
enum AccountKind: String, ExpressibleByArgument, CaseIterable, Codable, Sendable {
    case icloud
    case google
}

extension CNContainerType {
    var name: String {
        switch self {
        case .unassigned: return "unassigned"
        case .local: return "local"
        case .exchange: return "exchange"
        case .cardDAV: return "cardDAV"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

/// Container names are usually "iCloud", "Google", "Card"… but Google accounts
/// can be named after the email address. Never print something that looks
/// like an address.
func redactedContainerName(_ name: String) -> String {
    name.contains("@") ? "<email-like name redacted>" : name
}

/// Guesses the account kind of a container from its name. iCloud and Google
/// are both `.cardDAV`, so the type alone can't tell them apart.
func guessKind(_ container: CNContainer) -> AccountKind? {
    let lower = container.name.lowercased()
    if lower.contains("icloud") { return .icloud }
    if lower.contains("google") || lower.contains("gmail") { return .google }
    return nil
}

/// Shared options so the user can override the name heuristic with the
/// identifiers that `inventory` prints.
struct ContainerOptions: ParsableArguments {
    @Option(help: "Container identifier to treat as iCloud (see `inventory`).")
    var icloudContainer: String?

    @Option(help: "Container identifier to treat as Google (see `inventory`).")
    var googleContainer: String?

    func override(for kind: AccountKind) -> String? {
        switch kind {
        case .icloud: return icloudContainer
        case .google: return googleContainer
        }
    }

    func resolve(_ kind: AccountKind, in store: CNContactStore) throws -> CNContainer {
        let all = try store.containers(matching: nil)
        if let id = override(for: kind) {
            guard let match = all.first(where: { $0.identifier == id }) else {
                throw SpikeError("No container with identifier \(id). Run `c2m-spike inventory` to list them.")
            }
            return match
        }
        let matches = all.filter { guessKind($0) == kind }
        guard matches.count == 1, let only = matches.first else {
            let listing = all.map { "  \($0.identifier)  type=\($0.type.name)  name=\(redactedContainerName($0.name))" }
            throw SpikeError(
                """
                Could not pick a unique \(kind.rawValue) container by name (\(matches.count) candidates).
                Pass --\(kind.rawValue)-container <identifier>. Containers:
                \(listing.joined(separator: "\n"))
                """)
        }
        return only
    }

    /// Kind of the container holding `contactID`, via override ids or name heuristic.
    func kind(ofContainer container: CNContainer) -> AccountKind? {
        if container.identifier == icloudContainer { return .icloud }
        if container.identifier == googleContainer { return .google }
        return guessKind(container)
    }
}

extension CNContactStore {
    func container(ofContact id: String) throws -> CNContainer? {
        try containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: id)).first
    }
}
