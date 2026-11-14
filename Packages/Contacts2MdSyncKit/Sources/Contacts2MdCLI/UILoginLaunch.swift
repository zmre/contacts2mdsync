// MARK: - Launch at login (Settings ▸ General)

/// Whether a launch opens the main window. With "Launch at login" and
/// "Start in the background" on, a login launch stays in the menu bar (live
/// sync running, no window). Only with the menu bar icon shown: without it a
/// hidden launch would leave no way back to the app.
public enum UILoginLaunch {
    public static func opensWindow(launchedAtLogin: Bool, startInBackground: Bool, menuBarShown: Bool) -> Bool {
        !(launchedAtLogin && startInBackground && menuBarShown)
    }
}
