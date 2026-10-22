internal import ArgumentParser

struct RescanCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "rescan",
        abstract: "Forget this Mac's caches so the next sync re-reads every note and all of Contacts.",
        discussion: """
            Clears the file cache, cached image hashes and the Contacts mirror (with its change-history \
            token) in this Mac's state for the vault. Records, merge bases, the review queue and the \
            decision log stay; nothing is written to the notes folder or to Contacts. Run `sync` (or \
            Sync Now in the app) afterwards.
            """)

    @OptionGroup var options: RootOptions

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "rescan").rescan()
    }
}

struct ResetStateCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset-state",
        abstract: "Forget this Mac's sync state for the vault (a backup is saved first).",
        discussion: """
            Copies state.sqlite to backups/state-<time>.sqlite, then forgets this Mac's records \
            (note ↔ contact bindings), merge bases, caches, review queue and groups. Activity history, \
            the decision log and every file in the notes folder stay. The next run is this Mac's first \
            export again (`export --yes`, or Sync Now in the app): it binds notes like a device joining \
            the vault (by sync id stamps when stamp_contacts is on, else by email/phone and name), and \
            anything ambiguous waits for review; nothing is duplicated. Without --yes, only shows what \
            would be reset.
            """)

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Reset (without it, nothing is changed).")
    var yes = false

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "reset-state").resetState(confirmed: yes)
    }
}
