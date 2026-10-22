internal import ContactModel
internal import Foundation

/// An Apple group renamed or deleted in Contacts since this device's last
/// executed run (architecture §8): a rename renames the managed tag in the
/// config's `groups:` map and in synced notes; a deletion leaves the tag in
/// the notes, no longer managed.
public struct GroupChange: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case renamed
        case deleted
    }

    public var kind: Kind
    /// The group's name before (renamed) or when it was last seen (deleted).
    public var group: String
    /// The new name (renamed).
    public var newGroup: String?
    /// The managed tag before.
    public var tag: String
    /// The managed tag now (renamed; equal to `tag` for a custom tag that is kept).
    public var newTag: String?

    /// Creates a change.
    public init(kind: Kind, group: String, newGroup: String? = nil, tag: String, newTag: String? = nil) {
        self.kind = kind
        self.group = group
        self.newGroup = newGroup
        self.tag = tag
        self.newTag = newTag
    }

    /// One line for output and Activity.
    public var summary: String {
        switch kind {
        case .renamed:
            let renamedTag = newTag.map { $0 == tag ? "tag \(tag) kept" : "tag \(tag) → \($0)" } ?? "tag \(tag)"
            return "group \"\(group)\" renamed to \"\(newGroup ?? "")\" in Contacts; \(renamedTag)"
        case .deleted:
            return "group \"\(group)\" was deleted in Contacts; tag \(tag) is no longer managed (left in notes)"
        }
    }
}

extension GroupBinding {
    /// This device's view of the snapshot's groups, with their managed tags.
    static func bindings(_ groups: [AppleGroup], config: VaultConfig) -> [GroupBinding] {
        groups.map {
            GroupBinding(groupID: $0.id, containerID: $0.containerID, name: $0.name, tag: config.tag(forGroup: $0.name))
        }
    }
}

extension SyncStateStore {
    /// Groups as of an executed run, so the next one recognises renames and
    /// deletions by CN id (§8); kept as they were when the config failed to write.
    func saveGroups(after plan: SyncPlan, result: SyncResult) throws {
        guard let context = plan.context, !result.markdown.failures.contains(where: { $0.path == VaultConfig.path })
        else { return }
        try saveGroups(GroupBinding.bindings(context.groups, config: plan.markdown.config))
    }
}
