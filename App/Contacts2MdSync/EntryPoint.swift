import Contacts2MdCLI
import Foundation

/// Process entry point.
///
/// The app binary doubles as the `contacts2md` command line (architecture
/// §15): Contacts permission and the sandboxed folder bookmark belong to the
/// app's code identity, so headless runs must use this same executable.
/// When the first argument is a known subcommand (`status`, `plan`, `export`,
/// `help`), the CLI runs and the process exits without ever creating an
/// `NSApplication`. Anything else (including Xcode's `-NS…` launch arguments)
/// starts the SwiftUI app.
@main
enum EntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if Contacts2MdCLI.isCLIInvocation(arguments) {
            exit(Contacts2MdCLI.run(arguments))
        }
        Contacts2MdSyncApp.main()
    }
}
