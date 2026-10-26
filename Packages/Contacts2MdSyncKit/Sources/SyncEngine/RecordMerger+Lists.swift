internal import ContactModel
internal import Foundation

/// Multi-value fields, merged element-wise by comparison key (architecture §7).
extension RecordMerger {
    enum SideState: Equatable {
        case removed
        /// Same key; `relabeled` when the label differs from a known base label.
        case kept(relabeled: Bool)
        case edited
    }

    mutating func mergeList(_ field: ListField) {
        let baseList = base.list(field)
        var slots: [ListSlot] = baseList.elements.keys.sorted().map { key in
            ListSlot(id: key, base: (key, baseList.elements[key]?.label ?? .unknown))
        }
        var index = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($0.element.id, $0.offset) })
        var appleAdded: [MergeElement] = []
        var markdownAdded: [MergeElement] = []
        for element in Self.unique(apple.list(field)) {
            if let slot = index[element.key] { slots[slot].apple = element } else { appleAdded.append(element) }
        }
        for element in Self.unique(markdown.list(field)) {
            if let slot = index[element.key] { slots[slot].markdown = element } else { markdownAdded.append(element) }
        }
        Self.pairEdits(&slots, &appleAdded, side: \.apple, field: field)
        Self.pairEdits(&slots, &markdownAdded, side: \.markdown, field: field)
        for element in appleAdded {
            index[element.key] = slots.count
            slots.append(ListSlot(id: element.key, apple: element))
        }
        for element in markdownAdded {
            if let slot = index[element.key], slots[slot].base == nil, slots[slot].markdown == nil {
                slots[slot].markdown = element
            } else {
                index[element.key] = slots.count
                slots.append(ListSlot(id: element.key, markdown: element))
            }
        }
        for slot in slots.indices { decide(&slots[slot], field: field) }
        if slots.contains(where: \.changesMarkdown) { noteMarkdown(field.rawValue) }
        if slots.contains(where: \.changesApple) { noteApple(field.rawValue) }
        result.lists[field] = slots
    }

    /// First element per key (a side never holds one key twice for merging).
    private static func unique(_ elements: [MergeElement]) -> [MergeElement] {
        var seen = Set<String>()
        return elements.filter { seen.insert($0.key).inserted }
    }

    /// An element removed from the base and one added on the same side are
    /// one edit when their labels match, or — when the base label is unknown
    /// (an M2 base) — when they are the only removed/added pair. A removal
    /// plus an addition with another label stays a delete and an add.
    ///
    /// Relationships (key `type|target`, label usually none) pair only
    /// within one relationship type, so `spouse Mara` → `[[Mara
    /// Quill]]` is one edit and is never paired with `child Cora` → `[[Cora
    /// Quill]]` just because both have no label. A type change (`sibling` →
    /// `child`, same target) pairs by target instead.
    private static func pairEdits(
        _ slots: inout [ListSlot], _ added: inout [MergeElement], side: WritableKeyPath<ListSlot, MergeElement?>,
        field: ListField
    ) {
        var removed = slots.indices.filter { slots[$0].base != nil && slots[$0][keyPath: side] == nil }
        if field == .relationships {
            pairRelations(&slots, &added, removed: removed, side: side)
            return
        }
        for slot in removed {
            guard case .known(let label)? = slots[slot].base?.label,
                let match = added.firstIndex(where: { $0.label == label })
            else { continue }
            slots[slot][keyPath: side] = added.remove(at: match)
        }
        removed = removed.filter { slots[$0][keyPath: side] == nil }
        if removed.count == 1, added.count == 1, slots[removed[0]].base?.label == .unknown {
            slots[removed[0]][keyPath: side] = added.removeFirst()
        }
    }

    /// The relationship type and target of a relationship element key (`type|r:<id>`, `type|n:<name>`).
    static func relationParts(_ key: String) -> (type: Substring, target: Substring) {
        guard let bar = key.firstIndex(of: "|") else { return (Substring(key), "") }
        return (key[..<bar], key[key.index(after: bar)...])
    }

    /// Relationship edits: same type and label first (a new target), then
    /// same target and label (a new type). Nothing else pairs.
    private static func pairRelations(
        _ slots: inout [ListSlot], _ added: inout [MergeElement], removed: [Int],
        side: WritableKeyPath<ListSlot, MergeElement?>
    ) {
        let sameType = { (lhs: String, rhs: String) in relationParts(lhs).type == relationParts(rhs).type }
        let sameTarget = { (lhs: String, rhs: String) in relationParts(lhs).target == relationParts(rhs).target }
        for matches in [sameType, sameTarget] {
            for slot in removed where slots[slot][keyPath: side] == nil {
                guard let base = slots[slot].base, case .known(let label) = base.label,
                    let index = added.firstIndex(where: { $0.label == label && matches(base.key, $0.key) })
                else { continue }
                slots[slot][keyPath: side] = added.remove(at: index)
            }
        }
    }

    private func state(_ element: MergeElement?, base: (key: String, label: BaseLabel)) -> SideState {
        guard let element else { return .removed }
        guard element.key == base.key else { return .edited }
        if case .known(let label) = base.label { return .kept(relabeled: element.label != label) }
        return .kept(relabeled: false)
    }

    private mutating func decide(_ slot: inout ListSlot, field: ListField) {
        slot.appleFinal = slot.apple.map { [$0] } ?? []
        slot.markdownFinal = slot.markdown.map { [$0] } ?? []
        if let base = slot.base {
            decideBase(&slot, base: base, field: field)
        } else {
            decideAddition(&slot, field: field)
        }
    }

    /// Added on one side: union. Added on both (same key): labels must agree.
    private mutating func decideAddition(_ slot: inout ListSlot, field: ListField) {
        switch (slot.apple, slot.markdown) {
        case (let apple?, let markdown?):
            if apple.label != markdown.label { labelConflict(&slot, field: field, baseLabel: .unknown) }
        case (let apple?, nil): slot.markdownFinal = [apple]
        case (nil, let markdown?): slot.appleFinal = [markdown]
        case (nil, nil): break
        }
    }

    /// A base element: what each side did to it (kept, relabeled, edited, removed).
    private mutating func decideBase(_ slot: inout ListSlot, base: (key: String, label: BaseLabel), field: ListField) {
        let (appleElement, markdownElement) = (slot.apple, slot.markdown)
        switch (state(appleElement, base: base), state(markdownElement, base: base)) {
        case (.kept, .kept):
            mergeLabels(&slot, baseLabel: base.label, field: field)
        case (.removed, .removed):
            break
        case (.kept(relabeled: false), .removed), (.removed, .kept(relabeled: false)):
            slot.appleFinal = []
            slot.markdownFinal = []
        case (.edited, .kept(relabeled: false)):
            slot.markdownFinal = slot.appleFinal
        case (.kept(relabeled: false), .edited):
            slot.appleFinal = slot.markdownFinal
        case (.edited, .edited) where appleElement?.key == markdownElement?.key:
            if appleElement?.label != markdownElement?.label {
                labelConflict(&slot, field: field, baseLabel: base.label)
            }
        default:
            if settlesWithoutConflict(&slot, base: base, field: field) { return }
            let both = appleElement != nil && markdownElement != nil
            elementConflict(&slot, field: field, options: both ? [.keepApple, .keepMarkdown, .keepBoth] : nil)
        }
    }

    /// Deletes and edits that are not a real conflict:
    ///
    /// - **A value we could not write.** Apple lost a base element after we
    ///   tried to change it (an unapplyable `~<new key>` replace or
    ///   `@<label>` relabel: e.g. a scripted write removed it but could not
    ///   add the replacement). That is Apple *unchanged* — a value Contacts
    ///   could not take — never an Apple deletion: markdown wins locally,
    ///   and the write planner does not retry what the card refused.
    /// - **Relationships.** The element key is (type, target), so an edit
    ///   re-points the relation (a new target or type): a relation the
    ///   other side never had. The other side's deletion (or different
    ///   edit) of the old relation says nothing about it, so the edits are
    ///   unioned like additions and the old relation is gone on both sides.
    private mutating func settlesWithoutConflict(
        _ slot: inout ListSlot, base: (key: String, label: BaseLabel), field: ListField
    ) -> Bool {
        let refusals = listRefusals["\(field.rawValue)|\(base.key)"] ?? []
        let changeRefused = refusals.contains { $0.hasPrefix("~") || $0.hasPrefix("@") }
        if slot.apple == nil, slot.markdown != nil, changeRefused {
            result.refusalsUsed.insert("\(field.rawValue)|\(base.key)")
            slot.appleFinal = slot.markdownFinal
            return true
        }
        guard field == .relationships else { return false }
        var both: [MergeElement] = []
        for element in [slot.markdown, slot.apple].compactMap({ $0 })
        where !both.contains(where: { $0.key == element.key }) {
            both.append(element)
        }
        slot.appleFinal = both
        slot.markdownFinal = both
        return true
    }

    /// Same element on both sides: the label changed on one side wins.
    private mutating func mergeLabels(_ slot: inout ListSlot, baseLabel: BaseLabel, field: ListField) {
        guard let apple = slot.apple, let markdown = slot.markdown, apple.label != markdown.label else { return }
        if case .known(let label) = baseLabel {
            if apple.label == label {
                slot.appleFinal = [Self.relabel(apple, markdown.label)]
                return
            }
            if markdown.label == label {
                slot.markdownFinal = [Self.relabel(markdown, apple.label)]
                return
            }
        }
        labelConflict(&slot, field: field, baseLabel: baseLabel)
    }

    private static func relabel(_ element: MergeElement, _ label: String?) -> MergeElement {
        var copy = element
        copy.label = label
        return copy
    }

    private static func side(_ element: MergeElement?) -> ConflictSide {
        ConflictSide(value: element?.display, label: element?.label)
    }

    private static func state(_ element: MergeElement?) -> String {
        element.map { "\($0.key)|\($0.label ?? "")" } ?? "∅"
    }

    private func baseSide(_ slot: ListSlot, field: ListField) -> ConflictSide? {
        guard let base = slot.base else { return nil }
        let label: String? = if case .known(let label) = base.label { label } else { nil }
        let display = self.base.list(field).elements[base.key]?.display ?? base.key
        return ConflictSide(value: display, label: label)
    }

    private func elementName(_ slot: ListSlot) -> String? {
        let elements = [slot.markdown, slot.apple].compactMap { $0 }
        return elements.lazy.compactMap(\.label).first ?? elements.first?.display ?? slot.base?.key
    }

    /// Delete-vs-edit or edited-differently: both sides keep theirs until resolved.
    private mutating func elementConflict(
        _ slot: inout ListSlot, field: ListField, options: [ConflictResolution]?
    ) {
        let choice = conflict(
            ConflictSpec(
                field: field.rawValue, slot: slot.id, element: elementName(slot), base: baseSide(slot, field: field),
                apple: Self.side(slot.apple), markdown: Self.side(slot.markdown), appleState: Self.state(slot.apple),
                markdownState: Self.state(slot.markdown), options: options ?? [.keepApple, .keepMarkdown]))
        switch choice {
        case .keepApple?: slot.markdownFinal = slot.appleFinal
        case .keepMarkdown?: slot.appleFinal = slot.markdownFinal
        case .keepBoth?:
            let both = [slot.apple, slot.markdown].compactMap { $0 }
            slot.appleFinal = both
            slot.markdownFinal = both
        case nil: break
        }
    }

    /// Same element, labels changed differently (or no base label).
    private mutating func labelConflict(_ slot: inout ListSlot, field: ListField, baseLabel: BaseLabel) {
        guard let apple = slot.apple, let markdown = slot.markdown else { return }
        let choice = conflict(
            ConflictSpec(
                field: field.rawValue, slot: slot.id + "#label", element: markdown.display,
                base: baseSide(slot, field: field), apple: Self.side(apple), markdown: Self.side(markdown),
                appleState: Self.state(apple), markdownState: Self.state(markdown),
                options: [.keepApple, .keepMarkdown]))
        switch choice {
        case .keepApple?: slot.markdownFinal = [Self.relabel(markdown, apple.label)]
        case .keepMarkdown?: slot.appleFinal = [Self.relabel(apple, markdown.label)]
        case .keepBoth?, nil: break
        }
    }
}
