import Contacts2MdCLI
import Foundation
import SyncEngine

/// Counts shown in the read-only preview (onboarding step 3).
struct PreviewSummary: Sendable, Equatable {
    var contactsRead: Int
    /// Card counts per account (`iCloud 1,031`, `Google 217`, …).
    var accounts: [AccountCount]
    var groups: Int
    var matched: Int
    var toAdopt: Int
    var toCreate: Int
    var markdownOnly: Int
    var duplicates: Int
    var possibleMatches: Int
    var otherReviews: Int
    var firstExport: Bool

    init(_ prepared: PreparedExport) {
        let plan = prepared.plan
        contactsRead = plan.appleContactCount
        let kinds = prepared.snapshot.contacts.flatMap(\.cards).map(\.accountKind.displayName)
        accounts = Dictionary(grouping: kinds, by: { $0 }).map { AccountCount(name: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
        groups = plan.config.groups.count
        matched = plan.unchanged + plan.updates.filter { $0.kind == .update || $0.kind == .pathFixup }.count
        toAdopt = plan.adoptions.count
        toCreate = plan.creates.count
        markdownOnly = plan.markdownOnly
        var duplicates = 0
        var matches = 0
        for review in plan.reviews {
            switch review {
            case .duplicateCluster, .mergeRecords: duplicates += 1
            case .possibleMatch: matches += 1
            default: break
            }
        }
        self.duplicates = duplicates
        possibleMatches = matches
        otherReviews = plan.reviews.count - duplicates - matches
        firstExport = prepared.firstExport
    }
}

/// Whether the Contacts notes field is readable (needs an Apple entitlement).
enum NotesAccess: Sendable {
    case checking
    case available
    case unavailable
    case unknown

    var description: String {
        switch self {
        case .checking: "Checking…"
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }
}

/// Cards in one account kind.
struct AccountCount: Sendable, Equatable, Hashable {
    var name: String
    var count: Int
}

/// What an export run did (onboarding step 5).
struct OutcomeSummary: Sendable, Equatable {
    var created: Int
    var adopted: Int
    var updated: Int
    var contactsBackup: String?
    var notesBackup: String?
    var failures: [String]
    var pendingReview: Int

    init(_ outcome: ExportOutcome, plan: ExportPlan) {
        created = outcome.result.created.count
        adopted = outcome.result.updated.filter { $0.kind == .adopt }.count
        updated = outcome.result.updated.count - adopted
        contactsBackup = outcome.backup?.url.path(percentEncoded: false)
        notesBackup = outcome.result.noteBackup?.path(percentEncoded: false)
        failures = outcome.result.failures.map { "\($0.path): \($0.message)" }
        pendingReview = plan.reviews.count
    }
}

/// Result of a quick folder scan (onboarding step 2).
struct FolderScan: Sendable, Equatable {
    var markdownFiles: Int
    var contactNotes: Int
    var configured: Bool
    var defaultFolder: String?
    /// This device's state for the vault (configured vaults only).
    var status: StoredStatus?
}
