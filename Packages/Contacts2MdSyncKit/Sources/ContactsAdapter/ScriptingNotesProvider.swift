#if os(macOS)
    public import ContactModel
    public import Foundation
    internal import Synchronization

    /// Remembers, for this process, that macOS refused Automation for Contacts,
    /// so runs in the next `window` skip notes without launching Contacts.app
    /// just to be told again (live sync runs often). `requestPermission()` and
    /// a granted check clear it.
    public final class NotesRefusalMemo: Sendable {
        /// Shared by every provider of the process (the app, `watch`).
        public static let shared = NotesRefusalMemo()

        private let refusedAt = Mutex<Date?>(nil)
        public let window: TimeInterval

        /// Creates a memo (tests use their own).
        public init(window: TimeInterval = 15 * 60) { self.window = window }

        func refused(now: Date) -> Bool {
            refusedAt.withLock { date in date.map { now.timeIntervalSince($0) < window } ?? false }
        }

        func record(_ refused: Bool, now: Date) { refusedAt.withLock { $0 = refused ? now : nil } }
    }

    /// Contacts notes through Contacts.app scripting (Apple Events), for builds
    /// without the notes entitlement (architecture §8, spike S12).
    ///
    /// - Contacts.app's `person` is an **underlying card** and its `id` is the
    ///   CNContact card identifier, so notes are read and written per card.
    /// - Bulk reads (`id of every person`, `note of every person`, then the ids
    ///   again to make sure nothing moved in between) take about 0.5 s for
    ///   3,785 cards; one card takes about 9 ms, so more than `bulkThreshold`
    ///   cards are read in bulk.
    /// - Writes are `set note of person id X to T` + `save`, card by card, then
    ///   verified by reading those cards again.
    /// - Contacts.app is launched hidden and without activation when needed, and
    ///   quit by `finishSession()` if this provider launched it, the user is not
    ///   using it (still hidden, not frontmost) and `quitWhenDone` is set.
    /// - Sync never prompts: events are sent with `neverInteract`, and only when
    ///   macOS already reports the Automation permission as granted. The prompt
    ///   is shown only by `requestPermission()` (Settings, a user action).
    public final class ScriptingNotesProvider: NotesProvider {
        public let source = NotesSource.scripting
        let sender: any AppleEventSending
        let app: any ContactsAppControlling
        /// Quit Contacts.app after a run when this provider launched it.
        public let quitWhenDone: Bool
        /// More cards than this in one read → one bulk read.
        public let bulkThreshold: Int
        /// Seconds per Apple Event (bulk reads of ~50k-character notes included).
        public let eventTimeout: TimeInterval
        /// Seconds to wait for Contacts.app to launch and answer events.
        public let launchTimeout: TimeInterval
        let sleep: @Sendable (TimeInterval) -> Void
        let refusals: NotesRefusalMemo

        private struct Session {
            /// This provider launched Contacts.app (and may quit it).
            var launchedByUs = false
            /// Contacts.app answered an event this session.
            var ready = false
        }

        private let session = Mutex(Session())

        /// Creates a provider (real Apple Events and Contacts.app by default).
        public init(
            sender: any AppleEventSending = LiveAppleEventSender(), app: any ContactsAppControlling = LiveContactsApp(),
            quitWhenDone: Bool = true, bulkThreshold: Int = 40, eventTimeout: TimeInterval = 60,
            launchTimeout: TimeInterval = 15,
            sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
            refusals: NotesRefusalMemo = .shared
        ) {
            self.refusals = refusals
            self.sender = sender
            self.app = app
            self.quitWhenDone = quitWhenDone
            self.bulkThreshold = bulkThreshold
            self.eventTimeout = eventTimeout
            self.launchTimeout = launchTimeout
            self.sleep = sleep
        }

        /// Instructions shown when Automation was refused.
        public static let permissionHelp =
            "Allow it in System Settings ▸ Privacy & Security ▸ Automation ▸ Contacts2MdSync ▸ Contacts, "
            + "then sync again."

        // MARK: - Permission

        /// The permission state without launching Contacts.app (`unknown` when
        /// it is not running: macOS answers only for a running app).
        public func currentPermission() -> NotesPermission {
            guard app.isRunning else { return .unknown }
            return Self.permission(sender.permissionStatus(askUserIfNeeded: false))
        }

        public func availability() -> NotesAvailability {
            do {
                try ensureRunning()
            } catch {
                return .unavailable(String(describing: error))
            }
            return .scripting(Self.permission(sender.permissionStatus(askUserIfNeeded: false)))
        }

        public func requestPermission() -> NotesAvailability {
            do {
                try ensureRunning()
            } catch {
                return .unavailable(String(describing: error))
            }
            let permission = Self.permission(sender.permissionStatus(askUserIfNeeded: true))
            refusals.record(permission != .granted, now: Date())
            return .scripting(permission)
        }

        static func permission(_ status: Int32) -> NotesPermission {
            switch status {
            case 0: .granted
            case -1743: .denied
            case -1744: .notDetermined
            default: .unknown
            }
        }

        // MARK: - Read

        public func readAll(cardIDs: [String]?) throws -> [String: String?] {
            try prepare()
            if let cardIDs, cardIDs.count <= bulkThreshold { return try readCards(cardIDs) }
            let all = try readEveryCard()
            guard let cardIDs else { return all }
            let wanted = Set(cardIDs)
            return all.filter { wanted.contains($0.key) }
        }

        /// Every person's note in bulk; retried when a person was added or
        /// removed between the id and note reads.
        private func readEveryCard() throws -> [String: String?] {
            for _ in 0..<3 {
                let ids = try strings(send(ContactsScriptingEvents.idsOfEveryPerson()))
                let notes = ContactsScriptingEvents.optionalStrings(
                    try send(ContactsScriptingEvents.notesOfEveryPerson()))
                let check = try strings(send(ContactsScriptingEvents.idsOfEveryPerson()))
                guard ids == check, ids.count == notes.count else { continue }
                var result: [String: String?] = [:]
                for (id, note) in zip(ids, notes) { result[id] = .some(note) }
                return result
            }
            throw NotesUnavailableError("Contacts changed during every notes read (3 attempts); notes skipped")
        }

        /// Notes of a few cards, one event each. A card Contacts.app does not
        /// know (`-1728`) is left out (unknown), never reported as empty.
        private func readCards(_ cardIDs: [String]) throws -> [String: String?] {
            var result: [String: String?] = [:]
            for id in cardIDs {
                do {
                    let reply = try send(ContactsScriptingEvents.note(ofPerson: id))
                    result[id] = .some(ContactsScriptingEvents.optionalString(reply))
                } catch let error as ContactsScriptingError where !error.isSessionLevel {
                    continue
                }
            }
            return result
        }

        // MARK: - Write

        public func write(_ notes: [String: String?]) throws -> NotesWriteResult {
            guard !notes.isEmpty else { return NotesWriteResult() }
            try prepare()
            var result = NotesWriteResult()
            var attempted: [String: String] = [:]
            for (id, text) in notes.sorted(by: { $0.key < $1.key }) {
                let value = text ?? ""
                do {
                    _ = try send(ContactsScriptingEvents.setNote(ofPerson: id, to: value))
                    _ = try send(ContactsScriptingEvents.save())
                    attempted[id] = value
                } catch let error as ContactsScriptingError where !error.isSessionLevel {
                    result.failed[id] = error.description
                }
            }
            // Verify: read the written cards again and compare (line endings and
            // trailing whitespace normalized, as Contacts may change them).
            let after = try readAll(cardIDs: attempted.keys.sorted())
            for (id, value) in attempted.sorted(by: { $0.key < $1.key }) {
                guard let note = after[id] else {
                    result.failed[id] = "not found when read back"
                    continue
                }
                if AppleNoteText.body(fromNote: note) == AppleNoteText.body(fromNote: value) {
                    result.written.append(id)
                } else {
                    result.failed[id] = "Contacts kept a different note"
                }
            }
            return result
        }

        // MARK: - Session

        public func finishSession() {
            let launched = session.withLock { state in
                defer { state = Session() }
                return state.launchedByUs
            }
            guard launched, quitWhenDone, app.isRunning, !app.isInUse else { return }
            app.quit()
        }

        /// Contacts.app running (launched hidden when needed).
        private func ensureRunning() throws {
            guard !app.isRunning else { return }
            try app.launchHidden(timeout: launchTimeout)
            session.withLock { $0.launchedByUs = true }
        }

        /// Running, permitted, and answering events.
        private func prepare() throws {
            if session.withLock({ $0.ready }), app.isRunning { return }
            // Refused moments ago: do not launch Contacts.app just to be told again.
            if refusals.refused(now: Date()), !app.isRunning {
                throw NotesUnavailableError("Automation permission for Contacts not granted", permissionDenied: true)
            }
            try ensureRunning()
            let permission = Self.permission(sender.permissionStatus(askUserIfNeeded: false))
            refusals.record(permission != .granted, now: Date())
            switch permission {
            case .granted: break
            case .denied:
                throw NotesUnavailableError(
                    "Automation permission for Contacts denied. " + Self.permissionHelp, permissionDenied: true)
            case .notDetermined, .unknown:
                throw NotesUnavailableError("Automation permission for Contacts not granted", permissionDenied: true)
            }
            // A freshly launched Contacts.app may not answer for a moment.
            let deadline = Date().addingTimeInterval(launchTimeout)
            while true {
                do {
                    _ = try ContactsScriptingEvents.result(
                        of: sender.send(ContactsScriptingEvents.countPeople(), timeout: eventTimeout))
                    break
                } catch let error as ContactsScriptingError where [-600, -609, -1708].contains(error.number) {
                    guard Date() < deadline else {
                        throw NotesUnavailableError("Contacts.app is not answering: \(error)")
                    }
                    sleep(0.2)
                }
            }
            session.withLock { $0.ready = true }
        }

        /// Sends one event; session-level failures become `NotesUnavailableError`.
        private func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
            do {
                return try ContactsScriptingEvents.result(of: sender.send(event, timeout: eventTimeout))
            } catch let error as ContactsScriptingError where error.isSessionLevel {
                session.withLock { $0.ready = false }
                throw NotesUnavailableError(error.description, permissionDenied: error.isPermissionDenied)
            }
        }

        private func strings(_ descriptor: NSAppleEventDescriptor?) -> [String] {
            ContactsScriptingEvents.optionalStrings(descriptor).compactMap { $0 }
        }
    }
#endif
