#if os(macOS)
    internal import ContactModel
    internal import Foundation

    /// Sending one card's commands (architecture §6 "Write routing"): an
    /// existing element Contacts.app cannot find by `id` (`-1728`; instant
    /// messages, spike S16) is tried by its `whose` form, else left out and
    /// its list edit reported skipped, while the rest of the card is written.
    extension ScriptingCardWriter {
        /// What sending one card's commands did.
        struct Sent {
            /// A per-card error: the card's operations fail.
            var failure: (any Error)?
            /// Elements Contacts.app could not find (`-1728`), by class, with the error.
            var unresolved: [FourCharCode: ContactsScriptingError] = [:]
            /// A command changing the card's fields went through.
            var changedFields = false
        }

        /// Sends `commands` to person `cardID`, then `save` — also after a
        /// per-object error, so nothing is left unsaved in Contacts.app.
        /// Session-level errors throw.
        ///
        /// An existing element Contacts.app cannot find by `id` (`-1728`) is
        /// tried again through its `whose` form in `matches` (instant
        /// messages, spike S16); if that fails too, the element's remaining
        /// commands are left out and its class is reported `unresolved`
        /// (the rest of the card is still written) — unless the person itself
        /// does not resolve, which fails the card.
        func send(
            _ commands: [ScriptCommand], to cardID: String, matches: [String: ElementMatch]
        ) throws -> Sent {
            var sent = Sent()
            guard !commands.isEmpty else { return sent }
            var addressing = ElementAddressing(matches: matches)
            var personChecked = false
            for command in commands {
                guard let target = command.target else {
                    do {
                        _ = try session.send(command.event(person: cardID))
                        sent.changedFields = sent.changedFields || command.changesFields
                        personChecked = true
                    } catch let error as ContactsScriptingError {
                        sent.failure = error
                        break
                    }
                    continue
                }
                if addressing.unresolved.contains(target.id) { continue }
                do {
                    try sendElement(command, target: target, to: cardID, addressing: &addressing)
                    sent.changedFields = true
                    personChecked = true
                } catch let error as ContactsScriptingError where error.isNoSuchObject {
                    if !personChecked {
                        if let missing = personMissing(cardID) {
                            sent.failure = missing
                            break
                        }
                        personChecked = true
                    }
                    addressing.unresolved.insert(target.id)
                    sent.unresolved[target.element] = error
                    elements.withLock { $0.unresolved += 1 }
                } catch let error as ContactsScriptingError {
                    sent.failure = error
                    break
                }
            }
            _ = try session.send(ContactsScriptingEvents.save())
            return sent
        }

        /// How this card's existing elements are addressed while sending.
        struct ElementAddressing {
            /// `whose` forms by element id, kept up to date as commands change the element.
            var matches: [String: ElementMatch]
            /// Elements already found not to resolve by `id`.
            var byMatch: Set<String> = []
            /// Elements given up on.
            var unresolved: Set<String> = []

            /// After `command` went through: its new value is what finds the element next.
            mutating func record(_ command: ScriptCommand, on id: String) {
                if case .setElement(_, _, let property) = command, let match = matches[id] {
                    matches[id] = match.updating(property)
                }
            }
        }

        /// Sends one element command by `id`, or by its `whose` form once the
        /// id did not resolve. Throws the `-1728` when neither finds it.
        func sendElement(
            _ command: ScriptCommand, target: (element: FourCharCode, id: String), to cardID: String,
            addressing: inout ElementAddressing
        ) throws {
            let match = addressing.matches[target.id]
            if !addressing.byMatch.contains(target.id) {
                do {
                    _ = try session.send(command.event(person: cardID))
                    addressing.record(command, on: target.id)
                    return
                } catch let error as ContactsScriptingError where error.isNoSuchObject && match != nil {
                    addressing.byMatch.insert(target.id)
                }
            }
            guard let match, let event = command.event(person: cardID, matching: match) else {
                throw ContactsScriptingError(number: -1728, message: "no way to address element \(target.id)")
            }
            _ = try session.send(event)
            elements.withLock { $0.byMatch += 1 }
            addressing.record(command, on: target.id)
        }

        /// `nil` when Contacts.app resolves `person id cardID`; else the error.
        func personMissing(_ cardID: String) -> ContactsScriptingError? {
            do {
                _ = try session.send(ContactsScriptingEvents.personID(cardID))
                return nil
            } catch let error as ContactsScriptingError {
                return error
            } catch {
                return nil  // session-level: the next command reports it
            }
        }

        /// Contacts.app scripting classes → the list field their edits come from.
        static let listFields: [FourCharCode: AppleListField] = {
            typealias Code = ContactsScriptingEvents.CardCode
            return [
                Code.email: .emails, Code.phone: .phones, Code.url: .urls, Code.address: .addresses,
                Code.relatedName: .relations, Code.socialProfile: .social, Code.instantMessage: .im,
                Code.customDate: .dates,
            ]
        }()

        /// The list edits whose elements Contacts.app could not find, as
        /// skips (the executor's verification records what the card did not
        /// keep as unapplyable, by value). Throws when an unresolved element
        /// belongs to no list edit (e.g. a stamp URL): then the card fails.
        static func unresolvedSkips(
            _ unresolved: [FourCharCode: ContactsScriptingError], of unit: Unit
        ) throws -> [AppleWriteSkip] {
            var skips: [AppleWriteSkip] = []
            for (element, error) in unresolved.sorted(by: { $0.key < $1.key }) {
                guard let field = listFields[element] else { throw error }
                let found = unit.operations.compactMap { operation -> AppleWriteSkip? in
                    guard case .update(_, let edits) = operation,
                        let edit = edits.first(where: { if case .list(field, _) = $0 { true } else { false } })
                    else { return nil }
                    return AppleWriteSkip(
                        operation: operation, edit: edit, reason: "\(unresolvedReason) (\(field.rawValue))")
                }
                guard !found.isEmpty else { throw error }
                skips += found
            }
            return skips
        }

        /// The reason recorded for edits of elements Contacts.app could not find.
        public static let unresolvedReason = "Contacts.app could not find the element to change (-1728)"
    }
#endif
