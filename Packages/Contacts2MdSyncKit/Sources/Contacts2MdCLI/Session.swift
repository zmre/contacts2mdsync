internal import ContactModel
internal import Foundation
internal import SyncEngine
internal import VaultIndex

/// One CLI run: opens the notes folder (and Contacts when needed), then
/// reports status, plans/exports, or records review decisions.
struct Session {
    let options: RootOptions
    let environment: CLIEnvironment
    let command: String
    let startedAt: Date
    /// `--json` collector.
    let json: JSONReport?

    init(options: RootOptions, environment: CLIEnvironment, command: String) {
        var environment = environment
        if let stateDir = options.stateDir {
            environment.stateDirectory = URL(filePath: (stateDir as NSString).expandingTildeInPath)
        }
        self.options = options
        self.environment = environment
        self.command = command
        self.startedAt = environment.clock.now
        self.json = options.json ? JSONReport(command: command, startedAt: environment.clock.now) : nil
    }

    var report: Reporter {
        Reporter(
            output: environment.output, quiet: options.quiet, verbose: options.verbose,
            timeZone: environment.timeZone, json: json)
    }

    /// The run cannot start (exit 3).
    struct NotRunnable: Error {
        let message: String
    }

    /// Opens the root, prints the header, runs `body`, maps errors to exit
    /// codes; with `--json`, prints the collected document last.
    func run(_ body: (ResolvedRoot) throws -> CLIExitCode) -> CLIExitCode {
        let code = runBody(body)
        if let json { environment.output.line(json.render(exitCode: code.rawValue)) }
        return code
    }

    private func runBody(_ body: (ResolvedRoot) throws -> CLIExitCode) -> CLIExitCode {
        let root: ResolvedRoot
        do {
            root = try environment.rootAccess.resolve(options.rootPath)
        } catch {
            report.info("contacts2md \(command)  \(report.timestamp(startedAt))  root=\(options.rootPath ?? "-")")
            report.error(String(describing: error))
            return .notRunnable
        }
        defer { root.close() }
        let device = (try? environment.device())?.name ?? "?"
        let shownRoot = options.rootPath ?? root.path
        json?.header(device: device, root: shownRoot)
        report.info("contacts2md \(command)  \(report.timestamp(startedAt))  device=\(device)  root=\(shownRoot)")
        do {
            guard environment.isDirectory(root.url) else {
                throw NotRunnable(message: "root \(root.path) is not an existing folder (or is not accessible)")
            }
            return try body(root)
        } catch let error as NotRunnable {
            report.error(error.message)
            return .notRunnable
        } catch let error as RootAccessError {
            report.error(error.message)
            return .notRunnable
        } catch let error as VaultNotReady {
            report.error(error.description)
            return .notRunnable
        } catch let error as SyncError {
            report.error(error.description)
            return .breaker
        } catch ContactStoreError.accessDenied {
            report.error(ContactStoreError.accessDenied.description)
            return .notRunnable
        } catch {
            report.error(String(describing: error))
            return .error
        }
    }

    var elapsed: TimeInterval { environment.clock.now.timeIntervalSince(startedAt) }

    /// The vault's config and device state (exit 3 when never exported).
    func configuredState(_ fs: any VaultFS) throws -> (config: VaultConfig, state: any SyncStateStore) {
        guard let config = try VaultConfig.load(from: fs)?.config else {
            throw NotRunnable(
                message: "not configured: run `contacts2md export --yes` (or the app's first export) once")
        }
        let directory = environment.stateDirectory.appending(path: config.vaultID.uuidString.lowercased())
        return (config, try environment.makeStateStore(directory))
    }

    // MARK: - status

    func status() -> CLIExitCode {
        run { root in
            let fs = environment.makeVault(root.url)
            let loaded = try VaultConfig.load(from: fs)
            var pendingCount = 0
            var state: (any SyncStateStore)?
            if let config = loaded?.config {
                let opened = try configuredState(fs).state
                state = opened
                let records = try opened.load()
                report.info(
                    "vault    configured  id=\(config.vaultID.uuidString.lowercased())"
                        + "  default_folder=\(config.defaultFolder)  region=\(config.defaultRegion ?? "-")")
                let last = records.lastExport.map(report.timestamp) ?? "never"
                report.info("export   last \(last)  records=\(records.records.count)")
                let stored = try VaultSession(root: root.url, environment: environment).storedStatus()
                if let stored {
                    report.info(
                        "sync     apple_writes=\(stored.appleWritesEnabled ? "enabled" : "disabled")"
                            + "  stamp_contacts=\(stored.stampContacts)  devices=\(stored.deviceCount)")
                    reportLease(stored)
                    if let warning = stored.identityWarning { report.warning("identity", warning) }
                }
                let pending = try opened.loadPending()
                pendingCount = pending.items.filter(\.item.needsDecision).count
                let asOf = pending.computedAt.map(report.timestamp) ?? "never"
                let breakdown =
                    stored.map {
                        " — \($0.conflicts) conflicts, \($0.pendingDeletes) deletions, \($0.markdownOnly) markdown-only"
                    } ?? ""
                report.info(
                    "review   \(pendingCount) pending (as of \(asOf); `contacts2md review list`)\(breakdown)")
            } else {
                report.info("vault    not configured (run `contacts2md export --yes` or the app's first export)")
            }
            let index = try VaultIndex.scan(
                fs, excludedFolders: [loaded?.config.imagesFolder ?? "_images"],
                excludeGlobs: loaded?.config.excludePaths ?? [], cache: (try? state?.loadFileCache()) ?? [:])
            let needsReview = reportNotes(index)
            let hasAccess = try reportApple()
            if hasAccess {
                reportNotesSetting(
                    VaultSession(root: root.url, environment: environment).notesSourceStatus(), changed: false)
            }
            report.info("summary  \(String(format: "%.1fs", elapsed))")
            guard hasAccess, loaded != nil else { return .notRunnable }
            return needsReview || pendingCount > 0 ? .needsReview : .success
        }
    }

    /// `lease    <holder> until <time>  role=…  heartbeat=…` and one line per other device.
    func reportLease(_ stored: StoredStatus) {
        json?.setting("lease_role", stored.leaseRole.rawValue)
        if let lease = stored.lease {
            let now = environment.clock.now
            let state = lease.releasedAt != nil ? " (released)" : lease.expiresAt < now ? " (expired)" : ""
            let stale = lease.isStale(at: now) ? "  STALE (no heartbeat for over 10 min)" : ""
            report.info(
                "lease    \(lease.deviceName) until \(report.timestamp(lease.expiresAt))\(state)"
                    + "  role=\(stored.leaseRole.rawValue)  heartbeat=\(report.timestamp(lease.heartbeatAt))\(stale)")
        } else {
            report.info("lease    none  role=\(stored.leaseRole.rawValue)")
        }
        let thisDevice = try? environment.device().id
        for device in stored.devices where device.deviceID != thisDevice {
            report.info("device   \(device.deviceName)  last sync \(report.timestamp(device.lastSync))")
        }
    }

    /// Prints note counts and contact-note problems; `true` when any need review.
    private func reportNotes(_ index: VaultIndex) -> Bool {
        let contacts = index.entries.filter(\.isContactNote)
        let linked = contacts.filter { $0.syncID != nil }.count
        let undownloaded = index.undownloaded.count
        report.info(
            "notes    \(contacts.count) contact notes (\(linked) linked, \(contacts.count - linked) markdown-only),"
                + " \(index.entries.count - contacts.count) other notes"
                + (undownloaded > 0 ? ", \(undownloaded) not downloaded from iCloud" : ""))
        for (id, paths) in index.duplicateIDs.sorted(by: { $0.value.sorted()[0] < $1.value.sorted()[0] }) {
            let list = paths.sorted().joined(separator: ", ")
            report.warning("copied", "\(paths.count) notes share c2mdsync id \(id.uuidString.lowercased()): \(list)")
        }
        let contactProblems = index.problems.filter(\.problemIsContactRelated)
        for entry in contactProblems {
            report.warning("invalid", "\(entry.path): \(entry.problem ?? "unreadable") — never written")
        }
        let otherProblems = index.problems.count - contactProblems.count
        if otherProblems > 0 {
            report.info("notes    \(otherProblems) non-contact notes have invalid frontmatter (ignored)")
        }
        return !index.duplicateIDs.isEmpty || !contactProblems.isEmpty
    }

    /// Prints Contacts access and counts; `false` without access.
    private func reportApple() throws -> Bool {
        do {
            let store = try environment.makeStore()
            let notes =
                try store.capabilities.notesAvailable ? "available" : "unavailable (no entitlement; see `notes` below)"
            let snapshot = try store.snapshot()
            let linked = snapshot.contacts.filter { $0.cards.count > 1 }.count
            report.info(
                "apple    access granted  contacts=\(snapshot.contacts.count)  linked=\(linked)"
                    + "  cards=\(snapshot.contacts.reduce(0) { $0 + $1.cards.count })  notes=\(notes)")
            return true
        } catch ContactStoreError.accessDenied {
            report.info("apple    access not granted (open Contacts2MdSync once to allow it)")
            return false
        }
    }
}
