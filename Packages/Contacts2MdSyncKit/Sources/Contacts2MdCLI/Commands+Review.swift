internal import ArgumentParser
internal import SyncEngine

/// `review decide <item> <choice>` or `review decide <item> --group … --exclude …`.
struct ReviewDecideCommand: ParsableCommand, EnvironmentCommand {
    static let configuration = CommandConfiguration(
        commandName: "decide",
        abstract: "Record a decision for one review item.",
        discussion: """
            Choices: duplicates → distinct | only:N (sync only member N), or a partition with \
            --group/--exclude; possible matches → adopt | distinct | ignore; copied notes → keep:N; \
            conflicts → apple | markdown | both; deleted in Contacts → trash | keep | restore; note deleted → \
            restore | unlink | delete-contact; markdown-only notes → add | ignore.

            Duplicates partition: member numbers as `review list` shows them. Each --group is one person \
            (one note); different groups are different people; --exclude members are not synced. Every \
            member needs a group or --exclude, e.g. `review decide dup-1a2b3c4d5e --group 1,2 --group 3 \
            --exclude 4`.
            """)

    @OptionGroup var options: RootOptions

    @Argument(help: "The item id from `review list` (e.g. dup-1a2b3c4d5e).")
    var itemID: String

    @Argument(help: "The choice (see `review list`); omit with --group / --exclude.")
    var choice: String?

    @Option(name: .long, help: "Duplicates: members (e.g. 1,2) that are one person. Repeat for each person.")
    var group: [String] = []

    @Option(name: .long, help: "Duplicates: members (e.g. 3,4) not to sync.")
    var exclude: [String] = []

    func validate() throws {
        let partitioned = !group.isEmpty || !exclude.isEmpty
        if partitioned, choice != nil {
            throw ValidationError("give either a choice or --group/--exclude, not both")
        }
        if !partitioned, choice == nil { throw ValidationError("missing a choice (or --group/--exclude)") }
        guard partitioned else { return }
        for list in group + exclude where Self.members(list) == nil {
            throw ValidationError("\"\(list)\" is not a list of member numbers (e.g. 1,2)")
        }
    }

    /// `1,2` → [0, 1]; `nil` when malformed.
    static func members(_ list: String) -> [Int]? {
        let values = list.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy({ ($0 ?? 0) >= 1 }) else { return nil }
        return values.compactMap { $0.map { $0 - 1 } }
    }

    /// The choice string: the positional choice, or `resolve:…` from the options.
    var resolvedChoice: String {
        if let choice { return choice }
        let partition = ClusterPartition(
            groups: group.map { Self.members($0) ?? [] }, excluded: exclude.flatMap { Self.members($0) ?? [] })
        return partition.choice
    }

    func run(in environment: CLIEnvironment) -> CLIExitCode {
        Session(options: options, environment: environment, command: "review decide")
            .reviewDecide(itemID: itemID, choice: resolvedChoice)
    }
}
