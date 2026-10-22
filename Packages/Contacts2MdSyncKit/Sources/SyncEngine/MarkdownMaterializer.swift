internal import ContactModel
internal import Foundation

/// Applies a merge result to the existing note (architecture §7):
/// markdown order is kept, Apple additions are appended, elements equal by
/// key keep their markdown display form, and everything the merge does not
/// own (title, plain aliases, unmanaged tags, markdown-only relationship
/// types, `death` and free-text dates, unknown keys) is left as it was.
struct MarkdownMaterializer {
    let resolver: RelationResolver
    /// `company:` for an organization name (wikilink to an org note when one exists).
    let company: (_ name: String, _ existing: CompanyRef?, _ kind: ContactKind) -> CompanyRef
    /// Managed tag keys.
    let managedTagKeys: Set<String>
    /// Managed tag key → the tag text to write.
    let tagText: (String) -> String

    /// A title regenerated because Apple's name changed.
    struct Rename: Hashable, Sendable {
        var oldTitle: String
        var newTitle: String
    }

    func apply(_ merge: MergeResult, to note: CanonicalContact, base: BaseView) -> (CanonicalContact, Rename?) {
        var result = note
        result.emails = rebuild(note.emails, merge.lists[.emails], text)
        result.phones = rebuild(note.phones, merge.lists[.phones], text)
        result.urls = rebuild(note.urls, merge.lists[.urls], text)
        result.social = rebuild(note.social, merge.lists[.social]) { element in
            if case .social(let handle) = element.value { return Labeled(element.label, handle) }
            return nil
        }
        result.im = rebuild(note.im, merge.lists[.im]) { element in
            if case .im(let handle) = element.value { return Labeled(element.label, handle) }
            return nil
        }
        result.addresses = rebuild(note.addresses, merge.lists[.addresses]) { element in
            if case .address(let address) = element.value { return Labeled(element.label, address) }
            return nil
        }
        result.dates = rebuildDates(note.dates, merge.lists[.dates])
        result.relationships = rebuildRelationships(note.relationships, merge.lists[.relationships])
        // Scalars after the lists: the birthday lives in `dates` and would
        // shift the list positions the slots refer to.
        for field in ScalarField.allCases {
            if let value = merge.markdownScalars[field] { set(field, value, in: &result) }
        }
        if let tags = merge.markdownTags { result.tags = self.tags(note.tags, final: tags) }
        if let body = merge.markdownBody { result.body = body.map { Self.leadingBlankLines(note.body) + $0 + "\n" } }
        let rename = retitle(&result, original: note, merge: merge, base: base)
        return (result, rename)
    }

    /// The blank lines a body starts with (kept when the body is replaced,
    /// so the gap after the frontmatter stays as the user wrote it).
    static func leadingBlankLines(_ body: String?) -> String {
        var prefix = ""
        var rest = Substring(body ?? "")
        while let newline = rest.firstIndex(of: "\n"), rest[..<newline].allSatisfy(\.isWhitespace) {
            prefix += "\n"
            rest = rest[rest.index(after: newline)...]
        }
        return prefix
    }

    // MARK: - Scalars

    private func set(_ field: ScalarField, _ value: String?, in contact: inout CanonicalContact) {
        switch field {
        case .company:
            contact.company = value.map { company($0, contact.company, contact.kind) }
        case .birthday:
            let date = value.map(PartialDate.init(parsing:))
            if let index = contact.dates.firstIndex(where: { $0.label == "birthday" }) {
                if let date { contact.dates[index].value = date } else { contact.dates.remove(at: index) }
            } else if let date {
                contact.dates.insert(Labeled("birthday", date), at: 0)
            }
        default:
            field.apple?.set(value, in: &contact)
        }
    }

    // MARK: - Lists

    private func text(_ element: MergeElement) -> Labeled<String>? {
        if case .text(let text) = element.value { return Labeled(element.label, text) }
        return nil
    }

    /// The note's list after the merge: each original element becomes its
    /// slot's final elements (in place), then Apple-only additions follow.
    private func rebuild<Value>(
        _ original: [Labeled<Value>], _ slots: [ListSlot]?, _ convert: (MergeElement) -> Labeled<Value>?
    ) -> [Labeled<Value>] {
        guard let slots, slots.contains(where: \.changesMarkdown) else { return original }
        var byIndex: [Int: Int] = [:]
        for (slotIndex, slot) in slots.enumerated() {
            if let index = slot.markdown?.markdownIndex { byIndex[index] = slotIndex }
        }
        var result: [Labeled<Value>] = []
        var emittedKeys = Set<String>()
        var visited = Set<Int>()
        func emit(_ slotIndex: Int, original element: Labeled<Value>?) {
            let slot = slots[slotIndex]
            for final in slot.markdownFinal where emittedKeys.insert(final.key).inserted {
                if let element, let markdown = slot.markdown, markdown.key == final.key {
                    result.append(Labeled(final.label, element.value))
                } else if let converted = convert(final) {
                    result.append(converted)
                }
            }
        }
        let finalKeys = Set(slots.flatMap { $0.markdownFinal.map(\.key) })
        for (index, element) in original.enumerated() {
            if let slotIndex = byIndex[index] {
                visited.insert(slotIndex)
                emit(slotIndex, original: element)
            } else if let key = duplicateKey(index, slots: slots, original: original), !finalKeys.contains(key) {
                continue  // a duplicate of an element that was removed
            } else {
                result.append(element)
            }
        }
        for slotIndex in slots.indices where !visited.contains(slotIndex) { emit(slotIndex, original: nil) }
        return result
    }

    /// For an element no slot claimed (a second copy of a key), the key its
    /// first copy has, so it disappears with it.
    private func duplicateKey<Value>(_ index: Int, slots: [ListSlot], original: [Labeled<Value>]) -> String? {
        let element = original[index]
        for slot in slots {
            guard let markdown = slot.markdown, let first = markdown.markdownIndex, first < index else { continue }
            if original[first] == element { return markdown.key }
        }
        return nil
    }

    private func rebuildDates(_ dates: [Labeled<PartialDate>], _ slots: [ListSlot]?) -> [Labeled<PartialDate>] {
        // Slot indices count every date; non-mergeable ones (birthday, death,
        // free text) are never claimed by a slot and stay where they are.
        rebuild(dates, slots) { element in
            if case .date(let date) = element.value { return Labeled(element.label ?? "other", date) }
            return nil
        }
    }

    private func rebuildRelationships(_ refs: [RelationshipRef], _ slots: [ListSlot]?) -> [RelationshipRef] {
        guard let slots, slots.contains(where: \.changesMarkdown) else { return refs }
        let labeled = refs.map { Labeled<RelationshipRef>($0.label, $0) }
        let rebuilt = rebuild(labeled, slots) { element -> Labeled<RelationshipRef>? in
            guard case .relation(let name, let type, let label) = element.value else { return nil }
            let target: RelationshipTarget =
                resolver.record(named: name).flatMap { resolver.title(of: $0) }.map(RelationshipTarget.wikilink)
                ?? .name(name)
            return Labeled(label, RelationshipRef(type: type, label: label, target: target))
        }
        return rebuilt.map { element in
            var ref = element.value
            ref.label = element.label
            return ref
        }
    }

    // MARK: - Tags

    private func tags(_ original: [String], final: [String]) -> [String] {
        let finalKeys = Set(final)
        var kept = original.filter { tag in
            let key = ComparisonKeys.tag(tag)
            return !managedTagKeys.contains(key) || finalKeys.contains(key)
        }
        let keptKeys = Set(kept.map(ComparisonKeys.tag))
        kept += final.filter { !keptKeys.contains($0) }.map(tagText)
        return kept
    }

    // MARK: - Title (markdown-owned)

    /// Regenerates the title only when Apple's name changed this run and the
    /// title still equals the title generated last time; the old title is
    /// kept as a plain alias so `[[Old]]` links keep resolving.
    private func retitle(
        _ contact: inout CanonicalContact, original: CanonicalContact, merge: MergeResult, base: BaseView
    ) -> Rename? {
        let nameFields: Set<ScalarField> = [.firstName, .lastName, .suffix, .nickname, .company, .middleName]
        guard merge.markdownScalars.keys.contains(where: nameFields.contains) else { return nil }
        let oldTitle = original.title
        let generatedBefore: Bool
        if let previous = base.generatedTitle {
            generatedBefore = previous == oldTitle
        } else {
            generatedBefore = base.legacyNameKeys.contains(ComparisonKeys.name(oldTitle))
        }
        let newTitle = TitleGenerator.title(for: contact)
        guard generatedBefore, !oldTitle.isEmpty, newTitle != oldTitle else { return nil }
        contact.title = newTitle
        let aliasKeys = Set(contact.aliases.map { ComparisonKeys.name($0.name) })
        if !aliasKeys.contains(ComparisonKeys.name(oldTitle)) { contact.aliases.append(.plain(oldTitle)) }
        return Rename(oldTitle: oldTitle, newTitle: newTitle)
    }
}
