internal import ContactModel
internal import Foundation

/// Managed tags (set merge), the note body (diff3) and the image (by hash).
extension RecordMerger {
    // MARK: - Tags (managed only): three-way set merge, never a conflict

    mutating func mergeTags() {
        let appleTags = Set(apple.tags)
        let markdownTags = Set(markdown.tags)
        guard appleTags != markdownTags else { return }
        let all = appleTags.union(markdownTags)
        let final = all.filter { tag in
            guard let base = base.tags else { return true }
            return base.contains(tag) ? appleTags.contains(tag) && markdownTags.contains(tag) : true
        }
        if final != markdownTags {
            let additions = apple.tags.filter { final.contains($0) && !markdownTags.contains($0) }
            result.markdownTags = markdown.tags.filter(final.contains) + additions
            noteMarkdown("tags")
        }
        result.appleTagsAdded = markdown.tags.filter { final.contains($0) && !appleTags.contains($0) }
        result.appleTagsRemoved = apple.tags.filter { !final.contains($0) }
        if !result.appleTagsAdded.isEmpty || !result.appleTagsRemoved.isEmpty { noteApple("tags") }
    }

    // MARK: - Body: line-based diff3

    private mutating func setBody(_ text: String, apple toApple: Bool, markdown toMarkdown: Bool) {
        let value: String? = text.isEmpty ? nil : text
        if toApple {
            result.appleBody = .some(value)
            noteApple("body")
        }
        if toMarkdown {
            result.markdownBody = .some(value)
            noteMarkdown("body")
        }
    }

    mutating func mergeBody() {
        guard let appleBody = apple.body, let markdownBody = markdown.body else { return }
        let baseBody: BaseScalar =
            switch base.body {
            case .known(let text): .known(text ?? "")
            case .unknown: .unknown
            }
        switch Self.direction(
            apple: appleBody, markdown: markdownBody, base: baseBody, appleEmpty: appleBody.isEmpty,
            markdownEmpty: markdownBody.isEmpty)
        {
        case .inSync: return
        case .push: return setBody(markdownBody, apple: true, markdown: false)
        case .pull: return setBody(appleBody, apple: false, markdown: true)
        case .conflict: bodyConflict(apple: appleBody, markdown: markdownBody, base: baseBody)
        }
    }

    /// Both bodies changed: diff3 when the hunks do not overlap, else a conflict.
    private mutating func bodyConflict(apple appleBody: String, markdown markdownBody: String, base: BaseScalar) {
        var baseText: String?
        if case .known(let text) = base {
            baseText = text
            if let text, let merged = Diff3.merge(base: text, apple: appleBody, markdown: markdownBody) {
                return setBody(merged, apple: true, markdown: true)
            }
        }
        let choice = conflict(
            ConflictSpec(
                field: "body", base: baseText.map { ConflictSide(value: Self.preview($0), text: $0) },
                apple: ConflictSide(value: Self.preview(appleBody), text: appleBody),
                markdown: ConflictSide(value: Self.preview(markdownBody), text: markdownBody), appleState: appleBody,
                markdownState: markdownBody, options: [.keepApple, .keepMarkdown, .keepBoth]))
        switch choice {
        case .keepApple?: setBody(appleBody, apple: false, markdown: true)
        case .keepMarkdown?: setBody(markdownBody, apple: true, markdown: false)
        case .keepBoth?: setBody(markdownBody + "\n\n---\n\n" + appleBody, apple: true, markdown: true)
        case nil: break
        }
    }

    /// The first line of a body, with a line count when longer.
    static func preview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        return lines.count > 1 ? "\(first) … (\(lines.count) lines)" : first
    }

    // MARK: - Image: by hash

    mutating func mergeImage() {
        let appleImage = apple.image
        let markdownImage = markdown.image
        guard appleImage != .unknown, markdownImage != .unknown else { return }
        var direction = Self.direction(
            apple: appleImage.hash, markdown: markdownImage.hash, base: base.image, appleEmpty: appleImage == .none,
            markdownEmpty: markdownImage == .none)
        if direction == .conflict {
            let describe = { (hash: String?) in hash.map { "image \(String($0.prefix(8)))" } }
            let baseSide: ConflictSide? =
                if case .known(let hash) = base.image { ConflictSide(value: describe(hash)) } else { nil }
            let choice = conflict(
                ConflictSpec(
                    field: "image", base: baseSide, apple: ConflictSide(value: describe(appleImage.hash)),
                    markdown: ConflictSide(value: describe(markdownImage.hash)), appleState: appleImage.hash ?? "∅",
                    markdownState: markdownImage.hash ?? "∅", options: [.keepApple, .keepMarkdown]))
            direction = choice == .keepApple ? .pull : choice == .keepMarkdown ? .push : .conflict
        }
        switch direction {
        case .push:
            result.appleImage = markdownImage.hash.map(ImageChange.set) ?? .remove
            noteApple("image")
        case .pull:
            result.markdownImage = appleImage.hash.map(ImageChange.set) ?? .remove
            noteMarkdown("image")
        case .inSync, .conflict:
            break
        }
    }
}
