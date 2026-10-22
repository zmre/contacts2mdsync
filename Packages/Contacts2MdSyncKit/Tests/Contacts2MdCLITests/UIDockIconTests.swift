import Contacts2MdCLI
import Testing

@Suite("Dock icon (Settings ▸ General)")
struct UIDockIconTests {
    @Test(
        "accessory only with the menu bar shown, the setting on and no window open",
        arguments: [
            (true, true, false, false),
            (true, true, true, true),
            (true, false, false, true),
            (false, true, false, true),
            (false, false, false, true),
        ])
    func policy(menuBar: Bool, hide: Bool, windows: Bool, expected: Bool) {
        #expect(UIDockIcon.showsDockIcon(menuBarShown: menuBar, hideWhenClosed: hide, windowsOpen: windows) == expected)
    }
}
