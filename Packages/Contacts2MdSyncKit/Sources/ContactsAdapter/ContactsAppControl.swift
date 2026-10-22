#if os(macOS)
    internal import AppKit
    internal import ContactModel
    internal import CoreServices
    public import Foundation
    internal import Synchronization

    /// Sends Apple Events to Contacts.app and asks macOS about Automation
    /// permission. Injected into `ScriptingNotesProvider` so tests never send
    /// a real event.
    public protocol AppleEventSending: Sendable {
        /// Sends `event` and waits for the reply (throws `ContactsScriptingError`).
        func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor

        /// `AEDeterminePermissionToAutomateTarget` for Contacts.app: `0` granted,
        /// `-1743` denied, `-1744` not decided yet, `-600` Contacts.app not
        /// running. With `askUserIfNeeded` macOS shows its prompt (once).
        func permissionStatus(askUserIfNeeded: Bool) -> Int32
    }

    /// Launches and quits Contacts.app. Injected into `ScriptingNotesProvider`.
    public protocol ContactsAppControlling: Sendable {
        /// Contacts.app is running.
        var isRunning: Bool { get }
        /// The user is using Contacts.app: it is visible (not hidden) or frontmost.
        var isInUse: Bool { get }
        /// Every running instance of Contacts.app is hidden.
        var isHidden: Bool { get }
        /// Launches Contacts.app hidden and without activating it, and waits until
        /// it finished launching.
        func launchHidden(timeout: TimeInterval) throws
        /// Hides Contacts.app without activating it (S14: a fresh launch can be
        /// visible for a moment despite `hides`).
        func hide()
        /// Asks Contacts.app to quit.
        func quit()
    }

    /// The real Apple Event sender (`NSAppleEventDescriptor.sendEvent`).
    public struct LiveAppleEventSender: AppleEventSending {
        /// Creates a sender.
        public init() {}

        public func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
            do {
                // Never interact: a sync must not show any UI in Contacts.app (or a
                // consent prompt); permission is asked only by `requestPermission`.
                return try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
            } catch let error as NSError {
                throw ContactsScriptingError(number: error.code, message: error.localizedDescription)
            }
        }

        public func permissionStatus(askUserIfNeeded: Bool) -> Int32 {
            let target = ContactsScriptingEvents.target()
            guard let descriptor = target.aeDesc else { return -50 }  // paramErr
            let wildcard = ContactsScriptingEvents.fourCC("****")  // typeWildCard
            return AEDeterminePermissionToAutomateTarget(descriptor, wildcard, wildcard, askUserIfNeeded)
        }
    }

    /// The real Contacts.app control (`NSWorkspace`, `NSRunningApplication`).
    public struct LiveContactsApp: ContactsAppControlling {
        /// Creates the control.
        public init() {}

        private var instances: [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: ContactsScriptingEvents.bundleID)
                .filter { !$0.isTerminated }
        }

        public var isRunning: Bool { !instances.isEmpty }

        public var isInUse: Bool { instances.contains { !$0.isHidden || $0.isActive } }

        public var isHidden: Bool { instances.allSatisfy(\.isHidden) }

        public func hide() {
            for app in instances where !app.isHidden { _ = app.hide() }
        }

        public func launchHidden(timeout: TimeInterval) throws {
            guard
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ContactsScriptingEvents.bundleID)
            else { throw NotesUnavailableError("Contacts.app not found") }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            let outcome = Mutex<String?>(nil)
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { outcome.withLock { $0 = error.localizedDescription } }
                done.signal()
            }
            guard done.wait(timeout: .now() + timeout) == .success else {
                throw NotesUnavailableError("Contacts.app did not start within \(Int(timeout)) s")
            }
            if let message = outcome.withLock({ $0 }) {
                throw NotesUnavailableError("Contacts.app could not be started: \(message)")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while !instances.contains(where: \.isFinishedLaunching), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        public func quit() {
            for app in instances { app.terminate() }
        }
    }
#endif
