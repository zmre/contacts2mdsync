internal import ContactModel
public import Foundation
internal import MarkdownCodec
public import VaultIndex

/// One `groups:` entry: an Apple group name and the managed tag it maps to.
public struct GroupTag: Hashable, Sendable {
    public var group: String
    public var tag: String

    /// Creates an entry.
    public init(group: String, tag: String) {
        self.group = group
        self.tag = tag
    }
}

/// The shared vault configuration, `<root>/.c2mdsync/config.yaml`
/// (markdown-schema §8). M1 reads and writes the keys below; every other key
/// (`limits`, `scope`, …) is preserved byte-for-byte when the file is updated.
public struct VaultConfig: Hashable, Sendable {
    /// Root-relative location of the file.
    public static let path = ".c2mdsync/config.yaml"
    /// Current schema number.
    public static let currentSchema = 1

    public var vaultID: UUID
    public var schema: Int
    /// Folder for new notes.
    public var defaultFolder: String
    /// Folder for contact photos (visible so mbr can serve them).
    public var imagesFolder: String
    /// ISO region for phone numbers without a country code.
    public var defaultRegion: String?
    /// Apple group → managed tag, in file order.
    public var groups: [GroupTag]
    /// `scope.markdown.exclude_paths` globs: notes there are never scanned.
    /// Read-only here (the `scope:` block is preserved verbatim).
    public var excludePaths: [String] = []
    /// `apple_writes: enabled` — the master switch for every write to Apple
    /// Contacts during `sync` (field edits, groups, creates, deletes, stamps).
    /// Default disabled: sync then only writes markdown and reports Apple-side
    /// changes as held.
    public var appleWrites = false
    /// `stamp_contacts: true` — stamp each synced contact's card with its
    /// record id (`x-c2mdsync:<uuid>`). Optional: a single device identifies
    /// contacts by cached card ids. Needs `apple_writes` too. Default false.
    public var stampContacts = false
    /// `limits:` (read-only here).
    public var limits = SyncLimits()
    /// `scope:` and `on_leave_scope` (read-only here).
    public var scope = SyncScope()

    /// Creates a configuration.
    public init(
        vaultID: UUID,
        schema: Int = VaultConfig.currentSchema,
        defaultFolder: String = "Inbox",
        imagesFolder: String = "_images",
        defaultRegion: String? = nil,
        groups: [GroupTag] = []
    ) {
        self.vaultID = vaultID
        self.schema = schema
        self.defaultFolder = defaultFolder
        self.imagesFolder = imagesFolder
        self.defaultRegion = defaultRegion
        self.groups = groups
    }

    /// The managed tag for an Apple group name.
    public func tag(forGroup name: String) -> String? { groups.first { $0.group == name }?.tag }

    /// All managed tags (comparison keys).
    public var managedTagKeys: Set<String> { Set(groups.map { ComparisonKeys.tag($0.tag) }) }

    /// The tag a new Apple group gets: mbr tag normalization of its name.
    public static func defaultTag(forGroup name: String) -> String { ComparisonKeys.tag(name) }

    // MARK: - Reading and writing

    /// Errors reading the configuration.
    public enum ConfigError: Error, Hashable, Sendable, CustomStringConvertible {
        case invalid(String)

        public var description: String {
            switch self {
            case .invalid(let message): "\(VaultConfig.path): \(message)"
            }
        }
    }

    /// Loads the configuration, or `nil` when the vault has none yet.
    public static func load(from fs: any VaultFS) throws -> (config: VaultConfig, text: String)? {
        guard fs.exists(path) else { return nil }
        let (data, _) = try fs.read(path)
        guard let text = String(data: data, encoding: .utf8) else { throw ConfigError.invalid("not UTF-8") }
        return (try parsed(text), text)
    }

    /// Parses config text (`load` without the file system).
    public static func parsed(_ text: String) throws -> VaultConfig {
        guard case .mapping(let fields) = try MarkdownCodec.parseYAML(text) else {
            throw ConfigError.invalid("not a mapping")
        }
        let value = { (key: String) in fields.first { $0.key == key }?.value.scalarText }
        let flag = { (text: String?) in Self.flag(text, default: false) }
        guard let idText = value("vault_id"), let id = UUID(uuidString: idText) else {
            throw ConfigError.invalid("missing or invalid vault_id")
        }
        var config = VaultConfig(vaultID: id)
        config.schema = value("schema").flatMap(Int.init) ?? currentSchema
        config.defaultFolder = value("default_folder") ?? config.defaultFolder
        config.imagesFolder = value("images_folder") ?? config.imagesFolder
        config.defaultRegion = value("default_region")
        if case .mapping(let scope)? = fields.first(where: { $0.key == "scope" })?.value,
            case .mapping(let markdown)? = scope.first(where: { $0.key == "markdown" })?.value,
            case .sequence(let paths)? = markdown.first(where: { $0.key == "exclude_paths" })?.value
        {
            config.excludePaths = paths.compactMap(\.scalarText).filter { !$0.isEmpty }
        }
        config.appleWrites = flag(value("apple_writes"))
        config.stampContacts = flag(value("stamp_contacts"))
        if case .mapping(let limits)? = fields.first(where: { $0.key == "limits" })?.value {
            config.limits = SyncLimits(limits)
        }
        if case .mapping(let scope)? = fields.first(where: { $0.key == "scope" })?.value {
            config.scope = SyncScope(scope)
        }
        if let onLeave = value("on_leave_scope") { config.scope.onLeaveScope = onLeave }
        if case .mapping(let groups)? = fields.first(where: { $0.key == "groups" })?.value {
            config.groups = groups.compactMap { entry in
                entry.value.scalarText.map { GroupTag(group: entry.key, tag: $0) }
            }
        }
        return config
    }

    /// The file text. With `previous` (the current file), only the managed
    /// keys that changed are re-emitted; everything else is kept verbatim.
    public func render(patching previous: String? = nil) -> String {
        guard let previous, let layout = YAMLLayout(scanning: previous), let old = try? Self.parse(previous) else {
            return managedEntries.compactMap { key, value in value.map { YAMLWriter.entry(key, $0) } }.joined()
        }
        var remaining = managedEntries
        var out = ""
        for segment in layout.segments {
            switch segment {
            case .trivia(let text):
                out += text
            case .entry(let key, let text):
                guard let index = remaining.firstIndex(where: { $0.key == key }) else {
                    out += text  // unknown key (limits, scope, …): verbatim
                    continue
                }
                guard let value = remaining.remove(at: index).value else { continue }
                let same =
                    old.fieldValue(key) == value.normalizedForComparison
                    || (["apple_writes", "stamp_contacts"].contains(key)
                        && Self.flag(old.fieldValue(key)?.scalarText, default: false)
                            == Self.flag(value.scalarText, default: false))
                out += same ? text : YAMLWriter.entry(key, value)
            }
        }
        // Keys missing from the file are added only when they differ from the
        // defaults (an absent key already means the default).
        for (key, value) in remaining where !isDefault(key) {
            if let value { out += YAMLWriter.entry(key, value) }
        }
        return out
    }

    /// The keys this type manages, in file order (`nil` = omit).
    private var managedEntries: [(key: String, value: YAMLValue?)] {
        [
            ("vault_id", .scalar(vaultID.uuidString.lowercased(), plain: true)),
            ("schema", .scalar(String(schema), plain: true)),
            ("default_folder", YAMLWriter.scalar(defaultFolder)),
            ("images_folder", YAMLWriter.scalar(imagesFolder)),
            ("default_region", defaultRegion.map { YAMLWriter.scalar($0) }),
            ("groups", .mapping(groups.map { YAMLField(key: $0.group, value: YAMLWriter.scalar($0.tag)) })),
            ("apple_writes", .scalar(appleWrites ? "enabled" : "disabled", plain: true)),
            ("stamp_contacts", .scalar(stampContacts ? "true" : "false", plain: true)),
        ]
    }

    private func isDefault(_ key: String) -> Bool {
        let defaults = VaultConfig(vaultID: vaultID)
        switch key {
        case "schema": return schema == defaults.schema
        case "default_folder": return defaultFolder == defaults.defaultFolder
        case "images_folder": return imagesFolder == defaults.imagesFolder
        case "groups": return groups.isEmpty
        case "apple_writes": return !appleWrites
        case "stamp_contacts": return !stampContacts
        default: return false
        }
    }

    /// `true`/`false` for the boolean spellings YAML and humans use;
    /// `fallback` for anything else (absent, misspelled).
    static func flag(_ text: String?, default fallback: Bool) -> Bool {
        switch text?.lowercased() {
        case "enabled", "enable", "true", "yes", "on": true
        case "disabled", "disable", "false", "no", "off": false
        default: fallback
        }
    }

    private static func parse(_ text: String) throws -> [YAMLField] {
        guard case .mapping(let fields) = try MarkdownCodec.parseYAML(text) else { throw ConfigError.invalid("") }
        return fields
    }
}

extension [YAMLField] {
    fileprivate func fieldValue(_ key: String) -> YAMLValue? {
        first { $0.key == key }?.value.normalizedForComparison
    }
}

extension YAMLValue {
    /// Scalars compared by text only (quoting style ignored).
    fileprivate var normalizedForComparison: YAMLValue {
        switch self {
        case .null: .null
        case .scalar(let text, _): .scalar(text, plain: true)
        case .sequence(let items): .sequence(items.map(\.normalizedForComparison))
        case .mapping(let fields):
            .mapping(fields.map { YAMLField(key: $0.key, value: $0.value.normalizedForComparison) })
        }
    }
}
