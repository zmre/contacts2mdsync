internal import ContactModel
public import Foundation
public import SyncEngine
public import SyncTriggers

/// Runs coordinator requests through `VaultSession`: the same lock → lease
/// → prepare → execute path as `contacts2md sync` (architecture §15
/// "Shared engine guarantees"), off the caller's thread.
///
/// The app creates one per notes folder, with the folder's security scope
/// open for as long as the runner is used:
///
/// ```swift
/// let ownWrites = OwnWriteRegistry()
/// let runner = VaultSyncRunner(root: url, environment: .live(), ownWrites: ownWrites)
/// let coordinator = SyncCoordinator(runner: runner, settings: TriggerSettingsStore(...).load())
/// ```
public struct VaultSyncRunner: SyncRunner {
    public let root: URL
    public let environment: CLIEnvironment
    /// Fed with every file a run writes, so FSEvents ignores them.
    public let ownWrites: OwnWriteRegistry?
    /// Options for every run (`appleMode` is replaced per request).
    public var options: SyncRequest
    /// How long a run waits for another run on this Mac before reporting
    /// `.localRunInProgress` (the coordinator retries later).
    public var lockWait: TimeInterval

    /// Creates a runner. `policy` is `.gui` for the app and `.headless` for
    /// `contacts2md watch`; it only affects reporting, never what is decided.
    public init(
        root: URL, environment: CLIEnvironment, ownWrites: OwnWriteRegistry?,
        options: SyncRequest = SyncRequest(policy: .gui), lockWait: TimeInterval = 5
    ) {
        self.root = root
        self.environment = environment
        self.ownWrites = ownWrites
        self.options = options
        self.lockWait = lockWait
    }

    public func run(
        _ request: SyncRunRequest, progress: @escaping @Sendable (SyncPhase) -> Void
    ) async -> SyncRunOutcome {
        let runner = self
        return await Task.detached(priority: .utility) { runner.runNow(request, progress: progress) }.value
    }

    public func lastFullCompare() async -> Date? {
        let session = VaultSession(root: root, environment: environment)
        return await Task.detached(priority: .utility) { session.lastFullCompare() }.value
    }

    /// One run, blocking (lock wait, lease settle, Contacts and file I/O).
    public func runNow(_ request: SyncRunRequest, progress: @Sendable (SyncPhase) -> Void) -> SyncRunOutcome {
        var environment = self.environment
        environment.trigger = request.kind.displayName
        environment.lockWait = lockWait
        let session = VaultSession(root: root, environment: environment)
        let startedAt = environment.clock.now
        progress(.waitingForLock)
        do {
            let lock: LocalLock
            switch try session.beginSync(takeOver: false) {
            case .localRunInProgress: return .blocked(.localRunInProgress)
            case .leaseHeldElsewhere(let lease):
                return follow(lease, request: request, session: session, startedAt: startedAt, progress: progress)
            case .ready(let acquired, _): lock = acquired
            }
            defer { lock.release() }
            var syncRequest = options
            syncRequest.appleMode = request.appleMode
            let prepared = try session.prepareSync(syncRequest, progress: progress)
            if let trip = prepared.plan.breaker {
                try session.recordSyncPlan(prepared, command: "sync", startedAt: startedAt)
                return .blocked(.breaker(trip.message))
            }
            progress(.writing)
            let result = try session.executeSync(prepared, command: "sync", startedAt: startedAt)
            ownWrites?.record(result, at: environment.clock.now)
            return .finished(
                Self.summary(
                    request.kind, prepared: prepared, result: result, startedAt: startedAt,
                    finishedAt: environment.clock.now))
        } catch let error as VaultNotReady {
            return .blocked(.notRunnable(error.description))
        } catch let error as RootAccessError {
            return .blocked(.notRunnable(error.message))
        } catch ContactStoreError.accessDenied {
            return .blocked(.notRunnable(ContactStoreError.accessDenied.description))
        } catch let error as SyncError {
            return .blocked(.breaker(error.description))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// The keeper for `SyncCoordinator(…, leaseKeeper:)` (heartbeats, Take
    /// Over, release on shutdown) for this runner's vault.
    public func makeLeaseKeeper() throws -> LeaseKeeper {
        try VaultSession(root: root, environment: environment).makeLeaseKeeper()
    }

    /// Another device leads: a read-only dry run (nothing written to the
    /// vault or Contacts), reported as `.following`, with the failure when
    /// the dry run could not be made (no Contacts access, …).
    private func follow(
        _ lease: VaultLease, request: SyncRunRequest, session: VaultSession, startedAt: Date,
        progress: @Sendable (SyncPhase) -> Void
    ) -> SyncRunOutcome {
        let holder = LeaseHolder(lease, now: environment.clock.now)
        var syncRequest = options
        syncRequest.appleMode = request.appleMode
        do {
            let prepared = try session.followerDryRun(syncRequest, startedAt: startedAt, progress: progress)
            return .following(
                holder,
                .checked(
                    Self.plannedSummary(
                        request.kind, prepared: prepared, startedAt: startedAt, finishedAt: environment.clock.now)))
        } catch {
            return .following(holder, .failed(Self.describe(error)))
        }
    }

    /// The message for a failed follower dry run (the same wording a
    /// blocked run of this device would use).
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as VaultNotReady: error.description
        case let error as RootAccessError: error.message
        case ContactStoreError.accessDenied: ContactStoreError.accessDenied.description
        default: String(describing: error)
        }
    }

    /// What the leader still has to do, as seen by a follower.
    static func plannedSummary(
        _ kind: SyncRunKind, prepared: PreparedSync, startedAt: Date, finishedAt: Date
    ) -> SyncRunSummary {
        let plan = prepared.plan
        var summary = SyncRunSummary(
            kind: kind, startedAt: startedAt, finishedAt: finishedAt, appleFull: prepared.apple.isComplete,
            appleRead: prepared.apple.kind.summary)
        summary.appleCreated = plan.apple.filter { $0.kind == .create }.count
        summary.appleDeleted = plan.apple.filter { $0.kind == .delete }.count
        summary.appleUpdated = plan.apple.count - summary.appleCreated - summary.appleDeleted
        summary.markdownCreated = plan.markdown.creates.count
        summary.markdownUpdated = plan.markdown.updates.count
        summary.markdownTrashed = plan.trash.count
        summary.pendingReview = plan.markdown.reviews.filter(\.needsDecision).count
        summary.conflicts = plan.conflicts.count
        return summary
    }

    static func summary(
        _ kind: SyncRunKind, prepared: PreparedSync, result: SyncResult, startedAt: Date, finishedAt: Date
    ) -> SyncRunSummary {
        let plan = prepared.plan
        var summary = SyncRunSummary(
            kind: kind, startedAt: startedAt, finishedAt: finishedAt, appleFull: prepared.apple.isComplete,
            appleRead: prepared.apple.kind.summary)
        summary.appleCreated = result.apple.filter { $0.kind == .create }.count
        summary.appleDeleted = result.apple.filter { $0.kind == .delete }.count
        summary.appleUpdated = result.apple.count - summary.appleCreated - summary.appleDeleted
        summary.appleHeld = plan.appleHold == nil ? 0 : plan.apple.count
        summary.appleHoldReason = plan.appleHold?.reason
        summary.markdownCreated = result.markdown.created.count
        summary.markdownUpdated = result.markdown.updated.count
        summary.markdownTrashed = result.trashed.count
        summary.pendingReview = plan.markdown.reviews.filter(\.needsDecision).count
        summary.conflicts = plan.conflicts.count
        summary.failures =
            result.markdown.failures.map { "\($0.path): \($0.message)" } + result.appleFailures
        return summary
    }
}
