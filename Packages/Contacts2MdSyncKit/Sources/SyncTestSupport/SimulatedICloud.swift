public import ContactModel
public import Foundation
internal import Synchronization
internal import VaultIndex

/// iCloud Drive for several devices sharing one vault (architecture §14
/// "Multi-device simulation"): each device has its own `InMemoryVault`
/// replica; a local change reaches the cloud and every other replica
/// `delay` seconds later (`propagate()`, on the shared `TestClock`).
///
/// Two devices changing the same file before seeing each other's change is
/// a conflict, resolved like iCloud: the change that arrives last becomes
/// the current contents everywhere, and the other is kept either as an
/// unresolved conflict version (`.versions`, `NSFileVersion`) or as a
/// conflicted copy next to it (`.duplicateFiles`, `Name 2.md`). Identical
/// bytes never conflict. `conflicts` counts them, so tests can assert that
/// syncing from several devices causes no conflicted-copy churn.
public final class SimulatedICloud: Sendable {
    /// How a conflict's losing side survives.
    public enum ConflictStyle: Sendable {
        /// An unresolved `NSFileVersion` of the file.
        case versions
        /// A sibling file `<stem> 2.<ext>`.
        case duplicateFiles
    }

    /// A conflict the simulated cloud recorded.
    public struct Conflict: Hashable, Sendable {
        public var path: String
        /// Where the losing contents went (the path itself for `.versions`).
        public var loserPath: String
    }

    private struct Upload {
        var origin: Int
        var change: VaultFileChange
        /// The server version the origin had seen when it made the change.
        var base: Int
        var due: Date
        var sequence: Int
    }

    private struct State {
        var server: [String: (data: Data?, version: Int)] = [:]
        var known: [[String: Int]]
        var pending: [Upload] = []
        var sequence = 0
        var conflicts: [Conflict] = []
    }

    public let clock: TestClock
    public let delay: TimeInterval
    public let style: ConflictStyle
    /// One vault per device.
    public let replicas: [InMemoryVault]
    private let state: Mutex<State>

    /// `devices` replicas of an empty vault.
    public init(devices: Int = 2, clock: TestClock, delay: TimeInterval = 30, style: ConflictStyle = .versions) {
        self.clock = clock
        self.delay = delay
        self.style = style
        let versions = ConflictVersionStore()
        replicas = (0..<devices).map { _ in InMemoryVault(conflictVersions: versions) }
        state = Mutex(State(known: Array(repeating: [:], count: devices)))
        for (index, replica) in replicas.enumerated() {
            replica.observeChanges { [weak self] change in self?.record(change, from: index) }
        }
    }

    /// The replica of device `index`.
    public func vault(_ index: Int) -> InMemoryVault { replicas[index] }

    /// Conflicts so far.
    public var conflicts: [Conflict] { state.withLock { $0.conflicts } }

    /// Local changes not yet delivered.
    public var pendingCount: Int { state.withLock { $0.pending.count } }

    /// Delivers every change whose delay has passed, in arrival order.
    public func propagate() {
        while let upload = nextDue(clock.now) { deliver(upload) }
    }

    /// Delivers everything at once (moves no clock: as if iCloud caught up).
    public func flush() {
        while let upload = nextDue(.distantFuture) { deliver(upload) }
    }

    private func record(_ change: VaultFileChange, from origin: Int) {
        let now = clock.now
        state.withLock { state in
            state.sequence += 1
            state.pending.append(
                Upload(
                    origin: origin, change: change, base: state.known[origin][change.path] ?? 0,
                    due: now.addingTimeInterval(delay), sequence: state.sequence))
        }
    }

    private func nextDue(_ now: Date) -> Upload? {
        state.withLock { state in
            guard
                let index = state.pending.indices.filter({ state.pending[$0].due <= now }).min(by: {
                    (state.pending[$0].due, state.pending[$0].sequence)
                        < (state.pending[$1].due, state.pending[$1].sequence)
                })
            else { return nil }
            return state.pending.remove(at: index)
        }
    }

    private enum Delivery {
        case nothing
        /// A delete lost to an edit: the edit comes back on the deleting device.
        case restoreOrigin(Data)
        /// Applied to `targets`; `loser` (if any) lost a conflict.
        case applied(targets: [Int], loser: Data?)
    }

    /// Applies one upload to the server and the other replicas.
    private func deliver(_ upload: Upload) {
        let path = upload.change.path
        let delivery = state.withLock { state -> Delivery in
            let server = state.server[path] ?? (nil, 0)
            let stale = upload.base != server.version
            if stale, let early = Self.staleOutcome(upload, server: server.data) {
                state.known[upload.origin][path] = server.version
                return early
            }
            let loser = stale ? server.data : nil
            let version = server.version + 1
            state.server[path] = (upload.change.data, version)
            let targets = Self.accept(upload, version: version, replicas: replicas.count, state: &state)
            if loser != nil, upload.change.data != nil {
                state.conflicts.append(Conflict(path: path, loserPath: loserPath(path)))
            }
            return .applied(targets: targets, loser: upload.change.data == nil ? nil : loser)
        }
        switch delivery {
        case .nothing:
            return
        case .restoreOrigin(let kept):
            replicas[upload.origin].applyRemote(VaultFileChange(path: path, data: kept))
        case .applied(let targets, let loser):
            for index in targets { replicas[index].applyRemote(upload.change) }
            guard let loser else { return }
            keepLoser(loser, of: path)
        }
    }

    /// Records `version` as seen by the origin and by every replica without
    /// its own pending change to the file; returns the replicas to update.
    private static func accept(_ upload: Upload, version: Int, replicas: Int, state: inout State) -> [Int] {
        let path = upload.change.path
        var targets: [Int] = []
        for index in 0..<replicas {
            let hasLocalChange = state.pending.contains { $0.origin == index && $0.change.path == path }
            guard index == upload.origin || !hasLocalChange else { continue }
            state.known[index][path] = version
            if index != upload.origin { targets.append(index) }
        }
        // The origin's later changes to this file were made on top of this one.
        for index in state.pending.indices
        where state.pending[index].origin == upload.origin && state.pending[index].change.path == path {
            state.pending[index].base = version
        }
        return targets
    }

    /// A change made without seeing the server's current contents: nothing
    /// to do when both are the same, and a delete never beats an edit.
    private static func staleOutcome(_ upload: Upload, server: Data?) -> Delivery? {
        if server == upload.change.data { return .nothing }
        if upload.change.data == nil, let kept = server { return .restoreOrigin(kept) }
        return nil
    }

    private func keepLoser(_ loser: Data, of path: String) {
        switch style {
        case .versions:
            replicas[0].conflictVersions.add(path, FileConflictVersion(data: loser, deviceName: "another Mac"))
        case .duplicateFiles:
            let copy = VaultFileChange(path: loserPath(path), data: loser)
            state.withLock { state in
                let version = (state.server[copy.path]?.version ?? 0) + 1
                state.server[copy.path] = (loser, version)
                for index in replicas.indices { state.known[index][copy.path] = version }
            }
            for replica in replicas { replica.applyRemote(copy) }
        }
    }

    private func loserPath(_ path: String) -> String {
        guard style == .duplicateFiles else { return path }
        let folder = VaultPath.directory(of: path)
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let ext = name.contains(".") ? "." + (name.split(separator: ".").last.map(String.init) ?? "") : ""
        return VaultPath.join(folder, VaultPath.stem(of: path) + " 2" + ext)
    }
}

/// Apple Contacts on several devices (architecture §14): each device has
/// its own `FakeContactStore`; a contact changed on one device (by sync or
/// by the user) reaches the others `delay` seconds later (`propagate()`),
/// whole contact by whole contact, the later change winning, like iCloud
/// contacts sync. Replicas receive changes as `replaceContacts`, which
/// also resets their change history (the next read is a full snapshot).
public final class SimulatedContactsCloud: Sendable {
    private struct Change {
        var origin: Int
        var unifiedID: String
        var contact: AppleContact?
        var due: Date
        var sequence: Int
    }

    private struct State {
        /// What each replica last agreed with the cloud on, by unified id.
        var known: [[String: AppleContact]]
        var pending: [Change] = []
        var sequence = 0
    }

    public let clock: TestClock
    public let delay: TimeInterval
    /// One store per device.
    public let stores: [FakeContactStore]
    private let state: Mutex<State>

    /// `devices` replicas of `contacts`.
    public init(
        contacts: [AppleContact], devices: Int = 2, clock: TestClock, delay: TimeInterval = 60,
        containers: [AppleContainer] = Fixtures.containers, groups: [AppleGroup] = Fixtures.groups
    ) {
        self.clock = clock
        self.delay = delay
        stores = (0..<devices).map { _ in
            FakeContactStore(contacts: contacts, containers: containers, groups: groups, notesEntitled: true)
        }
        let known = Dictionary(contacts.map { ($0.unifiedID, $0) }, uniquingKeysWith: { first, _ in first })
        state = Mutex(State(known: Array(repeating: known, count: devices)))
    }

    /// The store of device `index`.
    public func store(_ index: Int) -> FakeContactStore { stores[index] }

    /// Picks up local changes on every replica and delivers those whose
    /// delay has passed.
    public func propagate() {
        detect()
        let now = clock.now
        let due = state.withLock { state -> [Change] in
            let ready = state.pending.filter { $0.due <= now }.sorted { ($0.due, $0.sequence) < ($1.due, $1.sequence) }
            state.pending.removeAll { $0.due <= now }
            return ready
        }
        for change in due { deliver(change) }
    }

    /// Delivers everything at once.
    public func flush() {
        detect()
        let all = state.withLock { state -> [Change] in
            defer { state.pending = [] }
            return state.pending.sorted { $0.sequence < $1.sequence }
        }
        for change in all { deliver(change) }
    }

    private func detect() {
        let now = clock.now
        let currents = stores.map { store in
            Dictionary(store.contacts.map { ($0.unifiedID, $0) }, uniquingKeysWith: { first, _ in first })
        }
        state.withLock { state in
            for (index, current) in currents.enumerated() {
                for id in Set(current.keys).union(state.known[index].keys).sorted()
                where current[id] != state.known[index][id] {
                    state.sequence += 1
                    state.pending.append(
                        Change(
                            origin: index, unifiedID: id, contact: current[id], due: now.addingTimeInterval(delay),
                            sequence: state.sequence))
                    state.known[index][id] = current[id]
                }
            }
        }
    }

    private func deliver(_ change: Change) {
        for (index, store) in stores.enumerated() where index != change.origin {
            var contacts = store.contacts.filter { $0.unifiedID != change.unifiedID }
            if let contact = change.contact { contacts.append(contact) }
            contacts.sort { $0.unifiedID < $1.unifiedID }
            guard contacts != store.contacts.sorted(by: { $0.unifiedID < $1.unifiedID }) else { continue }
            store.replaceContacts(contacts)
            state.withLock { $0.known[index][change.unifiedID] = change.contact }
        }
    }
}
