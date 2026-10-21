import SwiftUI

/// The SwiftUI app. Launched from `EntryPoint.main()` when the binary is not
/// invoked as a command-line tool.
struct Contacts2MdSyncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Placeholder preferences window (notes folder, sync options) until M1.
struct SettingsView: View {
    var body: some View {
        Form {
            ContentUnavailableView(
                "No Settings Yet",
                systemImage: "gearshape",
                description: Text("Notes folder and sync options will appear here.")
            )
        }
        .frame(width: 420, height: 240)
        .padding()
    }
}
