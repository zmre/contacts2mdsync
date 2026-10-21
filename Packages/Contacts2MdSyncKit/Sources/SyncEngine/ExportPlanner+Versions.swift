internal import ContactModel
internal import Foundation
internal import MarkdownCodec
internal import VaultIndex

// iCloud conflict versions (`NSFileVersion`, architecture §11, M6).
//
// iCloud keeps one of two concurrent edits as a file's current contents and
// the other as an unresolved conflict version. Versions that say the same
// thing as the current contents (canonically equal) are resolved by the
// leader without asking. Otherwise the note's record is paused and a
// `fileVersionConflict` review item asks which to keep; the decision is
// bound to the current contents and the version set, so a later edit or a
// new version asks again. Resolutions are planned here and executed only by
// the leader (followers never write the vault).

extension PlanningRun {
    /// Plans resolutions or review items for every file with conflict versions.
    mutating func planVersionConflicts() {
        for entry in index.entries where !entry.conflictVersions.isEmpty && !entry.isDataless {
            planVersionConflict(
                path: entry.path, title: entry.title, recordID: entry.syncID, versions: entry.conflictVersions,
                equal: FileConflictVersion.notesAreCanonicallyEqual)
        }
        let configVersions = (try? planner.fs.unresolvedConflictVersions(VaultConfig.path)) ?? []
        if !configVersions.isEmpty {
            planVersionConflict(
                path: VaultConfig.path, title: "vault settings", recordID: nil, versions: configVersions,
                equal: Self.configsEqual)
            if plan.versionResolutions.contains(where: { $0.path == VaultConfig.path && $0.keep != nil }) {
                plan.configText = nil  // the chosen version replaces the file; group changes wait a run
            }
        }
    }

    private mutating func planVersionConflict(
        path: String, title: String, recordID: UUID?, versions: [FileConflictVersion],
        equal: (Data, Data) -> Bool
    ) {
        guard let (current, _) = try? planner.fs.read(path) else { return }
        let differing = versions.filter { !equal(current, $0.data) }.sorted { $0.sha256 < $1.sha256 }
        guard !differing.isEmpty else {
            plan.versionResolutions.append(FileVersionResolution(path: path, keep: nil, reason: "identical"))
            return
        }
        let currentSHA = FileStamp.hash(current)
        let key = FileVersionConflict.key(differing.map(\.sha256))
        if let decision = decisions.fileVersionChoice(forPath: path), decision.markdownHash == currentSHA,
            decision.appleHash == key
        {
            if let chosen = decision.version {
                if let version = differing.first(where: { $0.sha256 == chosen }) {
                    plan.versionResolutions.append(FileVersionResolution(path: path, keep: version, reason: "decision"))
                    pause(recordID, reason: "its note is replaced by the iCloud version you kept; syncs next run")
                    return
                }
            } else {
                plan.versionResolutions.append(FileVersionResolution(path: path, keep: nil, reason: "decision"))
                return
            }
        }
        let infos = differing.map { version in
            FileVersionInfo(
                sha256: version.sha256, modifiedAt: version.modificationDate, deviceName: version.deviceName,
                differences: Self.differences(current, version.data))
        }
        plan.reviews.append(
            .fileVersionConflict(
                FileVersionConflict(
                    path: path, title: title, recordID: recordID, currentSHA256: currentSHA, versions: infos)))
        pause(recordID, reason: "iCloud kept conflicting versions of its note; pick one first")
    }

    private mutating func pause(_ recordID: UUID?, reason: String) {
        guard let recordID else { return }
        pausedIDs.insert(recordID)
        pauseReasons[recordID] = reason
    }

    /// Changed contact keys between two note texts, else `text`.
    static func differences(_ current: Data, _ other: Data) -> [String] {
        guard let lhs = String(data: current, encoding: .utf8), let rhs = String(data: other, encoding: .utf8),
            let left = (try? MarkdownCodec.parse(lhs))?.contact, let right = (try? MarkdownCodec.parse(rhs))?.contact
        else { return ["text"] }
        let keys = MarkdownCodec.differingKeys(MarkdownCodec.normalize(left), MarkdownCodec.normalize(right))
        return keys.isEmpty ? ["formatting"] : keys
    }

    /// Two `config.yaml` texts with the same settings.
    static func configsEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard let left = String(data: lhs, encoding: .utf8), let right = String(data: rhs, encoding: .utf8),
            let leftConfig = try? VaultConfig.parsed(left), let rightConfig = try? VaultConfig.parsed(right)
        else { return false }
        return leftConfig == rightConfig
    }
}
