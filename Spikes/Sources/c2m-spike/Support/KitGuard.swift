import ContactModel
import Contacts
import ContactsAdapter
import Foundation

/// The real M3 Apple write path (`CNContactStoreAdapter.apply` → `CardWriter`),
/// wrapped so it can only ever touch harness scratch cards (spike S13).
///
/// `apply` never forwards a batch until `HarnessBatchGuard.check` has passed
/// for EVERY operation in it. One bad operation refuses the whole batch:
///
/// - every target card id is re-fetched (`unifyResults = false`) right before
///   the save and must pass `Harness.isHarness` and carry this spike's tag;
/// - an edit must not be able to remove the harness name prefix or marker
///   (a URL list edit must keep the card's marker; given/family name edits
///   must keep the `ZZ Spike ` prefix); note and image edits are refused;
/// - a create must set the `ZZ Spike ` name prefix and a marker URL of this
///   spike; its groups must be allowed scratch groups;
/// - group operations must name a group whose name is in `allowedGroupNames`
///   (re-fetched by id) and a card that passes the checks above.
///
/// After the save, every created and still-existing target card is fetched
/// again and must still pass `Harness.isHarness`; a failure is reported as a
/// SAFETY error (the save already happened, so this is a loud alarm, not a
/// guard).
///
/// Deliberately NOT a `ContactStore` conformer: it exposes only `apply`, so
/// the harness has no way to reach any other write entry point, and it keeps
/// building while the protocol grows (M5 history/refetch requirements).
struct HarnessGuardedStore {
    /// The real adapter; only `apply` is ever called on it.
    private let inner = CNContactStoreAdapter()
    /// Spike tag every target card's marker must carry (e.g. `s13`).
    let spike: String
    /// Exact names of groups that group operations may use.
    let allowedGroupNames: Set<String>
    let log: ApplyLog

    func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult {
        let store = CNContactStore()
        let guardCheck = HarnessBatchGuard(store: store, spike: spike, allowedGroupNames: allowedGroupNames)
        try guardCheck.check(batch)
        let result = try inner.apply(batch, author: author)
        log.record(batch: batch, author: author, result: result)
        try guardCheck.postCheck(batch, result: result)
        return result
    }
}

/// Counts what went through `HarnessGuardedStore.apply` (instrumentation for
/// the "no unified save" check: every operation names an underlying card id).
final class ApplyLog: @unchecked Sendable {
    struct Entry {
        var operations: [AppleWriteOperation]
        var author: String
        var applied: Int
        var failed: [String]
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    var entries: [Entry] { lock.withLock { storage } }

    func record(batch: AppleWriteBatch, author: String, result: AppleWriteResult) {
        lock.withLock {
            storage.append(
                Entry(
                    operations: batch.operations, author: author, applied: result.applied.count,
                    failed: result.failed.map { "\(HarnessBatchGuard.describe($0.operation)): \($0.message)" }))
        }
    }
}

/// The pre- and post-save checks for one batch.
struct HarnessBatchGuard {
    let store: CNContactStore
    let spike: String
    let allowedGroupNames: Set<String>
    /// Cards on which an `image` edit is allowed (S16: only a card that has a
    /// note, so the router sends it to Contacts.app scripting, which skips it).
    /// Empty for S13/S15: every image edit is refused.
    var imageAllowedCardIDs: Set<String> = []

    /// Throws `SpikeError` (SAFETY) unless every operation targets harness
    /// material only. Nothing is written by this function.
    func check(_ batch: AppleWriteBatch) throws {
        var cards: [String: CNContact] = [:]
        for operation in batch.operations {
            if let id = operation.cardID, cards[id] == nil {
                cards[id] = try harnessCard(id, for: operation)
            }
            switch operation {
            case .update(let cardID, let edits):
                try checkEdits(edits, on: cards[cardID]!, describing: operation)
            case .create(let new):
                try checkCreate(new)
            case .addMember(_, let groupID), .removeMember(_, let groupID):
                try checkGroup(groupID, describing: operation)
            case .stamp, .removeStamp, .delete:
                break  // card verified above; stamps never touch the marker URL
            }
        }
    }

    /// After the save: created cards and surviving targets must still be harness cards.
    func postCheck(_ batch: AppleWriteBatch, result: AppleWriteResult) throws {
        var problems: [String] = []
        let deleted = Set(batch.operations.compactMap { op -> String? in
            if case .delete(let id) = op { id } else { nil }
        })
        let targets = Set(batch.operations.compactMap(\.cardID)).subtracting(deleted)
        for id in targets.sorted() {
            // A Google card may already have a new id (server churn); a missing
            // id is reported by the caller's re-location step, not here.
            guard let card = try fetchUnderlying(store, id: id, keys: []) else { continue }
            if !Harness.isHarness(card) { problems.append("target \(id) no longer passes the harness check") }
        }
        for (_, id) in result.createdCardIDs.sorted(by: { $0.value < $1.value }) {
            guard let card = try fetchUnderlying(store, id: id, keys: []) else { continue }
            if !Harness.isHarness(card) { problems.append("created card \(id) does not pass the harness check") }
        }
        if !problems.isEmpty {
            throw SpikeError("SAFETY (post-save): " + problems.joined(separator: "; ") + ". Stop and inspect by hand.")
        }
    }

    // MARK: - Cards

    private func harnessCard(_ id: String, for operation: AppleWriteOperation) throws -> CNContact {
        guard let card = try fetchUnderlying(store, id: id, keys: []) else {
            throw SpikeError("SAFETY: \(Self.describe(operation)): card \(id) not found; refusing the whole batch.")
        }
        guard Harness.isHarness(card) else {
            throw SpikeError(
                "SAFETY: \(Self.describe(operation)): card \(id) is not a harness card (name prefix + marker). "
                    + "Refusing the whole batch.")
        }
        guard Harness.marker(card).flatMap(Harness.spikeTag) == spike else {
            throw SpikeError(
                "SAFETY: \(Self.describe(operation)): card \(id) is a harness card of another spike, not \(spike). "
                    + "Refusing the whole batch.")
        }
        return card
    }

    private func checkEdits(_ edits: [CardEdit], on card: CNContact, describing operation: AppleWriteOperation) throws {
        var given = card.givenName
        var family = card.familyName
        for edit in edits {
            switch edit {
            case .scalar(.givenName, let value): given = value ?? ""
            case .scalar(.familyName, let value): family = value ?? ""
            case .list(.urls, let elements):
                // CardWriter drops every representable URL not listed, so the
                // marker must be listed (as kept or new) or it would vanish.
                guard let marker = Harness.marker(card),
                    elements.contains(where: { $0.value == .text(marker) })
                else {
                    throw SpikeError(
                        "SAFETY: \(Self.describe(operation)): URL list edit would remove the harness marker. "
                            + "Refusing the whole batch.")
                }
            case .image where imageAllowedCardIDs.contains(card.identifier):
                break
            case .note, .image:
                throw SpikeError(
                    "SAFETY: \(Self.describe(operation)): note/image edits are out of scope here. "
                        + "Refusing the whole batch.")
            default: break
            }
        }
        let name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        guard name.hasPrefix(Harness.namePrefix) else {
            throw SpikeError(
                "SAFETY: \(Self.describe(operation)): name edit would drop the \"\(Harness.namePrefix)\" prefix. "
                    + "Refusing the whole batch.")
        }
    }

    private func checkCreate(_ new: NewAppleContact) throws {
        var given = ""
        var family = ""
        var hasMarker = false
        let markerPrefix = "\(Harness.markerScheme)\(spike):"
        for edit in new.edits {
            switch edit {
            case .scalar(.givenName, let value): given = value ?? ""
            case .scalar(.familyName, let value): family = value ?? ""
            case .list(.urls, let elements):
                hasMarker = elements.contains {
                    if case .text(let text) = $0.value { text.hasPrefix(markerPrefix) } else { false }
                }
            case .note, .image:
                throw SpikeError("SAFETY: create with note/image is out of scope for S13. Refusing the whole batch.")
            default: break
            }
        }
        let name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        guard name.hasPrefix(Harness.namePrefix), hasMarker else {
            throw SpikeError(
                "SAFETY: create without the \"\(Harness.namePrefix)\" name prefix and a \(markerPrefix) marker URL. "
                    + "Refusing the whole batch.")
        }
        for groupID in new.groupIDs { try checkGroup(groupID, describing: .create(new)) }
    }

    // MARK: - Groups

    private func checkGroup(_ groupID: String, describing operation: AppleWriteOperation) throws {
        let groups = try catchingObjC {
            try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupID]))
        }
        guard let group = groups.first(where: { $0.identifier == groupID }) else {
            throw SpikeError("SAFETY: \(Self.describe(operation)): group \(groupID) not found. Refusing the whole batch.")
        }
        guard allowedGroupNames.contains(group.name) else {
            throw SpikeError(
                "SAFETY: \(Self.describe(operation)): group \(groupID) is not a harness scratch group. "
                    + "Refusing the whole batch.")
        }
    }

    // MARK: - Output

    /// One-line, PII-free description (ids and field names only).
    static func describe(_ operation: AppleWriteOperation) -> String {
        switch operation {
        case .stamp(let id, let uuid): "stamp \(id) x-c2mdsync:\(uuid.uuidString.lowercased().prefix(8))…"
        case .removeStamp(let id): "removeStamp \(id)"
        case .update(let id, let edits): "update \(id) [\(edits.map(describe).joined(separator: ", "))]"
        case .create(let new): "create in \(new.containerID) [\(new.edits.map(describe).joined(separator: ", "))]"
        case .delete(let id): "delete \(id)"
        case .addMember(let id, let group): "addMember \(id) -> group \(group)"
        case .removeMember(let id, let group): "removeMember \(id) <- group \(group)"
        }
    }

    static func describe(_ edit: CardEdit) -> String {
        switch edit {
        case .scalar(let field, _): field.rawValue
        case .birthday: "birthday"
        case .list(let field, let elements): "\(field.rawValue)(\(elements.count))"
        case .note: "note"
        case .image: "image"
        }
    }
}
