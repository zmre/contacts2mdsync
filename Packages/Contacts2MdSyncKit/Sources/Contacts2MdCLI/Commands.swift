internal import ArgumentParser
internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

/// Options every subcommand takes.
struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: "The notes folder to export into (must exist).")
    var root: String

    @Option(name: .long, help: "Folder (under the root) for new notes. Saved in .mdsync/config.yaml.")
    var defaultFolder: String?

    @Option(name: .long, help: "Region for phone numbers without a country code (e.g. US). Saved in the config.")
    var region: String?

    @Flag(name: .long, help: "Only print warnings and errors.")
    var quiet = false

    @Flag(name: .long, help: "Also list unchanged notes.")
    var verbose = false

    @Option(name: .long, help: ArgumentHelp("Per-device state folder (testing).", visibility: .hidden))
    var stateDir: String?

    /// `--root` with `~` expanded and no trailing slash.
    var rootPath: String { ((root as NSString).expandingTildeInPath as NSString).standardizingPath }

    var rootURL: URL { URL(filePath: rootPath, directoryHint: .isDirectory) }
}

struct StatusCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show vault and Contacts status.")

    @OptionGroup var options: CommonOptions

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "status").status()
    }
}

struct PlanCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "Dry run: show what `export` would write. Writes nothing.")

    @OptionGroup var options: CommonOptions

    @Flag(name: .long, help: "Recreate notes whose file was deleted.")
    var restoreMissing = false

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "plan")
            .export(write: false, stamp: false, restoreMissing: restoreMissing)
    }
}

struct ExportCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "One-way export Apple Contacts → markdown.",
        discussion: "Without --yes this only prints the plan (same as `plan`)."
    )

    @OptionGroup var options: CommonOptions

    @Flag(name: .long, help: "Actually write files. Without it, nothing is written.")
    var yes = false

    @Flag(
        name: .long,
        help: "Also stamp each exported contact's iCloud card with its sync id (writes to Contacts; backs up first).")
    var stamp = false

    @Flag(name: .long, help: "Recreate notes whose file was deleted.")
    var restoreMissing = false

    func validate() throws {
        if stamp && !yes { throw ValidationError("--stamp writes to Contacts and requires --yes") }
    }

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "export")
            .export(write: yes, stamp: stamp, restoreMissing: restoreMissing)
    }
}
