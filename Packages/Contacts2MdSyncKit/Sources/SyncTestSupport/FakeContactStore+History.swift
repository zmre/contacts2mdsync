public import ContactModel
public import Foundation
internal import Synchronization

/// Change history (M5): events recorded by writes and edits, read back
/// since a token with author exclusion, like `CNChangeHistoryFetchRequest`.
extension FakeContactStore {
    public func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult {
        try state.withLock { state in
            guard state.accessGranted else { throw ContactStoreError.accessDenied }
            guard state.historySupported else { return .unsupported }
            if state.failNextHistory {
                state.failNextHistory = false
                throw FakeError(description: "simulated change-history failure")
            }
            state.historyReads += 1
            let current = Self.token(state)
            guard let token, let start = Self.position(of: token, in: state) else {
                // A nil, foreign or pre-reset token: DropEverything (spike S3).
                return .reset(token: current)
            }
            let excluded = Set(authors)
            var changed: [String] = []
            var deleted: [String] = []
            var groupsChanged = false
            var count = 0
            for (author, event) in state.history[start...] where !(author.map(excluded.contains) ?? false) {
                count += 1
                switch event {
                case .changed(let id): if !changed.contains(id) { changed.append(id) }
                case .deleted(let id): if !deleted.contains(id) { deleted.append(id) }
                case .group: groupsChanged = true
                }
            }
            return .changes(
                HistoryChanges(
                    changedCardIDs: changed, deletedCardIDs: deleted, groupsChanged: groupsChanged,
                    eventCount: count, token: current))
        }
    }

    public func currentHistoryToken() throws -> Data? {
        try state.withLock { state in
            guard state.accessGranted else { throw ContactStoreError.accessDenied }
            return state.historySupported ? Self.token(state) : nil
        }
    }

    public func refetch(cardIDs: [String], siblingHints: [String]) throws -> AppleRefetch {
        try state.withLock { state in
            guard state.accessGranted else { throw ContactStoreError.accessDenied }
            state.refetches.append(cardIDs)
            let view = Self.view(of: state)
            let wanted = Set(cardIDs)
            return AppleRefetch(
                contacts: view.contacts.filter { $0.cards.contains { wanted.contains($0.id) } },
                containers: view.containers, groups: view.groups, notesAvailable: view.notesAvailable)
        }
    }

    static func token(_ state: State) -> Data { Data("fake-history:\(state.historyEpoch):\(state.history.count)".utf8) }

    /// The history index a token points at, or `nil` when it is not ours or predates a reset.
    static func position(of token: Data, in state: State) -> Int? {
        let parts = (String(bytes: token, encoding: .utf8) ?? "").split(separator: ":")
        guard parts.count == 3, parts[0] == "fake-history", Int(parts[1]) == state.historyEpoch,
            let index = Int(parts[2]), index <= state.history.count
        else { return nil }
        return index
    }
}
