import Contacts2MdCLI
import Testing

@Suite("Launch at login (Settings ▸ General)")
struct UILoginLaunchTests {
    @Test(
        "no window only for a login launch with the setting on and the menu bar shown",
        arguments: [
            (true, true, true, false),
            (false, true, true, true),
            (true, false, true, true),
            (true, true, false, true),
            (false, false, false, true),
        ])
    func window(atLogin: Bool, background: Bool, menuBar: Bool, expected: Bool) {
        #expect(
            UILoginLaunch.opensWindow(launchedAtLogin: atLogin, startInBackground: background, menuBarShown: menuBar)
                == expected)
    }
}
