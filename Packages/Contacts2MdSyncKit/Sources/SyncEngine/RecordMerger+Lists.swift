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
        Self.pairEdits(&slots, &appleAdded, side: \.apple)
        Self.pairEdits(&slots, &markdownAdded, side: \.markdown)
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
    private static func pairEdits(
        _ slots: inout [ListSlot], _ added: inout [MergeElement], side: WritableKeyPath<ListSlot, MergeElement?>
    ) {
        var removed = slots.indices.filter { slots[$0].base != nil && slots[$0][keyPath: side] == nil }
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
            let both = appleElement != nil && markdownElement != nil
            elementConflict(&slot, field: field, options: both ? [.keepApple, .keepMarkdown, .keepBoth] : nil)
        }
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
