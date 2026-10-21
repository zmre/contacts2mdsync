public import Foundation
internal import Synchronization
internal import VaultIndex

#if os(macOS)
    internal import CoreServices
#endif

/// One file-system event (absolute path + `FSEventStreamEventFlags`).
public struct VaultFSEvent: Hashable, Sendable {
    public var path: String
    public var flags: UInt32

    /// Creates an event.
    public init(path: String, flags: UInt32 = 0) {
        self.path = path
        self.flags = flags
    }

    /// `MustScanSubDirs`, `UserDropped`, `KernelDropped`, `RootChanged`: events were lost.
    public static let rescanFlags: UInt32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0004 | 0x0000_0020
}

/// Decides what a batch of FSEvents means (pure; the FSEvents plumbing is
/// in `VaultChangeSource`).
///
/// - A drop flag (`MustScanSubDirs`, `UserDropped`, `KernelDropped`, or the
///   root itself changed) → `.rescanVault`: events were lost.
/// - Events outside the root, under `.c2mdsync/` (lease, device records,
///   decision logs, config), or in dot files and folders (our temp files,
///   `.DS_Store`, `.obsidian`, …: the vault scan skips them) are ignored.
/// - A file we just wrote, still holding the bytes we wrote, is ignored
///   (`OwnWriteRegistry`).
/// - Anything else → `.live`.
public struct VaultEventFilter: Sendable {
    /// The root, resolved (`/private/var/…`, no trailing slash).
    public let root: String
    public let ownWrites: OwnWriteRegistry?
    /// sha256 of the file at a root-relative path; `nil` when it is missing.
    public let hash: @Sendable (String) -> String?

    /// Creates a filter for `root`.
    public init(
        root: URL, ownWrites: OwnWriteRegistry?, hash: (@Sendable (String) -> String?)? = nil
    ) {
        let resolved = Self.normalize(root.path(percentEncoded: false))
        self.root = resolved
        self.ownWrites = ownWrites
        self.hash =
            hash ?? { relative in
                guard let data = try? Data(contentsOf: URL(filePath: resolved).appending(path: relative)) else {
                    return nil
                }
                return FileStamp.hash(data)
            }
    }

    /// The trigger for `events`, or `nil` when none matters.
    public func decide(_ events: [VaultFSEvent], at now: Date) -> SyncTrigger? {
        if let dropped = events.first(where: { $0.flags & VaultFSEvent.rescanFlags != 0 }) {
            return SyncTrigger(.rescanVault, reason: "file events dropped (\(relativePath(dropped.path) ?? "root"))")
        }
        for event in events {
            guard let relative = relativePath(event.path), Self.isSynced(relative) else { continue }
            if let ownWrites, ownWrites.isOwnWrite(path: relative, currentSHA: hash(relative), at: now) { continue }
            return SyncTrigger(.live, reason: relative)
        }
        return nil
    }

    /// The root-relative path of `path`, or `nil` outside the root (or the root itself).
    public func relativePath(_ path: String) -> String? {
        let normalized = Self.normalize(path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard normalized.hasPrefix(prefix) else { return nil }
        let relative = String(normalized.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// `false` for `.c2mdsync/…` and any dot component.
    static func isSynced(_ relative: String) -> Bool {
        !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Resolves symlinks (`/var` → `/private/var`) and drops a trailing slash.
    static func normalize(_ path: String) -> String {
        var resolved = (path as NSString).resolvingSymlinksInPath
        if resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }
}

#if os(macOS)
    /// FSEvents on the notes root (file-level, recursive) → live triggers;
    /// lost events → a vault rescan (architecture §10). Events only trigger
    /// runs: every run enumerates the whole vault (the parse cache keeps
    /// that cheap), so a merged or dropped event can never lose a change.
    ///
    /// In the sandboxed app the root's security scope must stay open while
    /// the source runs.
    public final class VaultChangeSource: SyncTriggerSource {
        public let filter: VaultEventFilter
        private let latency: TimeInterval
        private let clock: any TriggerClock
        private let queue = DispatchQueue(label: "com.zmre.contacts2mdsync.fsevents")
        private let state = Mutex<(stream: StreamBox?, emit: (@Sendable (SyncTrigger) -> Void)?)>((nil, nil))

        private final class StreamBox: @unchecked Sendable {
            let stream: FSEventStreamRef
            init(_ stream: FSEventStreamRef) { self.stream = stream }
        }

        /// Watches `root`; `ownWrites` suppresses our own writes.
        public init(
            root: URL, ownWrites: OwnWriteRegistry?, latency: TimeInterval = 0.5,
            clock: any TriggerClock = SystemTriggerClock()
        ) {
            filter = VaultEventFilter(root: root, ownWrites: ownWrites)
            self.latency = latency
            self.clock = clock
        }

        /// Feeds events through the filter (what the FSEvents callback does).
        public func handle(_ events: [VaultFSEvent]) {
            guard let emit = state.withLock({ $0.emit }), let trigger = filter.decide(events, at: clock.now) else {
                return
            }
            emit(trigger)
        }

        public func start(_ emit: @escaping @Sendable (SyncTrigger) -> Void) {
            state.withLock { $0.emit = emit }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let source = Unmanaged<VaultChangeSource>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let events = (0..<min(count, list.count)).map { VaultFSEvent(path: list[$0], flags: flags[$0]) }
                source.handle(events)
            }
            let flags = UInt32(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot)
            guard
                let stream = FSEventStreamCreate(
                    kCFAllocatorDefault, callback, &context, [filter.root] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            state.withLock { $0.stream = StreamBox(stream) }
        }

        public func stop() {
            let box = state.withLock { state in
                defer { state = (nil, nil) }
                return state.stream
            }
            guard let box else { return }
            FSEventStreamStop(box.stream)
            FSEventStreamInvalidate(box.stream)
            FSEventStreamRelease(box.stream)
        }

        deinit { stop() }
    }
#endif
