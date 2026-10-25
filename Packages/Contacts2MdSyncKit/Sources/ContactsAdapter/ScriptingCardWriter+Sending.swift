#if os(macOS)
    internal import ContactModel
    internal import Foundation

    /// Sending one card's commands (architecture §6 "Write routing"): an
    /// element Contacts.app refuses to change (any per-object Apple Event
    /// error: `-1719`, `-1728`, `-10000`, `-10006`, `-1708`, …; spike S16) is
    /// left out and its list edit reported skipped, while the rest of the
    /// card is written and saved. Only person-level failures fail the card.
    extension ScriptingCardWriter {
        /// What sending one card's commands did.
        struct Sent {
            /// A person-level error: the card's operations fail.
            var failure: (any Error)?
            /// Element classes with a command Contacts.app refused, with the first error.
            var refused: [FourCharCode: ContactsScriptingError] = [:]
            /// A command changing the card's fields went through.
            var changedFields = false
        }

        /// Errors that are session-level for most events but, on an element
        /// command after Contacts.app answered, concern only that element
        /// (`-1708` errAEEventNotHandled: the element does not take the
        /// event). The person check that follows tells the two apart.
        static let elementLevelErrors: Set<Int> = [-1708]

        /// Sends `commands` to person `cardID`, then `save` — also after a
        /// per-object error, so nothing is left unsaved in Contacts.app.
        /// Session-level errors throw; a failing `save` throws (the card fails).
        ///
        /// Person-level commands (`set` of a person property, group adds and
        /// removes) that fail fail the card. An element command (`set … of
        /// <element> id E`, `make new <element>`, `delete <element> id E`)
        /// that fails with any per-object error leaves that element out: its
        /// remaining commands are not sent and its class is reported
        /// `refused` (the rest of the card is still written) — unless the
        /// person itself no longer resolves, which fails the card.
        func send(_ commands: [ScriptCommand], to cardID: String) throws -> Sent {
            var sent = Sent()
            guard !commands.isEmpty else { return sent }
            var leftOut: Set<String> = []
            for command in commands {
                guard let element = command.element else {
                    do {
                        _ = try session.send(command.event(person: cardID))
                        sent.changedFields = sent.changedFields || command.changesFields
                    } catch let error as ContactsScriptingError {
                        sent.failure = error
                        break
                    }
                    continue
                }
                if let id = element.id, leftOut.contains(id) { continue }
                do {
                    _ = try session.send(command.event(person: cardID), perObject: Self.elementLevelErrors)
                    sent.changedFields = true
                    elements.withLock { $0.sent[element.code, default: 0] += 1 }
                } catch let error as ContactsScriptingError {
                    if let missing = try personMissing(cardID) {
                        sent.failure = missing
                        break
                    }
                    if let id = element.id { leftOut.insert(id) }
                    if sent.refused[element.code] == nil { sent.refused[element.code] = error }
                    elements.withLock { $0.refused += 1 }
                }
            }
            _ = try session.send(ContactsScriptingEvents.save())
            return sent
        }

        /// `nil` when Contacts.app resolves `person id cardID`; else the
        /// per-object error. Session-level errors throw.
        func personMissing(_ cardID: String) throws -> ContactsScriptingError? {
            do {
                _ = try session.send(ContactsScriptingEvents.personID(cardID))
                return nil
            } catch let error as ContactsScriptingError {
                return error
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

        /// The list edits whose elements Contacts.app refused, as skips with
        /// the error in the reason (the executor's verification records what
        /// the card did not keep as unapplyable, by value — not retried while
        /// unchanged). Throws when a refused element belongs to no list edit
        /// (e.g. the stamp URL): then the card fails.
        static func refusedSkips(
            _ refused: [FourCharCode: ContactsScriptingError], of unit: Unit
        ) throws -> [AppleWriteSkip] {
            var skips: [AppleWriteSkip] = []
            for (element, error) in refused.sorted(by: { $0.key < $1.key }) {
                guard let field = listFields[element] else { throw error }
                let found = unit.operations.compactMap { operation -> AppleWriteSkip? in
                    guard case .update(_, let edits) = operation,
                        let edit = edits.first(where: { if case .list(field, _) = $0 { true } else { false } })
                    else { return nil }
                    return AppleWriteSkip(
                        operation: operation, edit: edit,
                        reason: CardScriptingSupport.elementFailureReason(field, error: error.description))
                }
                guard !found.isEmpty else { throw error }
                skips += found
            }
            return skips
        }
    }
#endif
