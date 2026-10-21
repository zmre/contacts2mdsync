internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

/// One CLI run: opens the vault and (when needed) Contacts, then reports
/// status, or plans, prints and optionally executes an export.
struct Session {
    let options: CommonOptions
    let environment: CLIEnvironment
    let command: String
    let startedAt: Date

    init(options: CommonOptions, environment: CLIEnvironment, command: String) {
        self.options = options
        self.environment = environment
        self.command = command
        self.startedAt = environment.clock.now
    }

    var report: Reporter {
        Reporter(
            output: environment.output, quiet: options.quiet, verbose: options.verbose,
            timeZone: environment.timeZone)
    }

    /// `--state-dir`, else the environment's per-device state folder.
    var stateDirectory: URL {
        options.stateDir.map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? environment.stateDirectory
    }

    /// The run cannot start (exit 3).
    struct NotRunnable: Error {
        let message: String
    }

    /// Prints the header, runs `body`, and maps errors to exit codes.
    func run(_ body: () throws -> CLIExitCode) -> CLIExitCode {
        report.info("contacts2md \(command)  \(report.timestamp(startedAt))  root=\(options.rootPath)")
        do {
            return try body()
        } catch let error as NotRunnable {
            report.error(error.message)
            return .notRunnable
        } catch ContactStoreError.accessDenied {
            report.error(ContactStoreError.accessDenied.description)
            return .notRunnable
        } catch {
            report.error(String(describing: error))
            return .error
        }
    }

    var elapsed: TimeInterval { environment.clock.now.timeIntervalSince(startedAt) }

    func openVault() throws -> any VaultFS {
        guard environment.isDirectory(options.rootURL) else {
            throw NotRunnable(message: "root \(options.rootPath) is not an existing folder")
        }
        return environment.makeVault(options.rootURL)
    }

    func recordStore(for config: VaultConfig) -> any RecordMapStore {
        JSONRecordMapStore(
            url: stateDirectory.appending(path: config.vaultID.uuidString.lowercased()).appending(path: "records.json"))
    }

    // MARK: - status

    func status() -> CLIExitCode {
        run {
            let fs = try openVault()
            let loaded = try VaultConfig.load(from: fs)
            let index = try VaultIndex.scan(fs, excludedFolders: [loaded?.config.imagesFolder ?? "_images"])
            if let config = loaded?.config {
                let records = try recordStore(for: config).load()
                report.info(
                    "vault    configured  id=\(config.vaultID.uuidString.lowercased())"
                        + "  default_folder=\(config.defaultFolder)  region=\(config.defaultRegion ?? "-")")
                let last = records.lastExport.map(report.timestamp) ?? "never"
                report.info("export   last \(last)  records=\(records.records.count)")
            } else {
                report.info("vault    not configured (run `contacts2md export --yes` once)")
            }
            let needsReview = reportNotes(index)
            let hasAccess = try reportApple()
            report.info("summary  \(String(format: "%.1fs", elapsed))")
            guard hasAccess, loaded != nil else { return .notRunnable }
            return needsReview ? .needsReview : .success
        }
    }

    /// Prints note counts and vault problems; `true` when any need review.
    private func reportNotes(_ index: VaultIndex) -> Bool {
        let contacts = index.contacts
        let linked = contacts.filter { $0.syncID != nil }.count
        report.info(
            "notes    \(contacts.count) contact notes (\(linked) linked, \(contacts.count - linked) markdown-only),"
                + " \(index.entries.count - contacts.count) other notes")
        for (id, paths) in index.duplicateIDs.sorted(by: { $0.value[0] < $1.value[0] }) {
            let list = paths.sorted().joined(separator: ", ")
            report.warning("copied", "\(paths.count) notes share c2mdsync id \(id.uuidString.lowercased()): \(list)")
        }
        for entry in index.problems {
            report.warning("invalid", "\(entry.path): \(entry.problem ?? "unreadable") — never written")
        }
        return !index.duplicateIDs.isEmpty || !index.problems.isEmpty
    }

    /// Prints Contacts access and counts; `false` without access.
    private func reportApple() throws -> Bool {
        do {
            let store = try environment.makeStore()
            let notes = try store.capabilities.notesAvailable ? "available" : "unavailable (no entitlement)"
            let count = try store.snapshot().contacts.count
            report.info("apple    access granted  contacts=\(count)  notes=\(notes)")
            return true
        } catch ContactStoreError.accessDenied {
            report.info("apple    access not granted (open Contacts2MdSync once to allow it)")
            return false
        }
    }
}
