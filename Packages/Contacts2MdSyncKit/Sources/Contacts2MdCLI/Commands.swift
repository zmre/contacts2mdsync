internal import ArgumentParser
internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

/// The folder and output options every subcommand takes.
struct RootOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "The notes folder (must exist). Default: the folder chosen in the Contacts2MdSync app.")
    var root: String?

    @Flag(name: .long, help: "Only print warnings and errors.")
    var quiet = false

    @Flag(name: .long, help: "Also list unchanged notes and informational lines.")
    var verbose = false

    @Option(name: .long, help: ArgumentHelp("Per-device state folder (testing).", visibility: .hidden))
    var stateDir: String?

    /// `--root` with `~` expanded and no trailing slash.
    var rootPath: String? {
        root.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
    }
}

/// Options for commands that plan an export.
struct ExportOptionGroup: ParsableArguments {
    @Option(name: .long, help: "Folder (under the root) for new notes. Saved in .c2mdsync/config.yaml.")
    var defaultFolder: String?

    @Option(name: .long, help: "Region for phone numbers without a country code (e.g. US). Saved in the config.")
    var region: String?

    @Flag(name: .long, help: "Recreate notes whose file was deleted.")
    var restoreMissing = false

    @Option(
        name: .long,
        help: """
            When to adopt existing notes that match a contact by email/phone and name with no ambiguity: \
            first-import (default), always, never.
            """)
    var autoAdopt: AdoptOption = .firstImport

    @Flag(
        name: .long,
        help: "Create new notes even while some notes are iCloud placeholders that are not downloaded yet.")
    var allowUndownloaded = false

    var request: ExportRequest {
        ExportRequest(
            defaultFolder: defaultFolder, region: region, restoreMissing: restoreMissing, autoAdopt: autoAdopt.value,
            allowUndownloaded: allowUndownloaded)
    }
}

/// `--auto-adopt` values (`AutoAdopt` lives in SyncEngine, which does not
/// depend on ArgumentParser).
enum AdoptOption: String, ExpressibleByArgument, CaseIterable {
    case firstImport = "first-import"
    case always
    case never

    var value: AutoAdopt {
        switch self {
        case .firstImport: .firstImport
        case .always: .always
        case .never: .never
        }
    }
}

struct StatusCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show vault, Contacts and review status. Writes nothing.")

    @OptionGroup var options: RootOptions

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "status").status()
    }
}

struct PlanCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "Dry run: show what `export` would write. Writes no notes.")

    @OptionGroup var options: RootOptions
    @OptionGroup var export: ExportOptionGroup

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "plan")
            .export(export.request, write: false, stamp: false, backup: false)
    }
}

struct ExportCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "One-way export Apple Contacts → markdown.",
        discussion: """
            Without --yes this only prints the plan (same as `plan`). Existing notes are copied to \
            the state folder's backups/ before they are rewritten.
            """
    )

    @OptionGroup var options: RootOptions
    @OptionGroup var export: ExportOptionGroup

    @Flag(name: .long, help: "Actually write files. Without it, nothing is written.")
    var yes = false

    @Flag(name: .long, help: "Also save a vCard backup of all contacts first (always done with --stamp).")
    var backup = false

    @Flag(
        name: .long,
        help: "Also stamp each exported contact's iCloud card with its sync id (writes to Contacts; backs up first).")
    var stamp = false

    func validate() throws {
        if stamp && !yes { throw ValidationError("--stamp writes to Contacts and requires --yes") }
    }

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "export")
            .export(export.request, write: yes, stamp: stamp, backup: backup)
    }
}

struct ReviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "List items that need a decision, and record decisions (until the app's review screens exist).",
        discussion: """
            Items come from the last `plan` or `export`. Decisions are appended to \
            .c2mdsync/devices/<device>/decisions.jsonl and take effect on the next plan or export.
            """,
        subcommands: [ReviewListCommand.self, ReviewDecideCommand.self, ReviewAdoptAllCommand.self],
        defaultSubcommand: ReviewListCommand.self
    )
}

struct ReviewListCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List pending review items with their ids and choices.")

    @OptionGroup var options: RootOptions

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "review list").reviewList()
    }
}

struct ReviewDecideCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "decide",
        abstract: "Record a decision for one review item.",
        discussion: """
            Choices: duplicates → distinct | only:N (sync only member N); possible matches → \
            adopt | distinct | ignore; copied notes → keep:N.
            """)

    @OptionGroup var options: RootOptions

    @Argument(help: "The item id from `review list` (e.g. dup-1a2b3c4d5e).")
    var itemID: String

    @Argument(help: "The choice (see `review list`).")
    var choice: String

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "review decide")
            .reviewDecide(itemID: itemID, choice: choice)
    }
}

struct ReviewAdoptAllCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt-all",
        abstract: "Adopt every pending possible match (one contact ↔ one note) at or above a confidence.")

    @OptionGroup var options: RootOptions

    @Option(name: .long, help: "Minimum confidence (0.3 name only, 0.5 name+company, 0.7 email/phone, 0.9 both).")
    var minConfidence: Double = 0.3

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "review adopt-all")
            .reviewAdoptAll(minConfidence: minConfidence)
    }
}
