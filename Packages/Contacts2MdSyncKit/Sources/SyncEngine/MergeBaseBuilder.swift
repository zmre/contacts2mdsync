internal import ContactModel
internal import Foundation

/// Builds the next merge base after a run (architecture §5 step 8).
///
/// The new base is what Apple (re-fetched after the writes, so server
/// normalization is absorbed) and the note (as written) **agree on**, field
/// by field and element by element. Where they still differ — a held or
/// failed write, an unresolved conflict, a value a card refused — the
/// previous base is kept, so the same change is found again next run
/// instead of being mistaken for a change on the other side.
struct MergeBaseBuilder {
    let apple: FieldView
    let markdown: FieldView
    /// Apple's values (for the generated title and name keys).
    let appleValues: CanonicalContact
    let old: BaseView
    let aliases: [String: ScalarAlias]
    let notesSynced: Bool

    private var base = RecordBase()
    private var unknown: [String] = []
    private var labels: [String: [String: String]] = [:]
    private var displays: [String: [String: String]] = [:]

    init(
        apple: FieldView, markdown: FieldView, appleValues: CanonicalContact, previous: RecordBase?,
        aliases: [String: ScalarAlias], notesSynced: Bool
    ) {
        self.apple = apple
        self.markdown = markdown
        self.appleValues = appleValues
        self.old = BaseView.of(previous)
        self.aliases = aliases
        self.notesSynced = notesSynced
    }

    /// The agreed base.
    func build() -> RecordBase {
        var builder = self
        builder.base.version = 2
        builder.scalars()
        for field in ListField.allCases { builder.list(field) }
        builder.tags()
        builder.body()
        builder.image()
        builder.base.generatedTitle = TitleGenerator.title(for: appleValues)
        let names = [MatchKeys.nameKey(appleValues), ComparisonKeys.name(TitleGenerator.title(for: appleValues))]
        builder.base.fields["name"] = Array(Set(names.compactMap { $0 })).sorted()
        builder.base.unknown = builder.unknown.isEmpty ? nil : builder.unknown.sorted()
        builder.base.labels = builder.labels.isEmpty ? nil : builder.labels
        builder.base.displays = builder.displays.isEmpty ? nil : builder.displays
        return builder.base
    }

    private mutating func scalars() {
        for field in ScalarField.allCases {
            var appleKey = ScalarField.key(apple.scalars[field])
            if let alias = aliases[field.rawValue], alias.observed == appleKey { appleKey = alias.attempted }
            let markdownKey = ScalarField.key(markdown.scalars[field])
            if appleKey == markdownKey {
                if let appleKey { base.fields[field.rawValue] = [appleKey] }
                continue
            }
            switch old.scalar(field) {
            case .known(let key): if let key { base.fields[field.rawValue] = [key] }
            case .unknown: unknown.append(field.rawValue)
            }
        }
    }

    /// Elements both sides hold; elements on one side only keep their old
    /// base membership (none when the old list had no base).
    private mutating func list(_ field: ListField) {
        let unique = { (elements: [MergeElement]) in
            Dictionary(elements.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let appleElements = unique(apple.list(field))
        let markdownElements = unique(markdown.list(field))
        let oldList = old.list(field)
        var keys: [String] = []
        for key in Set(appleElements.keys).union(markdownElements.keys).union(oldList.elements.keys) {
            let (fromApple, fromMarkdown) = (appleElements[key], markdownElements[key])
            let label: BaseLabel
            if let fromApple, let fromMarkdown {
                label =
                    fromApple.label == fromMarkdown.label
                    ? .known(fromApple.label) : (oldList.elements[key]?.label ?? .unknown)
            } else if oldList.known, let previous = oldList.elements[key] {
                label = previous.label
            } else {
                continue
            }
            keys.append(key)
            if case .known(let text) = label { labels[field.rawValue, default: [:]][key] = text ?? "" }
            if let display = fromMarkdown?.display ?? fromApple?.display ?? oldList.elements[key]?.display {
                displays[field.rawValue, default: [:]][key] = display
            }
        }
        if !keys.isEmpty { base.fields[field.rawValue] = keys.sorted() }
    }

    private mutating func tags() {
        let appleTags = Set(apple.tags)
        let markdownTags = Set(markdown.tags)
        let tags = appleTags.union(markdownTags).union(old.tags ?? []).filter { tag in
            let (inApple, inMarkdown) = (appleTags.contains(tag), markdownTags.contains(tag))
            if inApple == inMarkdown { return inApple }
            return old.tags?.contains(tag) ?? false
        }
        base.tags = tags.sorted()
        if !tags.isEmpty { base.fields["tags"] = tags.sorted() }
    }

    private mutating func body() {
        if notesSynced, let appleBody = apple.body, appleBody == markdown.body {
            base.body = appleBody.isEmpty ? nil : appleBody
        } else {
            switch old.body {
            case .known(let text): base.body = text
            case .unknown: unknown.append("body")
            }
        }
        if let text = base.body { base.fields["body"] = [FieldHash.of([text])] }
    }

    private mutating func image() {
        if apple.image != .unknown, apple.image == markdown.image {
            base.imageHash = apple.image.hash
        } else {
            switch old.image {
            case .known(let hash): base.imageHash = hash
            case .unknown: unknown.append("image")
            }
        }
        if let hash = base.imageHash { base.fields["image"] = [hash] }
    }
}
