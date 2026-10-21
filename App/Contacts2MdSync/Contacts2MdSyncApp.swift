import AppKit
import SwiftUI

/// The SwiftUI app. Launched from `EntryPoint.main()` when the binary is not
/// invoked as a command-line tool.
struct Contacts2MdSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppPreferences.showInMenuBar) private var showInMenuBar = true

    private var model: AppModel { delegate.model }

    var body: some Scene {
        Window("Contacts2MdSync", id: AppPreferences.mainWindowID) {
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
                    .disabled(!model.canSync)
                Button("Check for Changes") { Task { await model.check() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canSync)
            }
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the model (so it outlives the main window), starts it at launch,
/// keeps running in the menu bar, and stops live sync before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.launch() }
    }

    /// With the menu bar extra shown, closing the window keeps the app (and live sync) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppPreferences.isMenuBarShown
    }

    /// Waits for a sync in progress (bounded) and closes the folder before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.live.isHosting else { return .terminateNow }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// App-level preferences (UserDefaults; per Mac).
enum AppPreferences {
    /// Settings ▸ General ▸ Show in menu bar (default on).
    static let showInMenuBar = "showInMenuBar"
    static let mainWindowID = "main"

    static var isMenuBarShown: Bool {
        UserDefaults.standard.object(forKey: showInMenuBar) as? Bool ?? true
    }
}
