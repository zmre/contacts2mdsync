public import ContactModel
internal import Foundation
internal import Synchronization

/// Spike S15 behaviour of the Contacts framework without the notes
/// entitlement, and writes as Contacts.app scripting makes them
/// (architecture §6 "Write routing").
extension FakeContactStore {
    /// Models the real Contacts framework without the notes entitlement
    /// (spike S15): `apply` fails every update, stamp, unstamp and group
    /// change of a card that has a note with `rejectedForNote` (134092, no
    /// partial change), and `removeMember` saves without changing anything.
    /// Writes through `scriptedApply` (Contacts.app) are not affected.
    public func setModelsFrameworkWithoutNotesEntitlement(_ enabled: Bool) {
        state.withLock {
            $0.notedCardsRejectUpdates = enabled
            $0.removeMemberIsNoOp = enabled
        }
    }

    /// Framework operations rejected with 134092 so far.
    public var rejectedForNote: [AppleWriteOperation] { state.withLock { $0.rejectedForNote } }

    /// Operations written through `scriptedApply` so far.
    public var scriptedOperations: [AppleWriteOperation] { state.withLock { $0.scriptedOperations } }

    /// Writes `operations` as Contacts.app scripting does (spike S15):
    /// every card, with or without a note; `removeMember` works; each
    /// card's save is one history event authored by nobody we exclude.
    /// Edits `CardScriptingSupport` cannot express are left out and
    /// reported in `skipped`. Creates and deletes fail (not scripted).
    public func scriptedApply(_ operations: [AppleWriteOperation]) -> AppleWriteResult {
        state.withLock { state in
            var result = AppleWriteResult(applied: [])
            for operation in operations {
                var effective = operation
                if case .update(let cardID, let edits) = operation {
                    var kept: [CardEdit] = []
                    for edit in edits {
                        if let reason = CardScriptingSupport.unsupported(edit) {
                            result.skipped.append(AppleWriteSkip(operation: operation, edit: edit, reason: reason))
                        } else {
                            kept.append(edit)
                        }
                    }
                    effective = .update(cardID: cardID, edits: kept)
                }
                do {
                    switch operation {
                    case .create, .delete: throw FakeError(description: "\(operation.summary) is not scripted")
                    default: break
                    }
                    var ignored = AppleWriteResult(applied: [])
                    try Self.apply(effective, to: &state, result: &ignored)
                    result.applied.append(operation)
                    result.scripted.append(operation)
                    state.scriptedOperations.append(operation)
                    if let cardID = operation.cardID { state.history.append((nil, .changed(cardID))) }
                } catch {
                    result.failed.append(
                        AppleWriteFailure(
                            operation: operation, message: "\(operation.summary) via Contacts.app: \(error)"))
                }
            }
            return result
        }
    }

    /// `true` when the framework rejects `operation` because its card has a note (S15 model on).
    static func rejectsForNote(_ operation: AppleWriteOperation, state: State) -> Bool {
        guard state.notedCardsRejectUpdates, !state.notesEntitled, let cardID = operation.cardID else { return false }
        if case .delete = operation { return false }
        guard let contact = state.contacts.first(where: { $0.cards.contains { $0.id == cardID } }),
            let card = contact.cards.first(where: { $0.id == cardID })
        else { return false }
        return !(scriptedNote(of: card, in: contact) ?? "").isEmpty
    }
}
