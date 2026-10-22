import AppKit
import Contacts2MdCLI

/// Switches between a regular app and a menu-bar-only accessory
/// (`NSApp.setActivationPolicy`) as windows open and close and as the two
/// General settings change (`UIDockIcon` decides).
@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private var observers: [any NSObjectProtocol] = []

    /// Starts following window changes (once, at launch).
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { DockIconController.shared.update() }
                })
        }
        observers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                let closing = note.object as? NSWindow
                MainActor.assumeIsolated { DockIconController.shared.update(closing: closing) }
            })
        update()
    }

    /// Applies the policy for the windows open now (`closing` is about to go).
    func update(closing: NSWindow? = nil) {
        let open = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.canBecomeMain && window.styleMask.contains(.titled)
        }
        let regular = UIDockIcon.showsDockIcon(
            menuBarShown: AppPreferences.isMenuBarShown, hideWhenClosed: AppPreferences.hidesDockIconWhenClosed,
            windowsOpen: open)
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Coming back from accessory: bring the window that just opened forward.
        if regular, open { NSApp.activate() }
    }
}
