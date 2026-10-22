internal import ArgumentParser
internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import SyncTriggers
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

    @Flag(name: .long, help: "Print one JSON document on stdout instead of lines (errors still go to stderr).")
    var json = false

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
        commandName: "plan",
        abstract: "Dry run: show what `sync` would change on both sides (or, before the first export, what "
            + "`export` would write). Writes no notes and nothing to Contacts.")

    @OptionGroup var options: RootOptions
    @OptionGroup var export: ExportOptionGroup

    @Flag(name: .long, help: "Show the one-way export plan even after the first export.")
    var oneWay = false

    @Option(name: .long, help: "Approve up to N Apple changes (default: limits.max_apple_changes_without_approval).")
    var maxAppleChanges: Int?

    @Flag(name: .long, help: "Read all of Contacts instead of only what the change history reports.")
    var full = false

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        let session = Session(options: options, environment: environment, command: "plan")
        let resolved = oneWay ? nil : try? environment.rootAccess.resolve(options.rootPath)
        let twoWay = resolved.map { session.hasSynced($0.url) } ?? false
        resolved?.close()
        guard twoWay else { return session.export(export.request, write: false, stamp: false, backup: false) }
        return session.sync(
            SyncRequest(
                maxAppleChanges: maxAppleChanges, allowUndownloaded: export.allowUndownloaded,
                appleMode: full ? .full : .incremental),
            write: false)
    }
}

struct SyncCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Run one two-way sync unattended (cron/launchd).",
        discussion: """
            Anything that needs a decision is skipped, queued for the app (or `contacts2md review`), and \
            printed as a WARNING. Apple Contacts is written only when the vault's config has \
            `apple_writes: enabled` (see `contacts2md config`); otherwise Contacts-side changes are \
            reported as `held`. Every run that writes to Contacts saves a vCard backup first.
            """)

    @OptionGroup var options: RootOptions

    @Option(
        name: .long,
        help: "Approve up to N Apple changes this run (default 25: limits.max_apple_changes_without_approval).")
    var maxAppleChanges: Int?

    @Flag(name: .long, help: "Run even if many records vanished at once (deletions are still only queued).")
    var allowMassVanish = false

    @Flag(name: .long, help: "Create new notes even while some notes are iCloud placeholders not downloaded yet.")
    var allowUndownloaded = false

    @Flag(name: .long, help: "Take the sync lease from another device.")
    var takeOver = false

    @Flag(
        name: .long,
        help: "Read all of Contacts (a full snapshot) instead of only what the change history reports.")
    var full = false

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "sync").sync(
            SyncRequest(
                maxAppleChanges: maxAppleChanges, allowMassVanish: allowMassVanish,
                allowUndownloaded: allowUndownloaded, takeOverLease: takeOver,
                policy: environment.trigger == "GUI" ? .gui : .headless, appleMode: full ? .full : .incremental),
            write: true)
    }
}

struct WatchCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Sync live until Ctrl-C (for development and testing; the app does this in the menu bar).",
        discussion: """
            Watches Contacts (CNContactStoreDidChange) and the notes folder (FSEvents), debounces \
            changes, and runs the same sync as `contacts2md sync`: incremental from the Contacts change \
            history for live events, a full compare at start (catch-up), after wake and on the safety \
            sweep. Prints one line per run. Another device's lease or another run on this Mac makes a run \
            a no-op. Never resolves anything needing review.
            """)

    @OptionGroup var options: RootOptions

    @Option(name: .long, help: "Seconds of quiet after the last change before a run.")
    var debounce: Double = 3

    @Option(name: .long, help: "Safety sweep interval in hours (1–6), or `off`.")
    var sweep: String = "2"

    @Flag(name: .long, help: "Do not run a full catch-up sync at start.")
    var noCatchUp = false

    @Option(name: .long, help: "Seconds to wait for another sync on this Mac before skipping a run.")
    var lockWait: Double = 5

    func validate() throws {
        guard debounce >= 0 else { throw ValidationError("--debounce must not be negative") }
        guard sweep.lowercased() == "off" || Double(sweep) != nil else {
            throw ValidationError("--sweep takes hours (1–6) or `off`")
        }
    }

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        let hours = sweep.lowercased() == "off" ? nil : Double(sweep)
        let interval = hours.flatMap { TriggerSettings(sweepInterval: $0 * 3600).sweepInterval }
        return Session(options: options, environment: environment, command: "watch").watch(
            WatchSettings(debounce: debounce, sweepInterval: interval, catchUp: !noCatchUp, lockWait: lockWait))
    }
}

/// `enabled|disabled`, `true|false`, `yes|no`, `on|off`.
struct Switch: ExpressibleByArgument {
    let value: Bool

    init?(argument: String) {
        switch argument.lowercased() {
        case "enabled", "enable", "true", "yes", "on": value = true
        case "disabled", "disable", "false", "no", "off": value = false
        default: return nil
        }
    }
}

/// What `contacts2md lease` does.
enum LeaseAction: String, ExpressibleByArgument, CaseIterable {
    case status
    case takeOver = "take-over"
    case release
}

struct LeaseCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Show, take over or release the vault lease (which device leads syncing).",
        discussion: """
            One device leads: it writes notes and Contacts. Others follow: `sync` there only checks \
            (a dry run) and exits 0; review decisions made there are carried out by the leader. \
            The leader refreshes the lease every 5 minutes; it expires after 20 minutes without a \
            heartbeat. `take-over` makes this Mac the leader at once (it waits about a minute for iCloud \
            when other devices use the vault, then checks it still holds the lease). `release` gives it \
            up so another device can lead.
            """)

    @OptionGroup var options: RootOptions

    @Argument(help: "status | take-over | release")
    var action: LeaseAction = .status

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "lease \(action.rawValue)").lease(action)
    }
}

struct ConfigCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change the vault's sync switches in .c2mdsync/config.yaml.",
        discussion: """
            apple_writes: lets `sync` write to Apple Contacts (default disabled). \
            stamp_contacts: stamps each synced contact with its record id (default false; needed only when \
            several devices sync one vault).
            """)

    @OptionGroup var options: RootOptions

    @Option(name: .long, help: "enabled | disabled")
    var appleWrites: Switch?

    @Option(name: .long, help: "true | false")
    var stampContacts: Switch?

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "config")
            .config(appleWrites: appleWrites, stampContacts: stampContacts)
    }
}

struct ExportCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "One-way export Apple Contacts → markdown.",
        discussion: """
            Without --yes this only prints the plan (same as `plan`). Existing notes are copied to \
            the state folder's backups/ before they are rewritten. With --yes it takes the vault \
            lease like `sync`; while another device leads it prints a note, writes nothing and exits 0.
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

    @Flag(
        name: .long,
        help: "Take the vault lease from another device first (otherwise an export while it leads writes nothing).")
    var takeOver = false

    func validate() throws {
        if stamp && !yes { throw ValidationError("--stamp writes to Contacts and requires --yes") }
        if takeOver && !yes { throw ValidationError("--take-over requires --yes") }
    }

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "export")
            .export(export.request, write: yes, stamp: stamp, backup: backup, takeOver: takeOver)
    }
}

struct ReviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "List items that need a decision, and record decisions.",
        discussion: """
            Items come from the last `plan`, `sync` or `export`. Decisions are appended to \
            .c2mdsync/devices/<device>/decisions.jsonl and take effect on the next run.
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
