#if os(macOS)
    public import ContactModel
    internal import Contacts
    public import Foundation
    internal import Synchronization

    /// Reads the cards and group members the scripting writer starts from
    /// (Contacts framework reads work on cards that have a note; only saves
    /// fail, spike S15). Injected so tests never touch a real store.
    protocol ScriptingCardReading: Sendable {
        /// Underlying cards (never unified) with every field the writer may touch.
        func cards(_ ids: [String]) throws -> [String: CNContact]
        /// Card ids in a group.
        func memberIDs(ofGroup id: String) throws -> Set<String>
    }

    /// The real reader: a fresh `CNContactStore` per call, `unifyResults = false`.
    struct ContactStoreCardReader: ScriptingCardReading {
        func cards(_ ids: [String]) throws -> [String: CNContact] {
            try CNContactStoreAdapter.ensureAccess()
            return try CardWriter(store: CNContactStore(), includeNote: false).fetchCards(ids, includeImage: false)
        }

        func memberIDs(ofGroup id: String) throws -> Set<String> {
            try CNContactStoreAdapter.ensureAccess()
            return try CardWriter(store: CNContactStore(), includeNote: false).memberIDs(of: id)
        }
    }

    /// Card writes through Contacts.app scripting (`CardScripting`,
    /// architecture §6 "Write routing", spike S15): for cards with a note
    /// without the notes entitlement (CNSaveRequest fails with 134092), and
    /// for every group removal (CNSaveRequest's `removeMember` is a no-op on
    /// iCloud).
    ///
    /// Per card, in one Contacts.app `save`:
    ///
    /// 1. Read the card through the Contacts framework and apply the
    ///    operations' edits to a copy with `CardWriter`, exactly as the
    ///    framework route would (`ScriptedCardPlan` explains the diff).
    ///    Edits scripting cannot express (`CardScriptingSupport`, among
    ///    them every instant-message edit) are left out and reported in
    ///    `skipped`; no Apple Event is sent for them.
    /// 2. Send the commands as raw Apple Events through the session (`person
    ///    id` is the card id; element ids are `CNLabeledValue` identifiers),
    ///    then `save`. A person-level error (the person does not resolve, a
    ///    person property or group command fails, `save` fails) still saves
    ///    what was set, so nothing is left unsaved in Contacts.app, and fails
    ///    that card's operations. An element command Contacts.app refuses
    ///    (any per-object error, e.g. `-1719`, `-1728`, `-10000`; spike S16)
    ///    leaves only that element out: its list edit is reported in
    ///    `skipped` with the error, and the rest of the card is applied (the
    ///    executor's verification records, by value, what the card did not
    ///    keep as unapplyable — not retried while unchanged).
    /// 3. Re-read the card until the change is visible to the Contacts
    ///    framework (S15 saw it at once; up to `visibleTimeout`), so the
    ///    executor's verification sees the write.
    public final class ScriptingCardWriter: CardScripting {
        /// The Contacts.app session (shared with the run's notes provider).
        public let session: ContactsAppSession
        let reader: any ScriptingCardReading
        /// How long to wait for a scripted change to show in the Contacts framework.
        public let visibleTimeout: TimeInterval
        let sleep: @Sendable (TimeInterval) -> Void
        let elements = Mutex(ElementLog())

        /// Element commands so far (spike S16, `--verbose`).
        public struct ElementLog: Hashable, Sendable {
            /// Element commands Contacts.app took, by element class.
            public var sent: [FourCharCode: Int] = [:]
            /// Element commands Contacts.app refused (each left its element out).
            public var refused = 0
        }

        /// Element commands so far.
        public var elementLog: ElementLog { elements.withLock { $0 } }

        /// Creates a writer over `session` (the real Contacts framework reads).
        public convenience init(session: ContactsAppSession, visibleTimeout: TimeInterval = 1) {
            self.init(
                session: session, reader: ContactStoreCardReader(), visibleTimeout: visibleTimeout,
                sleep: { Thread.sleep(forTimeInterval: $0) })
        }

        init(
            session: ContactsAppSession, reader: any ScriptingCardReading, visibleTimeout: TimeInterval,
            sleep: @escaping @Sendable (TimeInterval) -> Void
        ) {
            self.session = session
            self.reader = reader
            self.visibleTimeout = visibleTimeout
            self.sleep = sleep
        }

        /// The permission for scripted writes (no prompt; a refusal moments
        /// ago does not launch Contacts.app again).
        public func availability() -> NotesAvailability { session.syncAvailability() }

        public func finishSession() { session.finish() }

        public func apply(_ operations: [AppleWriteOperation]) throws -> AppleWriteResult {
            guard !operations.isEmpty else { return AppleWriteResult(applied: []) }
            try session.prepare()
            let units = Self.units(operations)
            let cards = try reader.cards(units.map(\.cardID))
            var members: [String: Set<String>] = [:]
            var result = AppleWriteResult(applied: [])
            var wroteSomething = false
            for (position, unit) in units.enumerated() {
                do {
                    try write(unit, card: cards[unit.cardID], members: &members, result: &result)
                    wroteSomething = true
                } catch let error as NotesUnavailableError {
                    // The session broke (permission, Contacts.app gone): stop here.
                    guard wroteSomething else { throw error }
                    for rest in units[position...] {
                        result.failed += rest.operations.map {
                            AppleWriteFailure(
                                operation: $0, message: "\($0.summary) via Contacts.app: \(error)")
                        }
                    }
                    break
                } catch {
                    result.failed += unit.operations.map {
                        AppleWriteFailure(operation: $0, message: "\($0.summary) via Contacts.app: \(error)")
                    }
                }
            }
            return result
        }

        // MARK: - One card

        /// The operations of one card, in first-seen order.
        struct Unit {
            var cardID: String
            var operations: [AppleWriteOperation]
        }

        static func units(_ operations: [AppleWriteOperation]) -> [Unit] {
            var units: [Unit] = []
            for operation in operations {
                guard let cardID = operation.cardID else { continue }
                if let index = units.firstIndex(where: { $0.cardID == cardID }) {
                    units[index].operations.append(operation)
                } else {
                    units.append(Unit(cardID: cardID, operations: [operation]))
                }
            }
            return units
        }

        /// What one card's operations become: the commands, and the edits left out.
        struct CardPlan {
            var commands: [ScriptCommand] = []
            var skipped: [AppleWriteSkip] = []
        }

        /// Plans one card (pure: no store, no events). `members` answers a
        /// group's current card ids (adds and removes are sent only when they
        /// change something).
        static func plan(_ unit: Unit, card: CNContact, members: (String) throws -> Set<String>) throws -> CardPlan {
            var plan = CardPlan()
            guard let after = card.mutableCopy() as? CNMutableContact else { return plan }
            var groups: [ScriptCommand] = []
            for operation in unit.operations {
                plan.skipped += try stage(operation, on: after, members: members, groups: &groups)
            }
            let fields = ScriptedCardPlan(before: card, after: after)
            plan.commands = fields.commands + groups
            return plan
        }

        /// Applies one operation to `after` (fields) or `groups` (membership);
        /// returns the edits scripting cannot express.
        private static func stage(
            _ operation: AppleWriteOperation, on after: CNMutableContact, members: (String) throws -> Set<String>,
            groups: inout [ScriptCommand]
        ) throws -> [AppleWriteSkip] {
            switch operation {
            case .update(_, let edits):
                var skipped: [AppleWriteSkip] = []
                for edit in edits {
                    guard let reason = CardScriptingSupport.unsupported(edit) else {
                        try CardWriter.apply(edit, to: after, includeNote: false)
                        continue
                    }
                    skipped.append(AppleWriteSkip(operation: operation, edit: edit, reason: reason))
                }
                return skipped
            case .stamp(_, let id):
                CardWriter.setStamp(id, on: after)
            case .removeStamp:
                after.urlAddresses = after.urlAddresses.filter { !SyncStamp.isStamp($0.value as String) }
            case .addMember(let cardID, let groupID):
                if !(try members(groupID)).contains(cardID) { groups.append(.addToGroup(groupID)) }
            case .removeMember(let cardID, let groupID):
                if try members(groupID).contains(cardID) { groups.append(.removeFromGroup(groupID)) }
            case .create, .delete:
                throw ContactStoreError.notImplemented("\(operation.summary) through Contacts.app")
            }
            return []
        }

        private func write(
            _ unit: Unit, card: CNContact?, members: inout [String: Set<String>], result: inout AppleWriteResult
        ) throws {
            guard let card else { throw ContactStoreError.cardNotFound(unit.cardID) }
            var cache = members
            let plan = try Self.plan(unit, card: card) { group in
                if let known = cache[group] { return known }
                let ids = try reader.memberIDs(ofGroup: group)
                cache[group] = ids
                return ids
            }
            members = cache
            let sent = try send(plan.commands, to: unit.cardID)
            if let failure = sent.failure { throw failure }
            let refused = try Self.refusedSkips(sent.refused, of: unit)
            if sent.changedFields { waitUntilVisible(unit.cardID, before: card) }
            Self.update(&members, after: plan.commands, cardID: unit.cardID)
            result.applied += unit.operations
            result.scripted += unit.operations
            result.skipped += plan.skipped + refused
        }

        /// The cached group members after `commands`.
        private static func update(
            _ members: inout [String: Set<String>], after commands: [ScriptCommand], cardID: String
        ) {
            for command in commands {
                switch command {
                case .addToGroup(let group): members[group]?.insert(cardID)
                case .removeFromGroup(let group): members[group]?.remove(cardID)
                default: break
                }
            }
        }

        /// Polls the Contacts framework until the card differs from `before`.
        private func waitUntilVisible(_ cardID: String, before: CNContact) {
            var waited: TimeInterval = 0
            let step = 0.05
            while waited < visibleTimeout {
                if let now = try? reader.cards([cardID])[cardID],
                    !ScriptedCardPlan(before: before, after: now).commands.isEmpty
                {
                    return
                }
                sleep(step)
                waited += step
            }
        }
    }
#endif
