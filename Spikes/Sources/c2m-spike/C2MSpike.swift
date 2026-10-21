import ArgumentParser
import Foundation

@main
struct C2MSpike: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "c2m-spike",
        abstract: "Spike harness for Contacts2MdSync (docs/spikes.md). Run from Terminal.",
        discussion: """
            SAFETY: write subcommands only touch scratch cards this tool created: name starts with \
            "ZZ Spike " AND a URL value starts with "x-c2mdsync-spike:" (or the legacy "x-mdsync-spike:"). \
            Writes print a plan and need --yes.

            Results land in Spikes/results (override with C2M_SPIKE_RESULTS). See Spikes/README.md.
            """,
        subcommands: [
            Inventory.self,
            S1Stamp.self,
            S3History.self,
            S4Unified.self,
            S5Normalize.self,
            S9IDs.self,
            S11Headless.self,
            Cleanup.self,
        ]
    )
}

/// Wraps a command body so SpikeError exit codes propagate.
func runReporting(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as SpikeError {
        stderrLine("error: \(error.message)")
        throw ExitCode(error.exitCode)
    }
}
