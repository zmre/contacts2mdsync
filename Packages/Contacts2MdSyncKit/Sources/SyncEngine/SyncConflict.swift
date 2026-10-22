public import Foundation

/// One side of a field conflict, for display.
public struct ConflictSide: Codable, Hashable, Sendable {
    /// The value as shown (`nil` = absent: deleted on that side).
    public var value: String?
    /// The element label (multi-value fields).
    public var label: String?
    /// The whole text when `value` is only a preview (note bodies), for a
    /// line-by-line comparison.
    public var text: String?

    /// Creates a side.
    public init(value: String?, label: String? = nil, text: String? = nil) {
        self.value = value
        self.label = label
        self.text = text
    }

    /// `"value"` / `label: "value"` / `(absent)`.
    public var display: String {
        guard let value else { return "(absent)" }
        let quoted = "\"\(value)\""
        return label.map { "\($0): \(quoted)" } ?? quoted
    }
}

/// How a conflict can be resolved.
public enum ConflictResolution: String, Codable, Hashable, Sendable, CaseIterable {
    /// Keep the Contacts value (the note follows).
    case keepApple = "apple"
    /// Keep the markdown value (Contacts follows).
    case keepMarkdown = "markdown"
    /// Keep both (list elements: both values; body: markdown, `---`, Apple).
    case keepBoth = "both"
}

/// A field (or list element) changed differently on both sides since the
/// last sync (architecture §7). It never blocks the record's other fields;
/// both sides keep their own value until it is resolved. A resolution is
/// recorded as a decision bound to both side hashes and applied on the next
/// run only if both still match; otherwise the conflict is raised again.
public struct SyncConflict: Codable, Hashable, Sendable, Identifiable {
    /// Stable id (`conflict-<10 hex>`) from record, field and element, so a
    /// decision made in one run finds the conflict in the next.
    public var id: String
    public var recordID: UUID
    /// Note title, for display.
    public var title: String
    /// Note path.
    public var path: String
    /// Markdown field (`job_title`, `phones`, `body`, …).
    public var field: String
    /// Element of a multi-value field (its label, else its value).
    public var element: String?
    /// The last agreed value (`nil`: no base).
    public var base: ConflictSide?
    public var apple: ConflictSide
    public var markdown: ConflictSide
    public var options: [ConflictResolution]
    /// Hash of the Apple side's state for this field/element.
    public var appleHash: String
    /// Hash of the markdown side's state.
    public var markdownHash: String

    /// Creates a conflict.
    public init(
        id: String, recordID: UUID, title: String, path: String, field: String, element: String?,
        base: ConflictSide?, apple: ConflictSide, markdown: ConflictSide, options: [ConflictResolution],
        appleHash: String, markdownHash: String
    ) {
        self.id = id
        self.recordID = recordID
        self.title = title
        self.path = path
        self.field = field
        self.element = element
        self.base = base
        self.apple = apple
        self.markdown = markdown
        self.options = options
        self.appleHash = appleHash
        self.markdownHash = markdownHash
    }

    /// `phones[mobile]`, `job_title`.
    public var fieldPath: String { element.map { "\(field)[\($0)]" } ?? field }

    /// `Jane Doe: phones[mobile] differs (Contacts "…" vs Markdown "…")`.
    public var summary: String {
        "\(title): \(fieldPath) differs (Contacts \(apple.display) vs Markdown \(markdown.display))"
    }

    /// The stable id for a record/field/slot.
    static func makeID(record: UUID, field: String, slot: String) -> String {
        let basis = "\(record.uuidString.lowercased())|\(field)|\(slot)"
        return "conflict-" + String(hexSHA256(Data(basis.utf8)).prefix(10))
    }

    /// Short hash of one side's state.
    static func sideHash(_ text: String) -> String { String(hexSHA256(Data(text.utf8)).prefix(16)) }
}
