internal import ContactModel
internal import Foundation

/// Turns a record's merge result into card-level Apple writes
/// (architecture §6, "Stamping and write targets"):
///
/// - **Additions** go to the target card: the iCloud card, else the first
///   writable card (a Google-only contact's Google card).
/// - **Edits and deletes** of existing values go to **every** writable card
///   holding a value with that comparison key, so a copy on a linked card
///   cannot come back through the union.
/// - **Single-valued fields** go to the target card and every other writable
///   card that has a non-empty value for the field, so the cards agree
///   whichever one wins the unified display.
/// - Writes that a card already refused (`UnapplyableIndex`) are skipped.
struct AppleWritePlanner {
    let builder: ViewBuilder
    let writableContainers: Set<String>
    let groups: [AppleGroup]
    let config: VaultConfig

    /// What one record needs written.
    struct Output {
        var operations: [AppleWriteOperation] = []
        /// Field names with at least one write.
        var fields: [String] = []
        /// Changes that cannot be made (`tags: family` without an iCloud card).
        var blocked: [String] = []
        /// Unapplyable marks to add now (a tag no card can carry).
        var newUnapplyable: [UnapplyableEntry] = []
    }

    /// The card new values go to.
    func target(of contact: AppleContact) -> AppleCard? {
        let writable = contact.cardsByPrecedence.filter { writableContainers.contains($0.containerID) }
        return contact.stampTargetCard.flatMap { card in writable.first { $0.id == card.id } } ?? writable.first
    }

    func plan(
        record: UUID, contact: AppleContact, merge: MergeResult, imageData: Data?, index: inout UnapplyableIndex,
        renamer: RelationRenamer = .none
    ) -> Output {
        guard let target = target(of: contact) else {
            var output = Output()
            if merge.changesApple { output.blocked.append("no writable card") }
            return output
        }
        var writes = RecordWrites(planner: self, record: record, contact: contact, target: target, index: index)
        writes.scalars(merge)
        for (field, slots) in merge.lists {
            for slot in slots where slot.changesApple { writes.apply(slot, field: field) }
        }
        writes.renameRelations(renamer)
        writes.body(merge)
        writes.image(merge, data: imageData)
        writes.groups(merge)
        index = writes.index
        return writes.finish()
    }

    // MARK: - New contacts

    /// Edits that create a contact from a note's merge view.
    func edits(for view: FieldView, imageData: Data?) -> [CardEdit] {
        var edits: [CardEdit] = []
        for field in ScalarField.allCases {
            guard let value = view.scalars[field] else { continue }
            if let apple = field.apple {
                edits.append(.scalar(apple, value))
            } else {
                edits.append(.birthday(PartialDate(parsing: value)))
            }
        }
        for field in ListField.allCases where !view.list(field).isEmpty {
            let elements = view.list(field).map { AppleListElement(label: $0.label, value: $0.value) }
            edits.append(.list(field.apple, elements))
        }
        if let body = view.body, !body.isEmpty { edits.append(.note(body)) }
        if let imageData { edits.append(.image(imageData)) }
        return edits
    }

    /// Groups (in `containerID`) for a note's managed tags.
    func groupIDs(for tags: [String], containerID: String) -> [String] {
        tags.compactMap { tag in
            let names = Set(config.groups.filter { ComparisonKeys.tag($0.tag) == tag }.map(\.group))
            return groups.first { names.contains($0.name) && $0.containerID == containerID }?.id
        }
    }
}

extension ViewBuilder {
    /// The comparison key of an Apple value in a list field (same keys as the views).
    func key(of value: AppleValue, label: String?, field: ListField) -> String {
        switch (field, value) {
        case (.emails, .text(let text)): Keys.email(text)
        case (.phones, .text(let text)): ComparisonKeys.phone(text, keyer: keyer)
        case (.urls, .text(let text)): ComparisonKeys.url(text)
        case (.social, .social(let handle)): Keys.social(Labeled(label, handle))
        case (.im, .im(let handle)): Keys.im(Labeled(label, handle))
        case (.addresses, .address(let address)): ComparisonKeys.address(address)
        case (.dates, .date(let date)): date.iso
        case (.relationships, .relation(let name, let type, let label)):
            relation(RelationshipRef(type: type, label: label, target: .name(name)), index: nil)?.key ?? ""
        default: ""
        }
    }
}

/// The writes of one record, card by card.
private struct RecordWrites {
    typealias Output = AppleWritePlanner.Output

    let planner: AppleWritePlanner
    let record: UUID
    let contact: AppleContact
    let target: AppleCard
    let writable: [AppleCard]
    let views: [String: FieldView]
    var index: UnapplyableIndex
    var edits: [String: [CardEdit]] = [:]
    var lists: [String: [ListField: [AppleListElement]]] = [:]
    var output = Output()

    init(planner: AppleWritePlanner, record: UUID, contact: AppleContact, target: AppleCard, index: UnapplyableIndex) {
        self.planner = planner
        self.record = record
        self.contact = contact
        self.target = target
        self.index = index
        writable = contact.cards.filter { planner.writableContainers.contains($0.containerID) }
        views = Dictionary(
            writable.map { card in
                (card.id, planner.builder.apple(contact.values(of: card) ?? contact.contact, tags: [], image: .none))
            }, uniquingKeysWith: { first, _ in first })
    }

    private mutating func add(_ edit: CardEdit, to card: String, field: String) {
        edits[card, default: []].append(edit)
        noteField(field)
    }

    private mutating func noteField(_ field: String) {
        if !output.fields.contains(field) { output.fields.append(field) }
    }

    private mutating func blocks(_ card: String, _ field: String, _ attempted: String) -> Bool {
        index.blocks(record: record, card: card, field: field, attempted: attempted)
    }

    /// Single-valued fields: the target card and every other card that has a value.
    mutating func scalars(_ merge: MergeResult) {
        for field in ScalarField.allCases {
            guard let wanted = merge.appleScalars[field] else { continue }
            let key = ScalarField.key(wanted)
            for card in writable {
                let current = ScalarField.key(views[card.id]?.scalars[field])
                guard card.id == target.id || current != nil, current != key,
                    !blocks(card.id, field.rawValue, key ?? "∅")
                else { continue }
                if let apple = field.apple {
                    add(.scalar(apple, wanted), to: card.id, field: field.rawValue)
                } else {
                    add(.birthday(wanted.map(PartialDate.init(parsing:))), to: card.id, field: field.rawValue)
                }
            }
        }
    }

    /// The note (only when notes are synced; the merge produces nothing
    /// otherwise): written through to **every** writable card whose note
    /// differs, because notes are per card (spike S12) and a stale note on a
    /// linked card would otherwise surface again when precedence changes.
    mutating func body(_ merge: MergeResult) {
        guard let body = merge.appleBody else { return }
        for card in writable {
            let current = ComparisonKeys.body(contact.values(of: card)?.body)
            guard current != (body ?? ""), !blocks(card.id, "body", "text") else { continue }
            add(.note(body), to: card.id, field: "body")
        }
    }

    /// The image: the target card only, unless that card could not take
    /// this image before (Contacts.app scripting has no usable image, §6).
    mutating func image(_ merge: MergeResult, data: Data?) {
        let wanted: Data??
        switch merge.appleImage {
        case .set?: wanted = data.map { .some($0) }
        case .remove?: wanted = .some(nil)
        case nil: wanted = nil
        }
        guard let wanted, !blocks(target.id, "image", SyncExecutor.imageAttempt(wanted)) else { return }
        add(.image(wanted), to: target.id, field: "image")
    }

    // MARK: Lists

    private func elements(_ field: ListField, card: String) -> [AppleListElement] {
        if let edited = lists[card]?[field] { return edited }
        return (views[card]?.list(field) ?? []).map {
            AppleListElement(existing: $0.value, existingLabel: $0.label, label: $0.label, value: $0.value)
        }
    }

    private func key(_ element: AppleListElement, _ field: ListField) -> String {
        planner.builder.key(of: element.value, label: element.label, field: field)
    }

    /// One changed element: relabel, replace in place or remove it on every
    /// card holding it; add new elements to the target card.
    mutating func apply(_ slot: ListSlot, field: ListField) {
        var extra = slot.appleFinal
        if let apple = slot.apple {
            let holders = writable.filter { card in
                elements(field, card: card.id).contains { key($0, field) == apple.key }
            }
            let elementField = "\(field.rawValue)|\(apple.key)"
            if let kept = slot.appleFinal.first(where: { $0.key == apple.key }) {
                extra.removeAll { $0.key == apple.key }
                for card in holders where !blocks(card.id, elementField, "@\(kept.label ?? "")") {
                    update(field, card: card.id, key: apple.key) { element in
                        element.label = kept.label
                        // A relation's label lives in its value too (the adapter maps type + label).
                        if case .relation(let name, let type, _) = element.value {
                            element.value = .relation(name: name, type: type, label: kept.label)
                        }
                    }
                }
            } else if let replacement = slot.appleFinal.first {
                extra.removeFirst()
                if holders.isEmpty { extra.insert(replacement, at: 0) }
                for card in holders where !blocks(card.id, elementField, "~\(replacement.key)") {
                    update(field, card: card.id, key: apple.key) {
                        $0.label = replacement.label
                        $0.value = replacement.value
                    }
                }
            } else {
                for card in holders where !blocks(card.id, elementField, "-") {
                    lists[card.id, default: [:]][field] = elements(field, card: card.id).filter {
                        key($0, field) != apple.key
                    }
                }
            }
        }
        for element in extra {
            var list = elements(field, card: target.id)
            guard !list.contains(where: { key($0, field) == element.key }),
                !blocks(target.id, "\(field.rawValue)|\(element.key)", "+")
            else { continue }
            list.append(AppleListElement(label: element.label, value: element.value))
            lists[target.id, default: [:]][field] = list
        }
    }

    /// Relation names that still use another record's old name (§8): the
    /// name is replaced in place on every writable card holding it (same
    /// element, same key, so the merge sees no change). A card that refused
    /// the new name before is not asked again.
    mutating func renameRelations(_ renamer: RelationRenamer) {
        for card in writable {
            var list = elements(.relationships, card: card.id)
            var changed = false
            for position in list.indices {
                guard case .relation(let name, let type, let label) = list[position].value,
                    let newName = renamer.newName(for: name),
                    !blocks(
                        card.id, "relationships|\(key(list[position], .relationships))",
                        "=\(ComparisonKeys.name(newName))")
                else { continue }
                list[position].value = .relation(name: newName, type: type, label: label)
                changed = true
            }
            if changed { lists[card.id, default: [:]][.relationships] = list }
        }
    }

    private mutating func update(
        _ field: ListField, card: String, key wanted: String, _ change: (inout AppleListElement) -> Void
    ) {
        var list = elements(field, card: card)
        for position in list.indices where key(list[position], field) == wanted { change(&list[position]) }
        lists[card, default: [:]][field] = list
    }

    // MARK: Groups (managed tags)

    mutating func groups(_ merge: MergeResult) {
        let config = planner.config
        let groupCards = contact.cardsByPrecedence.filter {
            $0.accountKind.supportsGroups && planner.writableContainers.contains($0.containerID)
        }
        func names(_ tag: String) -> Set<String> {
            Set(config.groups.filter { ComparisonKeys.tag($0.tag) == tag }.map(\.group))
        }
        for tag in merge.appleTagsAdded {
            let candidates = planner.groups.filter { names(tag).contains($0.name) }
            let placement = groupCards.lazy.compactMap { card in
                candidates.first { $0.containerID == card.containerID }.map { (card, $0) }
            }.first
            guard let (card, group) = placement else {
                if !blocks("*", "tags|\(tag)", "+") {
                    output.blocked.append("tags: \(tag) (no iCloud or On My Mac card, or no such group there)")
                    output.newUnapplyable.append(
                        UnapplyableEntry(
                            recordID: record, cardID: "*", field: "tags|\(tag)", attempted: "+", observed: "absent"))
                }
                continue
            }
            output.operations.append(.addMember(cardID: card.id, groupID: group.id))
            noteField("tags")
        }
        for tag in merge.appleTagsRemoved where !blocks("*", "tags|\(tag)", "-") {
            for group in planner.groups where names(tag).contains(group.name) && contact.groupIDs.contains(group.id) {
                for card in groupCards where card.containerID == group.containerID {
                    output.operations.append(.removeMember(cardID: card.id, groupID: group.id))
                }
            }
            noteField("tags")
        }
    }

    /// Card updates (in card order) before group changes.
    mutating func finish() -> Output {
        for (cardID, fields) in lists {
            for (field, elements) in fields.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                add(.list(field.apple, elements), to: cardID, field: field.rawValue)
            }
        }
        let updates = contact.cards.compactMap { card in
            edits[card.id].map { AppleWriteOperation.update(cardID: card.id, edits: $0) }
        }
        output.operations = updates + output.operations
        return output
    }
}
