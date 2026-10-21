internal import Contacts
public import Foundation
internal import Synchronization

#if os(macOS)
    internal import AppKit
#endif

/// Holds a notification observer token (opaque, only ever removed).
private struct ObserverToken: @unchecked Sendable {
    let token: any NSObjectProtocol
    let center: NotificationCenter
}

/// `CNContactStoreDidChange` → a live trigger (architecture §10: only a
/// debounced "go look" signal; the change set comes from the history).
///
/// Our own saves post the notification too. The resulting run is cheap:
/// the history excludes our `transactionAuthor`, so nothing is re-read.
public final class ContactsChangeSource: SyncTriggerSource {
    private let center: NotificationCenter
    private let name: Notification.Name
    private let observer = Mutex<ObserverToken?>(nil)
    /// Contacts posts the notification only while a store exists in the process.
    private let store: Mutex<CNContactStore?>

    /// Observes `name` on `center` (defaults: `CNContactStoreDidChange` on the
    /// default center; tests post their own name on a private center).
    public init(center: NotificationCenter = .default, name: Notification.Name? = nil) {
        self.center = center
        self.name = name ?? .CNContactStoreDidChange
        store = Mutex(name == nil ? CNContactStore() : nil)
    }

    public func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            emit(SyncTrigger(.live, reason: "Contacts changed"))
        }
        observer.withLock { $0 = ObserverToken(token: token, center: center) }
    }

    public func stop() {
        let token = observer.withLock { current -> ObserverToken? in
            defer { current = nil }
            return current
        }
        if let token { token.center.removeObserver(token.token) }
        store.withLock { $0 = nil }
    }
}

/// The Mac woke up → a `.wake` catch-up run after `delay` (30 s, so iCloud
/// can deliver queued changes first). Another wake within the delay restarts it.
public final class WakeSource: SyncTriggerSource {
    private let center: NotificationCenter
    private let name: Notification.Name
    private let delay: TimeInterval
    private let clock: any TriggerClock
    private let state = Mutex<(observer: ObserverToken?, pending: Task<Void, Never>?)>((nil, nil))

    /// Observes `name` on `center`. Defaults: `NSWorkspace.didWakeNotification`
    /// on `NSWorkspace.shared.notificationCenter` (macOS).
    public init(
        center: NotificationCenter? = nil, name: Notification.Name? = nil, delay: TimeInterval = 30,
        clock: any TriggerClock = SystemTriggerClock()
    ) {
        #if os(macOS)
            self.center = center ?? NSWorkspace.shared.notificationCenter
            self.name = name ?? NSWorkspace.didWakeNotification
        #else
            self.center = center ?? .default
            self.name = name ?? Notification.Name("C2MDidWake")
        #endif
        self.delay = delay
        self.clock = clock
    }

    public func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) {
        let (delay, clock) = (delay, clock)
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            let deadline = clock.now.addingTimeInterval(delay)
            let task = Task {
                do { try await clock.sleep(until: deadline) } catch { return }
                emit(SyncTrigger(.wake, reason: "woke from sleep"))
            }
            self?.state.withLock { state in
                state.pending?.cancel()
                state.pending = task
            }
        }
        state.withLock { $0.observer = ObserverToken(token: token, center: center) }
    }

    public func stop() {
        let (observer, pending) = state.withLock { state in
            defer { state = (nil, nil) }
            return (state.observer, state.pending)
        }
        pending?.cancel()
        if let observer { observer.center.removeObserver(observer.token) }
    }
}

/// One `.launch` catch-up trigger when started (app start, after the first
/// sync is done: the host starts it only for a vault synced before).
public final class LaunchCatchUp: SyncTriggerSource {
    private let started = Mutex(false)

    /// Creates the source.
    public init() {}

    public func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) {
        let first = started.withLock { started in
            defer { started = true }
            return !started
        }
        if first { emit(SyncTrigger(.launch, reason: "app started")) }
    }

    public func stop() {}
}
