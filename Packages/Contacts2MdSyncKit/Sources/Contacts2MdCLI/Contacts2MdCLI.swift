internal import ArgumentParser
internal import Foundation

/// Exit codes (architecture §15).
public enum CLIExitCode: Int32, Sendable {
    /// Done; nothing needs review.
    case success = 0
    /// Done; some items were skipped and need review.
    case needsReview = 1
    /// Partial: change limit held back Apple writes (M3).
    case partial = 2
    /// Not runnable: no Contacts access, root missing, not configured.
    case notRunnable = 3
    /// A safety breaker tripped; nothing written (M3).
    case breaker = 4
    /// Unexpected error.
    case error = 5
    /// Bad command line (ArgumentParser's `EX_USAGE`).
    case usage = 64
}

/// The `contacts2md` command line, as a library so both the dev executable
/// (`contacts2md`) and the app binary (`Contacts2MdSync <subcommand>`) run it.
public enum Contacts2MdCLI {
    /// First arguments that select the CLI in the app binary.
    public static let subcommandNames: Set<String> = ["status", "plan", "export", "review", "help"]

    /// `true` when `arguments` (without the executable path) ask for the CLI.
    /// Unknown flags such as `-NSDocumentRevisionsDebugMode` (Xcode) do not.
    public static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return subcommandNames.contains(first) || first == "--help" || first == "-h"
    }

    /// Runs the CLI with `arguments` (without the executable path).
    public static func run(_ arguments: [String], environment: CLIEnvironment = .live()) -> Int32 {
        do {
            let command = try RootCommand.parseAsRoot(arguments)
            guard let runnable = command as? any EnvironmentCommand else {
                environment.output.line(RootCommand.helpMessage())
                return CLIExitCode.success.rawValue
            }
            return runnable.run(in: environment).rawValue
        } catch {
            let message = RootCommand.fullMessage(for: error)
            let code = RootCommand.exitCode(for: error)
            if code == .success {
                environment.output.line(message)
                return CLIExitCode.success.rawValue
            }
            environment.output.error(message)
            return code == .validationFailure ? CLIExitCode.usage.rawValue : code.rawValue
        }
    }

    /// Runs with the process arguments and exits.
    public static func main() -> Never {
        exit(run(Array(CommandLine.arguments.dropFirst())))
    }
}

/// A subcommand that runs against an injected environment.
protocol EnvironmentCommand {
    func run(in environment: CLIEnvironment) -> CLIExitCode
}

struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts2md",
        abstract: "Export Apple Contacts to mbr-format markdown notes.",
        discussion: """
            Without --root, the notes folder chosen in the Contacts2MdSync app is used.
            Warnings go to stdout with stable prefixes; errors go to stderr.
            Exit codes: 0 ok, 1 review needed, 3 not runnable, 5 error, 64 usage.
            """,
        subcommands: [StatusCommand.self, PlanCommand.self, ExportCommand.self, ReviewCommand.self]
    )
}
