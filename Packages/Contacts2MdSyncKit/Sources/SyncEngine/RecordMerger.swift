internal import ContactModel
internal import Foundation

/// A scalar write Apple did not keep (architecture §9 "Unapplyable fields"):
/// after we wrote `attempted`, the card reads back `observed`. While Apple
/// still shows `observed`, it counts as `attempted`, so the field is neither
/// rewritten nor raised as a conflict.
struct ScalarAlias: Hashable, Sendable {
    var attempted: String?
    var observed: String?
}

/// One list element's merge unit: a base element (with what each side did
/// to it), or an element added on one or both sides.
struct ListSlot: Sendable {
    /// Base key (or the added key for additions).
    var id: String
    var base: (key: String, label: BaseLabel)?
    /// The Apple element in this slot now (the base element, or its edit).
    var apple: MergeElement?
    /// The markdown element in this slot now.
    var markdown: MergeElement?
    /// What Apple should hold after the run.
    var appleFinal: [MergeElement] = []
    /// What the note should hold after the run.
    var markdownFinal: [MergeElement] = []

    /// Apple must change.
    var changesApple: Bool { !Self.same(apple.map { [$0] } ?? [], appleFinal) }
    /// The note must change.
    var changesMarkdown: Bool { !Self.same(markdown.map { [$0] } ?? [], markdownFinal) }

    static func same(_ lhs: [MergeElement], _ rhs: [MergeElement]) -> Bool {
        lhs.map { "\($0.key)|\($0.label ?? "")" } == rhs.map { "\($0.key)|\($0.label ?? "")" }
    }
}

/// What to do with the image on one side.
enum ImageChange: Hashable, Sendable {
    /// Take the other side's image (hash).
    case set(String)
    case remove
}

/// The result of merging one record (architecture §7).
struct MergeResult: Sendable {
    /// Scalars the note must change to (`nil` = clear).
    var markdownScalars: [ScalarField: String?] = [:]
    /// Scalars Apple must change to.
    var appleScalars: [ScalarField: String?] = [:]
    var lists: [ListField: [ListSlot]] = [:]
    /// Final managed tags for the note, when they change.
    var markdownTags: [String]?
    var appleTagsAdded: [String] = []
    var appleTagsRemoved: [String] = []
    /// New note body (comparison form) for the note / for Apple.
    var markdownBody: String??
    var appleBody: String??
    var markdownImage: ImageChange?
    var appleImage: ImageChange?
    var conflicts: [SyncConflict] = []
    /// Changed fields per side, for output.
    var markdownFields: [String] = []
    var appleFields: [String] = []

    var changesApple: Bool {
        !appleScalars.isEmpty || lists.values.contains { $0.contains(where: \.changesApple) }
            || !appleTagsAdded.isEmpty || !appleTagsRemoved.isEmpty || appleBody != nil || appleImage != nil
    }
}

/// Merges one record's Apple side and note against their base, field by
/// field (architecture §7 table). Pure: no I/O. Lists are merged in
/// `RecordMerger+Lists.swift`; tags, body and image in `RecordMerger+Content.swift`.
struct RecordMerger {
    let recordID: UUID
    let title: String
    let path: String
    let base: BaseView
    let apple: FieldView
    let markdown: FieldView
    /// A recorded resolution for a conflict id.
    let resolution: (String) -> ConflictDecision?
    /// Unapplyable scalar writes by field name.
    let aliases: [String: ScalarAlias]

    var result = MergeResult()

    init(
        recordID: UUID, title: String, path: String, base: BaseView, apple: FieldView, markdown: FieldView,
        resolution: @escaping (String) -> ConflictDecision? = { _ in nil },
        aliases: [String: ScalarAlias] = [:]
    ) {
        self.recordID = recordID
        self.title = title
        self.path = path
        self.base = base
        self.apple = apple
        self.markdown = markdown
        self.resolution = resolution
        self.aliases = aliases
    }

    /// Runs the merge.
    static func merge(_ merger: RecordMerger) -> MergeResult {
        var merger = merger
        for field in ScalarField.allCases { merger.mergeScalar(field) }
        for field in ListField.allCases { merger.mergeList(field) }
        merger.mergeTags()
        merger.mergeBody()
        merger.mergeImage()
        return merger.result
    }

    // MARK: - Direction (scalars, body, image)

    /// What a single-valued field needs.
    enum Direction: Equatable {
        case inSync
        /// Markdown changed: write it to Apple.
        case push
        /// Apple changed: write it to the note.
        case pull
        case conflict
    }

    /// The §7 rule for a single value: equal keys are in sync; with a base,
    /// the side still equal to it is the one that did not change; without a
    /// base (first bind), an empty side takes the other's value.
    static func direction(
        apple: String?, markdown: String?, base: BaseScalar, appleEmpty: Bool, markdownEmpty: Bool
    ) -> Direction {
        if apple == markdown { return .inSync }
        switch base {
        case .known(let key):
            if apple == key { return .push }
            if markdown == key { return .pull }
        case .unknown:
            if appleEmpty { return .push }
            if markdownEmpty { return .pull }
        }
        return .conflict
    }

    // MARK: - Conflicts

    /// One conflict to raise (or to find resolved).
    struct ConflictSpec {
        var field: String
        /// Slot within the field (`""` for scalars).
        var slot = ""
        var element: String?
        var base: ConflictSide?
        var apple: ConflictSide
        var markdown: ConflictSide
        /// Comparison state of each side (hashed into the side hashes).
        var appleState: String
        var markdownState: String
        var options: [ConflictResolution]
    }

    /// Records a conflict, or returns the recorded resolution when both side
    /// hashes still match.
    mutating func conflict(_ spec: ConflictSpec) -> ConflictResolution? {
        let id = SyncConflict.makeID(record: recordID, field: spec.field, slot: spec.slot)
        let appleHash = SyncConflict.sideHash(spec.appleState)
        let markdownHash = SyncConflict.sideHash(spec.markdownState)
        if let decided = resolution(id), decided.appleHash == appleHash, decided.markdownHash == markdownHash,
            let choice = ConflictResolution(rawValue: decided.choice), spec.options.contains(choice)
        {
            return choice
        }
        result.conflicts.append(
            SyncConflict(
                id: id, recordID: recordID, title: title, path: path, field: spec.field, element: spec.element,
                base: spec.base, apple: spec.apple, markdown: spec.markdown, options: spec.options,
                appleHash: appleHash, markdownHash: markdownHash))
        return nil
    }

    mutating func noteMarkdown(_ field: String) {
        if !result.markdownFields.contains(field) { result.markdownFields.append(field) }
    }

    mutating func noteApple(_ field: String) {
        if !result.appleFields.contains(field) { result.appleFields.append(field) }
    }

    // MARK: - Scalars

    mutating func mergeScalar(_ field: ScalarField) {
        let appleValue = apple.scalars[field]
        let markdownValue = markdown.scalars[field]
        var appleKey = ScalarField.key(appleValue)
        let markdownKey = ScalarField.key(markdownValue)
        if let alias = aliases[field.rawValue], alias.observed == appleKey { appleKey = alias.attempted }
        var direction = Self.direction(
            apple: appleKey, markdown: markdownKey, base: base.scalar(field), appleEmpty: appleKey == nil,
            markdownEmpty: markdownKey == nil)
        if direction == .conflict {
            let baseSide: ConflictSide? =
                if case .known(let key) = base.scalar(field) { ConflictSide(value: key) } else { nil }
            let choice = conflict(
                ConflictSpec(
                    field: field.rawValue, base: baseSide, apple: ConflictSide(value: appleValue),
                    markdown: ConflictSide(value: markdownValue), appleState: appleKey ?? "∅",
                    markdownState: markdownKey ?? "∅", options: [.keepApple, .keepMarkdown]))
            direction = choice == .keepApple ? .pull : choice == .keepMarkdown ? .push : .conflict
        }
        switch direction {
        case .push:
            result.appleScalars[field] = .some(markdownValue)
            noteApple(field.rawValue)
        case .pull:
            result.markdownScalars[field] = .some(appleValue)
            noteMarkdown(field.rawValue)
        case .inSync, .conflict:
            break
        }
    }
}
