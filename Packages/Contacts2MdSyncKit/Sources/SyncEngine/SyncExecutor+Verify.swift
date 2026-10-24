internal import ContactModel
internal import Foundation
internal import VaultIndex

/// Write routing hints and verification after the Apple writes
/// (architecture §6 "Write routing", §9 "Unapplyable fields").
extension SyncExecutor {
    /// What this run read about each written card's note (card id → has a
    /// note), for the write routing: without the entitlement a card with a
    /// note must be written through Contacts.app (spike S15). Cards whose
    /// note was not read (notes off or skipped, unknown) are left out.
    static func cardNotes(_ plan: SyncPlan) -> [String: Bool] {
        guard plan.notes.isActive, plan.notes.skipped == nil else { return [:] }
        var notes: [String: Bool] = [:]
        for change in plan.apple {
            guard let contact = plan.records[change.recordID]?.apple else { continue }
            let targets = Set(change.operations.compactMap(\.cardID))
            notes.merge(CardNoteHints.from([contact], cardIDs: targets)) { _, new in new }
        }
        return notes
    }

    /// Edits their route could not express, as unapplyable entries. Only
    /// the image needs one here (verification never calls an image refused,
    /// spike S5); every other skipped edit is found missing by `verify`.
    static func unapplyable(_ skipped: [AppleWriteSkip], plan: SyncPlan) -> [UnapplyableEntry] {
        skipped.compactMap { skip in
            guard case .image(let data) = skip.edit, let cardID = skip.operation.cardID,
                let record = plan.apple.first(where: { $0.operations.contains(skip.operation) })?.recordID
            else { return nil }
            return UnapplyableEntry(
                recordID: record, cardID: cardID, field: "image", attempted: imageAttempt(data),
                observed: "not scriptable")
        }
    }

    /// The `attempted` key of an image write (`∅` = remove).
    static func imageAttempt(_ data: Data?) -> String { data.map(FileStamp.hash) ?? "∅" }

    // MARK: - Verification (unapplyable)

    /// Re-reads every written card and records the writes it did not keep.
    func verify(
        _ plan: SyncPlan, applied: [(record: UUID, operation: AppleWriteOperation)], after snapshot: AppleSnapshot,
        context: SyncContext
    ) -> [UnapplyableEntry] {
        let byCard = Self.contactsByCard(snapshot)
        let groupNames = Dictionary(snapshot.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var entries: [UnapplyableEntry] = []
        for (record, operation) in applied {
            switch operation {
            case .update(let cardID, let edits):
                guard let before = plan.records[record]?.apple,
                    let beforeCard = before.cards.first(where: { $0.id == cardID }),
                    let beforeValues = before.values(of: beforeCard), let after = byCard[cardID],
                    let afterCard = after.cards.first(where: { $0.id == cardID }),
                    let afterValues = after.values(of: afterCard)
                else { continue }
                let notesRead = snapshot.notesAvailable && after.notesUnknown != true  // notes verified only if re-read
                let checked = notesRead ? edits : edits.filter { if case .note = $0 { false } else { true } }
                entries += Verifier(builder: context.builder, record: record, card: cardID).check(
                    checked, before: beforeValues, after: afterValues)
            case .addMember(let cardID, let groupID):
                guard let after = byCard[cardID], !after.groupIDs.contains(groupID),
                    let name = groupNames[groupID], let tag = context.config.tag(forGroup: name)
                else { continue }
                entries.append(
                    UnapplyableEntry(
                        recordID: record, cardID: "*", field: "tags|\(ComparisonKeys.tag(tag))", attempted: "+",
                        observed: "absent"))
            case .removeMember(let cardID, let groupID):
                // CNSaveRequest's removeMember is a silent no-op on iCloud (spike S15): check it took.
                guard let after = byCard[cardID], after.groupIDs.contains(groupID),
                    let name = groupNames[groupID], let tag = context.config.tag(forGroup: name)
                else { continue }
                entries.append(
                    UnapplyableEntry(
                        recordID: record, cardID: "*", field: "tags|\(ComparisonKeys.tag(tag))", attempted: "-",
                        observed: "present"))
            default:
                continue
            }
        }
        return entries
    }

    static func contactsByCard(_ snapshot: AppleSnapshot) -> [String: AppleContact] {
        var byCard: [String: AppleContact] = [:]
        for contact in snapshot.contacts {
            for card in contact.cards { byCard[card.id] = contact }
        }
        return byCard
    }
}

/// Compares a card after a save with the edits sent to it.
private struct Verifier {
    let builder: ViewBuilder
    let record: UUID
    let card: String

    private func entry(_ field: String, _ attempted: String, _ observed: String) -> UnapplyableEntry {
        UnapplyableEntry(recordID: record, cardID: card, field: field, attempted: attempted, observed: observed)
    }

    func check(_ edits: [CardEdit], before: CanonicalContact, after: CanonicalContact) -> [UnapplyableEntry] {
        edits.flatMap { edit -> [UnapplyableEntry] in
            switch edit {
            case .scalar(let apple, let value):
                guard let field = ScalarField.allCases.first(where: { $0.apple == apple }) else { return [] }
                let got = ScalarField.key(field.value(in: after))
                return scalar(field.rawValue, wanted: ScalarField.key(value), got: got)
            case .birthday(let date):
                return scalar(
                    ScalarField.birthday.rawValue, wanted: date?.iso, got: ScalarField.birthday.value(in: after))
            case .note(let text):
                return ComparisonKeys.body(text) == ComparisonKeys.body(after.body)
                    ? [] : [entry("body", "text", "different")]
            case .image:
                return []  // the image may come back as a thumbnail only (spike S5): never "refused"
            case .list(let appleField, let elements):
                guard let field = ListField.allCases.first(where: { $0.apple == appleField }) else { return [] }
                return list(field, elements, before: before, after: after)
            }
        }
    }

    private func scalar(_ field: String, wanted: String?, got: String?) -> [UnapplyableEntry] {
        wanted == got ? [] : [entry(field, wanted ?? "∅", got ?? "∅")]
    }

    /// Additions missing, replacements missing, relabels not kept, removals still present.
    private func list(
        _ field: ListField, _ elements: [AppleListElement], before: CanonicalContact, after: CanonicalContact
    ) -> [UnapplyableEntry] {
        let beforeKeys = Set(builder.apple(before, tags: [], image: .none).list(field).map(\.key))
        let afterLabels = Dictionary(
            builder.apple(after, tags: [], image: .none).list(field).map { ($0.key, $0.label) },
            uniquingKeysWith: { first, _ in first })
        let name = field.rawValue
        var entries: [UnapplyableEntry] = []
        var kept = Set<String>()
        for element in elements {
            let key = builder.key(of: element.value, label: element.label, field: field)
            guard let existing = element.existing else {
                if afterLabels[key] == nil { entries.append(entry("\(name)|\(key)", "+", "absent")) }
                continue
            }
            let old = builder.key(of: existing, label: element.existingLabel, field: field)
            kept.insert(old)
            if old != key {
                if afterLabels[key] == nil { entries.append(entry("\(name)|\(old)", "~\(key)", "absent")) }
            } else if element.label != element.existingLabel, let label = afterLabels[key], label != element.label {
                entries.append(entry("\(name)|\(key)", "@\(element.label ?? "")", "@\(label ?? "")"))
            }
        }
        for key in beforeKeys.subtracting(kept) where afterLabels[key] != nil {
            entries.append(entry("\(name)|\(key)", "-", "present"))
        }
        return entries
    }
}
