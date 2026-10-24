import Contacts2MdCLI
import Foundation

// Review answers (docs/ui.md §4–§7): decision-log entries the next sync applies.

extension AppModel {
    /// Records answers in the decision log; `true` on success.
    @discardableResult
    func decide(_ answers: [UIReviewDecision]) async -> Bool {
        guard let root = rootURL, !answers.isEmpty else { return false }
        do {
            try await source.record(answers, root: root)
            await reload()
            // Following another device: what it still has to apply changed
            // (the leader carries the answers out); count it again.
            if live.state.isFollowing { await check() }
            return true
        } catch {
            errorMessage = Self.describe(error)
            await reload()
            return false
        }
    }

    /// Records conflict resolutions; the next sync applies each one while
    /// both sides still hold the values it was made against.
    @discardableResult
    func resolve(_ choices: [UIConflictChoice]) async -> Bool {
        await decide(choices.map(\.decision))
    }

    /// Records deletion decisions; the next sync carries them out.
    @discardableResult
    func applyDeletions(_ choices: [UIDeletionChoice]) async -> Bool {
        await decide(choices.map(\.decision))
    }

    /// Records "create a contact from this note" for each path.
    @discardableResult
    func addToContacts(paths: [String]) async -> Bool {
        await decide(paths.map { .addContact(path: $0) })
    }
}
