# Contacts2MdSync — Architecture

Companion docs: [plan.md](plan.md) (milestones, decisions), [markdown-schema.md](markdown-schema.md) (file format), [ui.md](ui.md) (screens), [spikes.md](spikes.md) (open technical questions), [research.md](research.md) (platform facts).

## 1. Goals and non-goals

**Goals**
- Mirror every Apple contact to one mbr-format markdown file under a user-chosen root.
- Two-way sync at field granularity, with automatic resolution wherever the intent is unambiguous.
- Files can be moved anywhere under the root without breaking sync or relationship links.
- Zero duplicate files. Zero duplicate Apple contacts created by us.
- Several devices may point at the same iCloud-synced root.

**Non-goals (v1)**
- Merging Apple contacts (no public link API; we suggest linking in Contacts.app instead).
- Auto-creating Apple contacts from new markdown files (opt-in via UI only).
- Editing non-contact notes (only via explicit UI action).

## 2. Module layout

```
App/
  project.yml                       XcodeGen spec (macOS now, iOS in M7)
  Contacts2MdSync/                  SwiftUI app: views, AppModel, watchers, bookmarks, SyncCoordinator
Packages/Contacts2MdSyncKit/
  ContactModel/     value types, normalization, comparison keys, label map    (Foundation only)
  MarkdownCodec/    frontmatter split, YAML parse (Yams), span-patching emitter, filenames
  ContactsShim/     Objective-C: change-history enumerator wrapped in @try/@catch → NSError
  ContactsAdapter/  CNContactStore ⇄ ContactModel, writes, groups, stamp, history
  VaultIndex/       file enumeration, parse cache, id/title/alias/stem indexes, candidates
  SyncEngine/       Matcher, Planner, Merger, Executor, StateStore, Lease, DecisionLog, Config
  SyncTestSupport/  FakeContactStore, InMemoryVault, scenario DSL, fixtures
  contacts2md-cli/  CLI: status / plan / export / sync (headless, cron-safe) — see §15
```

Third-party dependencies, pinned via `Package.resolved`:

| Package                 | Used for                                   | Lands in |
|-------------------------|--------------------------------------------|----------|
| Yams                    | YAML parsing (we emit managed keys ourselves) | M0/M1 |
| PhoneNumberKit          | E.164 comparison keys (behind a protocol)  | M1       |
| GRDB                    | per-device SQLite state                    | M2       |
| swift-argument-parser   | dev CLI                                    | M1       |

### Seams

The engine never touches `CN*` types or the real file system.

```swift
protocol ContactStore {
  var capabilities: StoreCapabilities { get }          // notesAvailable, iCloudContainerID, writableContainers
  func snapshot() throws -> AppleSnapshot              // unified contacts + underlying cards + containers + groups
  func fetch(unifiedIDs: [String]) throws -> [AppleContact]
  func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult
  func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult
}

protocol VaultFS {
  func enumerate(root: URL) throws -> [FileEntry]      // path, mtime, size, isDataless
  func read(_ url: URL) throws -> (Data, FileStamp)
  func write(_ data: Data, to url: URL, expecting: FileStamp?) throws -> FileStamp   // compare-and-swap
  func trash(_ url: URL) throws
  func unresolvedConflictVersions(_ url: URL) -> [ConflictVersion]
}

protocol SyncStateStore { … }     // GRDB impl + in-memory impl
protocol Clock, IDGenerator, DeviceIdentity
```

`FakeContactStore` has switchable misbehaviours that mirror real-world bugs: unified contacts across iCloud/Google/read-only containers, identifier churn, server-normalization echo (`4155550100` → `(415) 555-0100`), linked-card display precedence, missing notes entitlement (error 102), per-container groups.

The app target holds only SwiftUI, an `@Observable AppModel`, FSEvents + `CNContactStoreDidChange` watchers, security-scoped bookmarks, and a `SyncCoordinator` actor that serializes runs.

## 3. Canonical model

```swift
struct CanonicalContact {
  var kind: Kind                                 // person | organization
  var title: String                              // markdown-owned
  var name: PersonName                           // prefix, given, middle, family, suffix
  var phonetic: PhoneticName?                    // → `apple:` extras
  var company: CompanyRef?                       // (name, isWikilink)
  var department, jobTitle: String?
  var aliases: [Alias]                           // .plain / .nickname / .maidenName / .formerly
  var emails, phones, urls: [Labeled<String>]
  var social: [Labeled<SocialHandle>]
  var im: [Labeled<IMHandle>]
  var addresses: [Labeled<PostalAddress>]
  var dates: [Labeled<PartialDate>]
  var relationships: [RelationshipRef]           // type, label, target: .record(UUID) | .name(String), attrs
  var tags: OrderedSet<String>
  var image: ImageRef?                           // sha256 + ext
  var body: String?                              // ↔ CNContact.note when entitled
  var passthrough: [String: YAMLNode]            // unknown keys, untouched
}
```

Every value carries a **display form** (exactly as written) and a **comparison key** (for equality, merge, hashing). Display values are never rewritten just because their key is unchanged.

| Field         | Comparison key                                                                 |
|---------------|--------------------------------------------------------------------------------|
| email         | trimmed, lowercased                                                           |
| phone         | E.164 using `default_region`; unparsable → digits and `+`, extension as `;ext=` |
| url           | lowercase scheme/host, default port and trailing `/` dropped                   |
| address       | per component: NFC, case-folded, whitespace collapsed; `country_code` uppercased |
| name / title  | NFC, case-folded, diacritic-folded (matching only)                            |
| date          | `YYYY-MM-DD` or `--MM-DD`                                                     |
| body          | `\r\n`→`\n`, trailing whitespace trimmed                                      |
| tag           | mbr normalization: trim, lowercase, spaces → `_`                              |
| image         | sha256 of bytes                                                               |

## 4. State tiers

| Tier              | Location                                                  | Shared?      | Contents                                                                 |
|-------------------|-----------------------------------------------------------|--------------|--------------------------------------------------------------------------|
| Note frontmatter  | each `.md`                                                | all devices  | contact fields, `mdsync.id`, optional `mdsync.status`                     |
| Vault state       | `<root>/.mdsync/`                                         | all devices  | `config.yaml`, `lease.json`, `devices/<id>.json`, `devices/<id>/decisions.jsonl` |
| Device state      | `~/Library/Application Support/Contacts2MdSync/<vault_id>/state.sqlite` | this device | CN ids, merge base, file cache, history token, pending queue, unapplyable fields, session stats |

**Why the merge base is per device.** A shared base can arrive over iCloud before that device's Contacts database has caught up. The device would read its stale Apple data as "Apple changed" and revert markdown. A per-device base fails safe: if stale, both sides look changed *to the same value*, and the "both changed equally → adopt" rule converges with no writes.

**Why decisions are append-only per device.** Each `decisions.jsonl` has one writer, so iCloud never produces conflict copies. Every device reads the union. A follower device can queue intents ("these two are distinct people", "delete confirmed", "opt this file in") for the leader to execute.

Device-state tables: `records` (uuid, unified CN id, underlying card ids + containers, last path, `base_json`, per-field base hashes), `file_cache` (path, mtime, size, sha, uuid), `history_token`, `groups` (CN id ↔ name ↔ tag), `pending` (conflicts, delete queues), `unapplyable`, `sessions`.

## 5. Sync cycle

```
acquire lease ──► scan vault ──► snapshot Apple ──► match/bind ──► merge per field
      │                                                              │
      │            ┌──────────── plan (dry run) ◄────────────────────┘
      │            ▼
      │      safety rails (mass-vanish, blast radius, duplicate gate)
      │            ▼
      │      execute: vCard backup → Apple batch (transactionAuthor) → verify re-fetch
      │               → markdown writes (coordinated, CAS, skip identical)
      │            ▼
      └──── refresh base from fresh re-fetch of both sides; record session stats
```

1. **Scan vault** — enumerate root, skip `.mdsync`, `_images`, excluded paths; re-parse only files whose (mtime, size) changed. Dataless iCloud placeholders count as present and are downloaded only when needed.
2. **Snapshot Apple** — unified contacts plus underlying cards (`unifyResults = false`, mapped via `isUnifiedWithContactWithIdentifier`). From M5, the history token narrows which contacts to re-fetch; a full snapshot is always the fallback and the source of truth.
3. **Match / bind** — §6.
4. **Merge** — §7.
5. **Plan** — a list of typed operations: `createFile`, `updateFile`, `updateCard`, `createCard`, `addToGroup`, `queueDelete`, `conflict`, `review`. The UI shows it; the CLI prints it.
6. **Safety rails** — §9.
7. **Execute** — Apple writes first (one `CNSaveRequest` per batch, `transactionAuthor = com.zmre.contacts2mdsync.<deviceID>`), then re-fetch the touched contacts, then markdown writes.
8. **Refresh base** from the post-write re-fetch so that server normalization becomes the new base and never echoes back.

## 6. Identity and duplicate prevention

### One file ↔ one unified contact

A markdown file is bound to exactly one *unified* Apple contact. We never silently fold two unified contacts into one file.

### Matching cascade

| Step | Signal                                         | Confidence | Action                               |
|------|------------------------------------------------|------------|--------------------------------------|
| 1    | `x-mdsync:<uuid>` URL on any underlying card   | 1.00       | bind                                 |
| 2    | cached underlying CN id in device state        | 0.95       | bind, re-stamp                        |
| 3    | email or phone key equal **and** name key equal | 0.90      | auto-bind only during adoption; else propose |
| 4    | email or phone equal, name differs             | 0.70       | propose                              |
| 5    | name + organization equal                      | 0.50       | propose                              |
| 6    | name only                                      | 0.30       | warning only                         |

**Create gate.** Before creating anything on either side, the candidate runs through the cascade against the whole other side *and* against unstamped person notes in the vault. Any hit ≥ 0.5 blocks auto-creation and moves the item to Review.

### Unlinked duplicate clusters

Union-find over unified contacts on shared strong keys (email key, E.164 phone) plus exact name+org. A cluster with more than one unified contact is a suspected unlinked duplicate (typically the same person in iCloud and Google). Before first export, and whenever one appears, the Duplicates view offers:

- **Open in Contacts to link** (`addressbook://` URLs), then rescan;
- **Distinct people** → decision log; never flagged again;
- **Sync only this one** → others excluded via decision log.

Until resolved, a cluster produces at most one file (the iCloud-backed member) so the first import never fans out duplicates.

### Stamping and write targets

- Stamp lives on the iCloud underlying card; if none, the first writable card.
- **Additions** go to the iCloud card.
- **Edits/deletes of existing values** go to whichever underlying card holds that value (matched by comparison key).
- **Single-valued fields** go to the iCloud card; after save, re-fetch the unified contact. If the unified value didn't change (a linked card wins display), write to every writable card that has the field. If it still doesn't stick, mark the field `unapplyable` and stop retrying — the main Apple-side anti-ping-pong guard.
- **New contacts** (opted in from markdown) are created in the iCloud container.

### Linking/unlinking after the fact

- User links two cards in Contacts.app that we had stamped separately → two stamps on one unified contact → *merge-records proposal* in Duplicates: user picks the surviving file; on confirm, the other file is deleted (Trash) and its stamp removed.
- User unlinks a stamped contact → the stamped card keeps identity; the other card looks new, matches ≥ 0.9 against the existing file, and appears as "possible duplicate", not a new file.

### Vault-side duplicates

- Two files with the same `mdsync.id` → sync paused for that id; UI: keep one, assign a new id to the other, or delete one.
- Duplicate titles → warned (mbr resolves ties by URL sort, so links become ambiguous).

### First import

Always a dry-run plan first: N files to create, M existing notes to adopt, K clusters to review, J ambiguous matches. Nothing is written until the user clicks **Run First Sync**. A vCard backup of all contacts (`CNContactVCardSerialization`) is written to Application Support before every session that writes to Apple; the last 10 are kept.

## 7. Three-way merge

Merge unit is a `FieldPath`: each name part, `company`, `department`, `job_title`, `title`, `body`, `image`, and each multi-value field merged **element-wise** by comparison key.

| Base → Apple / Markdown                                     | Result                                                                    |
|-------------------------------------------------------------|---------------------------------------------------------------------------|
| A = M (by key)                                              | in sync; markdown display form wins, no Apple write                       |
| only Apple changed                                          | apply to markdown                                                         |
| only markdown changed                                       | apply to Apple                                                            |
| both changed, keys equal                                    | adopt, refresh base (formatting-only edits, server echo)                  |
| both changed, keys differ, scalar                           | **conflict**: Keep Contacts / Keep Markdown                              |
| element added on either side                                | union                                                                     |
| element deleted on one side, untouched on the other         | delete                                                                    |
| element deleted on one side, edited on the other            | **conflict** for that element                                            |
| element label changed differently on both sides             | **conflict**: Contacts / Markdown / Keep Both                            |
| `tags` (managed only)                                       | three-way set merge, never a conflict                                     |
| `relationships`                                             | element key = (type, target uuid or name key); edge attrs from markdown   |
| `body`                                                      | line-based diff3; overlapping hunks → conflict with Keep Both (md, `---`, Apple) |
| `image`                                                     | by hash; both changed → conflict                                         |
| `title`                                                     | markdown-owned; regenerated only if it still equals the old generated title |
| no base (first bind / adoption)                             | treat as both changed: equal keys adopted, single-side additions unioned, scalar disagreements → conflict |

Element order: markdown order kept; Apple additions appended.

```swift
struct SyncConflict: Identifiable, Codable {
  let id: UUID
  let record: UUID
  let field: FieldPath
  let element: ElementKey?
  let base: FieldValue?
  let apple: FieldValue
  let markdown: FieldValue
  let options: [Resolution]        // .keepApple, .keepMarkdown, .keepBoth, .custom
  let appleHash: Hash              // resolution applies only if both hashes still match
  let markdownHash: Hash
}
```

A conflict never blocks the record's other fields. Resolutions are applied on the next run only if both side hashes still match; otherwise the conflict is regenerated.

## 8. Relationships, groups, notes

**Relationships** — see [markdown-schema.md §6](markdown-schema.md#6-relationships). On a title rename: old title appended as plain alias; `to:` references in managed records rewritten; Apple relation names on other cards updated. Non-contact notes linking `[[Old]]` are reported in the UI with a one-click update; the alias and filename stem keep them resolving meanwhile.

**Groups** — see [markdown-schema.md §7](markdown-schema.md#7-tags-and-groups). Tracked by CN group id per device; shared config keyed by group name. Apple-side group rename updates the map and renames the tag in managed files. Groups in non-iCloud/Local containers are ignored.

**Notes** — feature-detected at runtime (`capabilities.notesAvailable`, probe fetch with `CNContactNoteKey`, error 102 → unavailable). When unavailable, the body is markdown-only and the body field is excluded from merge. Ad-hoc/Nix-built binaries will never have it; the notarized Developer ID release will once Apple approves the request.

## 9. Safety rails

| Rail                     | Rule                                                                                                 |
|--------------------------|------------------------------------------------------------------------------------------------------|
| Apple delete             | uuid must be missing in 2 full snapshots ≥ 10 min apart and unmatched by cascade → queued for user. On confirm: markdown file moved to Trash. |
| Markdown delete          | file gone (not dataless) → queued. Options: Restore File (re-export), Unlink (keep contact, clear stamp), Delete iCloud card (destructive confirm). |
| Mass-vanish breaker      | > 10 records or > 5 % vanish from either side in one run → halt everything, ask. Covers iCloud toggled off, account removed, root unmounted/evicted. |
| Blast radius             | > 25 Apple changes in one run → show plan, require approval.                                         |
| Create gate              | §6 — any match ≥ 0.5 blocks auto-create.                                                             |
| Backups                  | vCard of whole store before any Apple write session; keep 10.                                        |
| File writes              | `NSFileCoordinator`, temp file + `replaceItemAt`, CAS on (mtime, size, sha), skip identical bytes, re-parse before write. |
| Invalid YAML             | never written; listed in Activity.                                                                   |
| Unapplyable fields       | fields Apple refuses or that don't stick are recorded and not retried until they change.            |

## 10. Change detection and echo suppression

- **Markdown**: canonical-model hash vs base (bytes never compared directly). FSEvents (file-level) triggers a debounced run. Own writes are remembered as (path, sha) for 30 s and ignored.
- **Apple**: full snapshot diff through M4 (thousands of contacts ≈ 1 s). From M5 the ObjC-shimmed change-history enumerator narrows the set; history fetch excludes `com.zmre.contacts2mdsync.*` authors; errors 603/604, nil token, or `DropEverything` → full snapshot. `CNContactStoreDidChange` is only a debounced "go look" signal.
- **Server echo** (iCloud/Google reformatting our writes) is neutralized by comparison keys plus refreshing the base from a post-write re-fetch.
- Combined debounce ≈ 3 s; `SyncCoordinator` actor guarantees one run at a time.

### Triggers while the app is running

Live sync is event-driven, not polling. Events can be missed, though: the app may be closed or the Mac asleep, FSEvents can drop or merge events, and iCloud may deliver changes in bursts. So live events are backed up by catch-up runs and a periodic full compare:

| Trigger                 | When                                                                     | What runs                                                                                   |
|-------------------------|--------------------------------------------------------------------------|---------------------------------------------------------------------------------------------|
| Live events             | `CNContactStoreDidChange`, FSEvents (3 s debounce)                       | Incremental sync (history token narrows Apple re-fetch; parse cache narrows vault scan)     |
| Launch catch-up         | App start (GUI or menu bar), after the first sync is done                | Sync with a full Apple snapshot and vault scan; picks up everything that changed while the app was closed |
| Wake catch-up           | `NSWorkspace.didWakeNotification`, plus network-reachable after wake; 30 s delay so iCloud can deliver queued changes first | Same as launch catch-up                                                                     |
| Safety sweep            | Every `sweep_interval` (default 2 h; user-configurable 1–6 h or off) when no full compare has run in that window | Full compare even with no events; reported in Activity as trigger `Sweep`                  |
| FSEvents rescan flag    | `kFSEventStreamEventFlagMustScanSubDirs` / `UserDropped` / `KernelDropped` | Full vault rescan (events were lost)                                                        |

- Catch-up and sweep runs use the same engine path, safety rails, and lease as every other run. A full compare costs ~1 s for a few thousand contacts plus a stat of every file (parse cache means only changed files are re-read).
- Timers use `NSBackgroundActivityScheduler` so macOS can coalesce them for battery life.
- If the Contacts history token is expired (603/604), the next run of any kind falls back to a full snapshot.
- When the app isn't running at all, the launchd schedule (§15) is the only trigger.

## 11. Multi-device

- **Lease** `.mdsync/lease.json`: `{device_id, device_name, acquired_at, heartbeat_at, expires_at}`; heartbeat 5 min, TTL 20 min. Acquire: expired or explicit "Take Over"; write, wait ~60 s, re-read, proceed only if still ours. Advisory — an accidental double leader converges because merges are idempotent and identical writes are skipped.
- **Followers** are read-only: they show status and dry-run diffs; user actions go to their own `decisions.jsonl`.
- **iCloud conflict versions** (`NSFileVersion`): canonically equal → auto-resolve keeping current; else raise a record conflict.
- **Handover** is safe because each device keeps its own base.

## 12. Scope (shape now, enforcement M3)

See `scope:` in [markdown-schema.md §8](markdown-schema.md#config-yaml-sketch). Precedence: contact rule > group rule; exclude > include. Leaving scope never deletes anything: `on_leave_scope: detach` sets `mdsync.status: detached` and stops syncing that file.

## 13. Platform notes

| Concern            | macOS (v1)                                              | iPadOS / iOS (M7)                                         |
|--------------------|---------------------------------------------------------|-----------------------------------------------------------|
| Folder access      | `NSOpenPanel` + security-scoped bookmark                | `UIDocumentPicker` folder + bookmark                      |
| Watching           | FSEvents                                                | foreground / `BGAppRefreshTask` / `NSMetadataQuery`        |
| Contacts access    | full only                                               | may be `.limited` (iOS 18+) → warn, request full          |
| iCloud files       | dataless files possible                                 | `.icloud` placeholders; `startDownloadingUbiquitousItem` |
| Status surface     | `MenuBarExtra`                                          | widget + Control Center control                           |

## 14. Testing strategy

- Unit tests per module (Swift Testing).
- Golden-file tests for the emitter; round-trip `parse(emit(x)) == x`.
- Fixtures validated by the real `mbr` binary (flake check) — zero contact "problems".
- Scenario DSL: one test per row of the merge table; echo convergence; unapplyable; delete queues; breakers.
- Property tests: random edits on both sides → sync twice → fixpoint, no duplicates, no data loss beyond explicit deletes.
- Multi-device simulation: two state stores, shared `InMemoryVault` with propagation delay, one Apple store with delay.

## 15. Headless CLI (cron / launchd)

After the GUI has been set up and one sync has completed, `contacts2md sync` runs unattended. Anything that needs a human decision is **skipped**, left queued for the GUI, and printed to stdout as a warning.

### Packaging: the CLI is the app binary

macOS ties both Contacts permission (TCC) and the sandboxed security-scoped folder bookmark to the app's code identity. A separate CLI binary would need its own Contacts grant, which it can't request without a UI, and it couldn't read the app's bookmark. So:

- The app executable takes subcommands. `Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync sync` runs headless: no `NSApplication`, no windows, no Dock icon.
- The nix package (and a `just` recipe) installs a `bin/contacts2md` wrapper that `exec`s that binary.
- It shares the app's sandbox container, so it reads the same bookmark, device state DB and config.
- If Contacts access hasn't been granted, the CLI fails fast (exit 3) and tells you to open the app once. It never prompts.
- **[spike S11]** Verify how TCC attributes access when the binary is started from Terminal, cron and launchd. The fallback is launching via `open -g -a Contacts2MdSync --args sync --wait`, which keeps the app as the responsible process.

### Commands

| Command                       | Does                                                                         |
|-------------------------------|------------------------------------------------------------------------------|
| `contacts2md status`          | Configured?, last sync time and device, lease holder, pending review counts  |
| `contacts2md plan`            | Dry run: what a sync would change, plus what would be skipped                 |
| `contacts2md sync`            | Run one sync cycle unattended                                                |
| `contacts2md export` (M1)     | One-way Apple → markdown; dev/testing                                        |

Flags: `--quiet` (warnings and errors only), `--json` (one JSON document on stdout for scripting), `--verbose`.

### What runs vs. what is skipped

| Situation                                                  | Headless behavior                                                                  |
|------------------------------------------------------------|------------------------------------------------------------------------------------|
| One-side edits, union of additions, echo convergence       | Applied                                                                            |
| New Apple contact, no possible match                       | File created in the default folder                                                 |
| Field conflict (both sides changed, disagree)              | Skipped. Record's other fields still sync. Conflict queued. Warning printed.     |
| Possible duplicate / match ≥ 0.5 blocking a create         | Skipped, queued, warning                                                           |
| Apple delete or markdown delete                            | Queued (as in the GUI), warning                                                    |
| Markdown-only candidates                                   | Never acted on. One summary line ("12 markdown-only files await review")          |
| Copied file (duplicate sync id), invalid YAML              | Skipped, warning                                                                   |
| Mass-vanish breaker                                        | Whole run aborts before writing, error, exit 4                                     |
| Blast radius (> 25 Apple changes)                          | Apple writes skipped, markdown writes still run, warning, exit 2. Override with `--max-apple-changes N`. |
| Another device holds the lease                             | No-op, info line, exit 0 (not an error; cron will try again)                       |
| GUI instance on this Mac is syncing                        | Wait up to 60 s for the local lock, then no-op as above                            |
| Not configured / first sync not done                       | Error, exit 3                                                                      |

Headless runs never resolve anything on the user's behalf. Queued items show up in the GUI's Review badges exactly as if the GUI had found them.

### Output

Plain text, one line per item, stable prefixes so `grep` works and cron mail is readable:

```
contacts2md sync  2026-10-21T03:00:02-06:00  device=Patrick's MacBook Pro
updated  md     Work/Jane Doe.md  (job_title, phones)
updated  apple  Sam Lee  (emails)
created  md     Inbox/Maria Gonzalez.md
WARNING  conflict   Jane Doe: phones[mobile] differs (Contacts "+1 555 0199" vs Markdown "+1 555 0142") — skipped, resolve in app
WARNING  duplicate  "Chris Martin" (iCloud) may match Work/Chris Martin.md (same email) — not created, review in app
WARNING  delete     Tom Becker deleted in Contacts — Work/Tom Becker.md kept, confirm in app
WARNING  pending    12 markdown-only files await review
summary  apple c/u/d 0/1/0  md c/u/d 1/1/0  skipped 3  pending-review 15  2.4s
```

As you asked, warnings go to **stdout**. Real errors (can't open the folder, permission missing, breaker tripped) go to stderr. The run is also recorded in Activity with trigger `CLI` and the session counts.

### Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | Synced; nothing needs review (also: lease held elsewhere)  |
| 1    | Synced; some items skipped and queued for review           |
| 2    | Partial: blast-radius limit held back Apple writes         |
| 3    | Not runnable: not configured, no Contacts access, folder bookmark stale |
| 4    | Aborted by safety breaker; nothing written                 |
| 5    | Unexpected error                                           |

Code 1 is separate from 0 so a wrapper can notify only when review is needed.

### Scheduling

- **Recommended: launchd.** On macOS cron is legacy and runs outside the user's GUI session, where Contacts/TCC can misbehave. The nix-darwin module gains:

  ```nix
  programs.contacts2mdsync.schedule = {
    enable = true;
    interval = 3600;            # seconds → launchd StartInterval
    # or calendar = [{ Minute = 0; }];
    logFile = "~/Library/Logs/Contacts2MdSync/sync.log";
  };
  ```

  This creates `launchd.user.agents.contacts2mdsync-sync` that runs `contacts2md sync --quiet`.
- **cron still works** (`0 * * * * /Applications/Nix\ Apps/Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync sync`), subject to spike S11.
- Settings ▸ General gets a "Sync every [1 hour ▾] in the background" toggle that installs the same LaunchAgent via `SMAppService` for non-nix installs.

### Shared engine guarantees

- Headless and GUI runs share one `SyncEngine` code path. The only difference is a `DecisionPolicy`: GUI = queue and present; headless = queue and report. There's no separate "CLI logic" to drift.
- A local lock file (`flock` in the app container) serializes GUI, CLI and launchd runs on one Mac. The vault lease serializes devices.
