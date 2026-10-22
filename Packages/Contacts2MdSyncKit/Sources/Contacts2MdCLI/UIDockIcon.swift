// MARK: - Dock icon (Settings ▸ General)

/// Whether the app shows a Dock icon: with the menu bar icon shown and
/// "Hide Dock icon when the window is closed" on, the app runs as an
/// accessory (menu bar only) while no window is open, and as a regular app
/// while one is. Without the menu bar icon the Dock icon always stays (it
/// would be the only way back to the app).
public enum UIDockIcon {
    /// `true`: regular app (Dock icon, ⌘-Tab); `false`: accessory.
    public static func showsDockIcon(menuBarShown: Bool, hideWhenClosed: Bool, windowsOpen: Bool) -> Bool {
        windowsOpen || !menuBarShown || !hideWhenClosed
    }
}
