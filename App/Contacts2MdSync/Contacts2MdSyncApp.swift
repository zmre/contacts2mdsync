import SwiftUI

/// The SwiftUI app. Launched from `EntryPoint.main()` when the binary is not
/// invoked as a command-line tool.
struct Contacts2MdSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                    model.isInspectorPresented.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!model.isConfigured)
            }
            CommandMenu("Contacts") {
                Button(model.syncTitle) { Task { await model.syncNow() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isConfigured || model.phase != .idle || !model.setup.isAuthorized)
                Button("Check for Changes") { Task { await model.check() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.isConfigured || model.phase != .idle || !model.setup.isAuthorized)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
