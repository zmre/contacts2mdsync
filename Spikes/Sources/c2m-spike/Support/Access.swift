import Contacts
import Foundation

enum Access {
    /// Human-readable authorization status. Mapped by raw value so `.limited`
    /// (iOS-only API surface) doesn't need availability gymnastics.
    static func statusName(_ status: CNAuthorizationStatus) -> String {
        switch status.rawValue {
        case 0: return "notDetermined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"
        case 4: return "limited"
        default: return "unknown(\(status.rawValue))"
        }
    }

    static var currentStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Returns a store with Contacts access, prompting once if undetermined.
    /// Run from Terminal: TCC attributes the prompt/grant to Terminal.
    static func authorizedStore() throws -> CNContactStore {
        let store = CNContactStore()
        let status = currentStatus
        switch status.rawValue {
        case 3:
            return store
        case 0:
            stderrLine("Contacts access not determined; requesting (a TCC prompt should appear)...")
            let granted = requestBlocking(store)
            if granted { return store }
            throw SpikeError(deniedHelp(status: "denied after prompt"), exitCode: 3)
        default:
            throw SpikeError(deniedHelp(status: statusName(status)), exitCode: 3)
        }
    }

    /// Blocks until the async request finishes. The completion handler runs
    /// on a private queue, so a semaphore on the main thread is safe.
    static func requestBlocking(_ store: CNContactStore) -> Bool {
        final class Box: @unchecked Sendable { var granted = false }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        store.requestAccess(for: .contacts) { granted, error in
            box.granted = granted
            if let error { stderrLine("requestAccess error: \(describe(error))") }
            semaphore.signal()
        }
        semaphore.wait()
        return box.granted
    }

    private static func deniedHelp(status: String) -> String {
        """
        No Contacts access (status: \(status)).
        Grant it in System Settings > Privacy & Security > Contacts for the app that launched this
        binary (usually Terminal / iTerm / Ghostty), then re-run. For a reset: `tccutil reset AddressBook`.
        """
    }
}

func stderrLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
