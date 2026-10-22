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
  Contacts2MdSync/                  SwiftUI app: views, AppModel, bookmarks; hosts the SyncTriggers coordinator
Packages/Contacts2MdSyncKit/
  ContactModel/     value types, normalization, comparison keys, label map,
                    ContactStore + NotesProvider seams, Apple snapshot types (Foundation only)
  PhoneNumberKeys/  PhoneKeyer backed by PhoneNumberKit (E.164)
  MarkdownCodec/    frontmatter split, YAML parse (Yams), span-patching emitter, filenames
  ContactsShim/     Objective-C: @try/@catch wrappers (change history, notes probe, vCard) → NSError
  ContactsAdapter/  CNContactStore ⇄ ContactModel, snapshot, groups, stamp, history;
                    notes providers: ScriptingNotesProvider (Apple Events to Contacts.app,
                    ContactsScriptingEvents, ContactsAppControl), EntitlementNotesProvider
  VaultIndex/       VaultFS seam + LocalVaultFS, incremental scan (file cache), id/title/alias/stem indexes
  SyncEngine/       ExportPlanner/Executor, Matching, Clustering, RecordMap, SyncStateStore, DecisionLog (M1–M2);
                    SyncPlanner, RecordMerger, Diff3, AppleWritePlanner, SyncExecutor, LeaseManager,
                    LocalLock, SyncScope (M3); LeaseKeeper, decision-log merging, iCloud file versions (M6);
                    NotesBridgedStore, NotesSync (notes through Contacts.app scripting, §8)
  SyncStateDB/      SyncStateStore on SQLite (GRDB), M1 records.json import
  SyncTriggers/     live sync (M5): SyncCoordinator actor, trigger sources (Contacts notification,
                    FSEvents, wake, sweep, launch), OwnWriteRegistry, per-device TriggerSettings (no SwiftUI)
  Contacts2MdCLI/   CLI library + VaultSession (shared with the app): status / plan / export / review (M1–M2),
                    sync / config (M3), watch + VaultSyncRunner (M5), NotesSettings (per Mac), see §15
  contacts2md/      dev executable wrapping Contacts2MdCLI (the app binary runs the same CLI)
  SyncTestSupport/  FakeContactStore, FakeNotesProvider, InMemoryVault, fixtures (~60 contacts), golden-file helper,
                    SimulatedICloud + SimulatedContactsCloud (multi-device replicas with delay, M6)
```

The engine depends only on ContactModel, MarkdownCodec and VaultIndex; it never imports Contacts.framework. Only Contacts2MdCLI (and the app) link ContactsAdapter.

Third-party dependencies, pinned via `Package.resolved`:

| Package                 | Used for                                   | Lands in |
|-------------------------|--------------------------------------------|----------|
| Yams                    | YAML parsing (we emit managed keys ourselves) | M0/M1 |
| PhoneNumberKit (github.com/PhoneNumberKit/PhoneNumberKit, 5.x) | E.164 comparison keys (behind `PhoneKeyer`) | M1 |
| GRDB (7.x)              | per-device SQLite state (`SyncStateDB`)    | M2 (M1 used a JSON record map) |
| swift-argument-parser   | CLI                                        | M1       |

PhoneNumberKit moved from `marmelroy/PhoneNumberKit` (4.x, now deprecated) to the `PhoneNumberKit` org (5.x). The keyer always passes an explicit region, because PhoneNumberKit's default region lookup reads `CNContactsUserDefaults`.

### Seams

The engine never touches `CN*` types or the real file system.

```swift
protocol ContactStore: Sendable {                      // ContactModel
  var capabilities: StoreCapabilities { get throws }   // notesAvailable, iCloudContainerID, writableContainers
  func snapshot() throws -> AppleSnapshot              // unified contacts + underlying cards + containers + groups
  func fetch(unifiedIDs: [String]) throws -> [AppleContact]
  func apply(_ batch: AppleWriteBatch, author: String) throws -> AppleWriteResult
                                                       // card-level ops: stamp, removeStamp, update, create,
                                                       // delete, addMember, removeMember (M3)
  func changes(since token: Data?, excluding authors: [String]) throws -> HistoryResult
  func exportVCards() throws -> Data                   // vCard backup before Apple writes
}

protocol NotesProvider: Sendable {                     // ContactModel; notes per underlying card (§8)
  var source: NotesSource { get }                      // .entitlement | .scripting
  func availability() -> NotesAvailability             // .entitlement | .scripting(permission) | .unavailable
  func currentPermission() -> NotesPermission          // no launch, no prompt
  func requestPermission() -> NotesAvailability        // shows the macOS prompt; app Settings only
  func readAll(cardIDs: [String]?) throws -> [String: String?]   // nil = every card; absent = unknown
  func write(_ notes: [String: String?]) throws -> NotesWriteResult   // nil or "" clears
  func finishSession()                                 // quit Contacts.app if this run launched it
}

protocol VaultFS: Sendable {                           // VaultIndex; rooted at construction
  func enumerate() throws -> [FileEntry]               // root-relative path, mtime, size, isDataless; skips dot paths
  func read(_ path: String) throws -> (Data, FileStamp)
  func write(_ data: Data, to path: String, expecting: WriteExpectation) throws -> FileStamp
                                                       // .absent | .unchanged(stamp) (CAS on sha256) | .any
  func trash(_ path: String) throws
  func exists(_ path: String) -> Bool
  func list(_ directory: String) throws -> [String]    // direct children incl. hidden (decision logs)
  func requestDownload(_ path: String)                 // iCloud: start downloading a dataless file
  func unresolvedConflictVersions(_ path: String) throws -> [FileConflictVersion]   // NSFileVersion (M6)
  func resolveConflictVersions(_ path: String, keeping: FileConflictVersion?) throws
                                                       // nil keeps the current contents (M6)
}

protocol RecordMapStore { … }     // load/save the record map (the executor's seam)
protocol SyncStateStore: RecordMapStore { … }  // M2: + file cache, pending, decision mirror, groups,
                                               // reported problems, sessions, metadata; GRDB + in-memory
protocol SyncClock, IDGenerator   // (not `Clock`: that name is taken by the stdlib)
struct DeviceIdentity             // M2: stable id + computer name (`<state>/device.json`)
```

Paths in `VaultFS` are root-relative strings (`Inbox/Jane Doe.md`), never URLs: identity is never a path, and relative strings make fakes and goldens trivial.

`FakeContactStore` has switchable misbehaviours that mirror real-world bugs: unified contacts across iCloud/Google/read-only containers, identifier churn, server-normalization echo (`4155550100` → `(415) 555-0100`), linked-card display precedence, missing notes entitlement (the key silently unavailable, as observed in spike S2, or error 102), per-container groups. Since M3 the fake writes to card values and recomputes the unified view from the cards (the most recently saved card wins single-valued display). It also models phone normalization on save (`setNormalizePhonesOnSave`), a container that silently ignores writes to a field (`dropWrites`), a failed save request, and the unified-save fan-out: an operation addressed to a linked contact's unified id writes to every card and increments `unifiedSaveCount`, which every scenario test expects to stay 0.

The app target holds only SwiftUI, an `@Observable AppModel` and security-scoped bookmarks. The watchers (FSEvents, `CNContactStoreDidChange`, wake, sweep) and the `SyncCoordinator` actor that serializes runs live in `SyncTriggers` (M5), so `contacts2md watch` and tests use them too; the app only hosts them (§10 "Hosting in the app").

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
  var body: String?                              // ↔ CNContact.note (entitlement) or Contacts.app scripting
  var passthrough: [String: YAMLNode]            // unknown keys, untouched
}
```

Every value carries a **display form** (exactly as written) and a **comparison key** (for equality, merge, hashing). Display values are never rewritten just because their key is unchanged.

| Field        | Comparison key                                                                   |
|--------------|----------------------------------------------------------------------------------|
| email        | trimmed, lowercased                                                              |
| phone        | E.164 using `default_region`; unparsable → digits and `+`, extension as `;ext=`  |
| url          | lowercase scheme/host, default port and trailing `/` dropped                     |
| address      | per component: NFC, case-folded, whitespace collapsed; `country_code` uppercased |
| name / title | NFC, case-folded, diacritic-folded (matching only)                               |
| date         | `YYYY-MM-DD` or `--MM-DD`; calendar ignored                                      |
| social / im  | (service, username), both lowercased; a synthesized `urlString` is ignored       |
| body         | `\r\n` and a lone `\r` → `\n`; leading blank lines and trailing whitespace trimmed |
| tag          | mbr normalization: trim, lowercase, spaces → `_`                                 |
| image        | sha256 of `imageData`; unavailable data with a thumbnail = *unknown*             |
| merge scalar | trimmed NFC text, case kept (a capitalization fix is a change); birthday as ISO   |
| relationship | `type` + `r:<record id>` when the name resolves to exactly one record, else `type` + `n:<name key>` |

Social and IM keys include the service (the markdown label), so the same handle on two services is two elements. `company` merges on the organization name, so `[[Acme Corp]]` in markdown and `Acme Corp` in Contacts are equal.

Observed rewrites behind these keys ([spike S5](spikes.md#s5-normalization-catalog), iCloud only so far; Google pending):

- **Dates**: Contacts sets `calendar = gregorian` on save, including on yearless dates. The key ignores the calendar.
- **Social profiles**: Contacts fills in `urlString` for known services on save (Twitter `zzspike` → `http://twitter.com/zzspike`), and iCloud gives social profiles new labeled-value ids after the save. Key on (service, username); never on their labeled-value ids.
- **Images**: after the iCloud sync, a 256×256 PNG came back as `imageDataAvailable = false`, no `imageData`, and a re-encoded thumbnail. That state never counts as "image removed" and never deletes the markdown image; the image's comparison is skipped until `imageData` is available again.
- **Verbatim on iCloud**: phone formats, labels (including custom and nil labels), email case, URLs without a scheme or in uppercase, addresses (lowercase state, ISO code and postcode), names, and `&` or `/` in organization fields.

## 4. State tiers

| Tier             | Location                                                                | Shared?     | Contents                                                                                        |
|------------------|-------------------------------------------------------------------------|-------------|-------------------------------------------------------------------------------------------------|
| Note frontmatter | each `.md`                                                              | all devices | contact fields, `c2mdsync.id`, optional `c2mdsync.status`                                       |
| Vault state      | `<root>/.c2mdsync/`                                                     | all devices | `config.yaml`, `lease.json`, `devices/<id>.json`, `devices/<id>/decisions.jsonl`                |
| Device state     | `~/Library/Application Support/Contacts2MdSync/<vault_id>/state.sqlite` | this device | CN ids, merge base, file cache, history token, pending queue, unapplyable fields, session stats |

**Why the merge base is per device.** A shared base can arrive over iCloud before that device's Contacts database has caught up. The device would read its stale Apple data as "Apple changed" and revert markdown. A per-device base fails safe: if stale, both sides look changed *to the same value*, and the "both changed equally → adopt" rule converges with no writes.

**Why decisions are append-only per device.** Each `decisions.jsonl` has one writer, so iCloud never produces conflict copies. Every device reads the union. A follower device can queue intents ("these two are distinct people", "delete confirmed", "opt this file in") for the leader to execute.

Device-state tables (M2 schema `v1`, `SyncStateDB`): `records` (id, unified id *cache*, last path, `base_json`), `record_cards` (record id, card id, container, account kind, first seen, `stamp_seen`), `field_hashes` (record id, field, sha256 of the base keys), `file_cache` (path, mtime, size, sha256, kind contact/other/problem, sync id, title, aliases, problem, contact-related flag), `groups` (CN group id, container, name, tag), `pending` (review item id, kind, JSON, first seen), `decisions` (mirror of the vault logs), `reported_problems` (sha256 of non-contact files with invalid YAML already reported), `unapplyable` (M3, empty), `sessions` (one JSON row per run, last 500), `meta` (`last_export`, `pending_computed_at`; `apple_cache` and `last_full_compare` from M5, see §10).

`base_json` held the Apple side at the last export in M2 (comparison keys per markdown field, plus `name`). From M3 it is the merge base: what Apple and the note agreed on after the last sync (`RecordBase` version 2, see §7). M3 schema `v2` adds `unapplyable.attempted` / `observed` and `record_cards.confirmed`, and uses these `meta` keys: `vanished_records` (record id → first time its contact was missing), `image_hashes` (note images by path, mtime and size, so unchanged images are not re-read).

The vault holds `.c2mdsync/lease.json` (§11) and `.c2mdsync/devices/<id>.json` (`device_id`, `device_name`, `last_sync`, `summary`), written after every sync. The device records let a device see that others use the vault.

The vault-side decision log is `.c2mdsync/devices/<device-id>/decisions.jsonl`, one JSON object per line: `{"id", "kind", "at", "device_id", "device_name", "contacts": [{"card_ids", "title"}], "path", "sync_id", "item"}`. Kinds: `distinct-people` (contacts pairwise distinct; with `path`: the contact is not the person in that note), `sync-only` (keep `contacts[0]`, exclude the rest), `ignore-candidate` (`path` or `sync_id`), `adopt` (`path` → `contacts[0]`), `dup-id-keep` (`path` keeps `sync_id`). M3 adds `resolve-conflict` (`item` = conflict id, `choice`, `apple_hash`, `markdown_hash`), `apple-delete` (`sync_id`, `choice` trash/keep/restore), `markdown-delete` (`sync_id`, `contacts`, `choice` restore/unlink/delete-contact) and `create-contact` (`path`). M5 adds `merge-keep` (`contacts[0]` carries several stamps; the note at `path` keeps its record, the other notes are detached and their stamps removed; review choice `keep:N` on a `merge-…` item). Contacts are referenced by underlying card ids, never the unified id. Every device reads the union; unknown kinds are ignored, unreadable lines reported as warnings. M6 adds `file-version-keep` (`path`, `choice` `keep-current` or `keep-other:N`, `version` = sha256 of the kept version, bound to `markdown_hash` = the current contents and `apple_hash` = the version set) and the multi-device reading rules in §11. The household fix adds `cluster-resolve` (`contacts` = every member of the cluster, `groups` = lists of `{"card_ids", "title"}`, one per person, `excluded` = members not synced, `choice` = the `resolve:…` text, `item`; §6 *Unlinked duplicate clusters*). Existing `distinct-people` and `sync-only` decisions keep working and are shown as partitions; the app writes `distinct-people` for Not Duplicates so devices on older versions still understand it, and older versions ignore `cluster-resolve` (unknown kind).

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

1. **Scan vault** — enumerate root, skip `.c2mdsync`, `_images`, excluded paths; re-parse only files whose (mtime, size) changed. Dataless iCloud placeholders count as present and are downloaded only when needed.
2. **Snapshot Apple** — unified contacts plus underlying cards (`unifyResults = false`, mapped via `isUnifiedWithContactWithIdentifier`). From M5, the history token narrows which contacts to re-fetch (the cached snapshot is patched with them, §10); a full snapshot is always the fallback and the source of truth for deletions and the breaker.
3. **Match / bind** — §6.
4. **Merge** — §7.
5. **Plan** — a list of typed operations: `createFile`, `updateFile`, `updateCard`, `createCard`, `addToGroup`, `queueDelete`, `conflict`, `review`. The UI shows it; the CLI prints it.
6. **Safety rails** — §9.
7. **Execute** — Apple writes first (one `CNSaveRequest` per batch, `transactionAuthor = com.zmre.contacts2mdsync.<deviceID>`), then re-fetch the touched contacts, then markdown writes.
8. **Refresh base** from the post-write re-fetch so that server normalization becomes the new base and never echoes back. A card we just created in a Google container is re-fetched by its stamp, not by identifier: Google sync replaces it with a new identifier shortly after the first save ([spike S9](spikes.md#s9-identifier-stability)).

As implemented in M3 (`SyncPlanner` → `SyncPlan` → `SyncExecutor`): the run takes the local lock and the lease, scans the vault, takes a full snapshot, reuses the M2 identity phases (stamp, cached card ids, adoption, clusters, decisions), then applies unlink decisions and scope, detects deletions, plans opted-in creates, and merges every bound record. The executor saves a vCard backup, applies all Apple operations as one batch tagged `com.zmre.contacts2mdsync.<deviceID>`, takes a second full snapshot, records writes a card did not keep, writes notes (compare-and-swap), and stores the agreed base. If the batch fails, the adapter retries each card's operations in its own save request. The post-write re-fetch is a full snapshot that finds each record again by its card ids or its stamp. We never create cards in Google, so the Google create churn does not arise from our own writes.

## 6. Identity and duplicate prevention

### One file ↔ one unified contact

A markdown file is bound to exactly one *unified* Apple contact. We never silently fold two unified contacts into one file.

What the unified contact looks like in practice ([spikes S4 and S9](spikes.md#cross-cutting-finding-icloud-and-google-cards-were-linked-automatically)):

- **Contacts links iCloud and Google cards automatically.** After the user's Google account was enabled, 1255 of its 1353 cards were linked to an iCloud card within about 15 minutes, with no user action. Each linked contact had exactly one iCloud card and one Google card. What stayed unlinked: 98 Google-only cards, 1172 iCloud-only cards, and 1 On My Mac card. Two cards with the same emails but different family names were not linked, so a name match is required; whether a name match alone is enough is untested.
- **A linked contact's unified id is synthesized.** It is neither card's identifier, and it has no `:ABPerson` suffix. A single card's unified id is the card id. Treat the unified id as a volatile cache: device state keys records on the stamp and the underlying card ids, and re-derives the unified id on every snapshot.
- **The unified view is a blend.** Multi-valued fields are the union of the cards, with values that are identical across cards shown once. Which card supplies a collapsed value, and therefore its labeled-value id, can change. Single-valued fields show one card's value; the observations fit "the most recently saved card wins", so a Google sync that re-saves its card can flip the display. The engine therefore never reads field values from the unified view (see *Stamping and write targets*).

### Matching cascade

| Step | Signal                                          | Confidence | Action                                       |
|------|-------------------------------------------------|------------|----------------------------------------------|
| 1    | `x-c2mdsync:<uuid>` URL on any underlying card  | 1.00       | bind                                         |
| 2    | cached underlying CN id in device state         | 0.95       | bind, re-stamp                               |
| 3    | email or phone key equal **and** name key equal | 0.90       | auto-bind only during adoption; else propose |
| 4    | email or phone equal, names *compatible*        | 0.70       | propose                                      |
| 5    | name + organization equal                       | 0.50       | propose                                      |
| 6    | name only                                       | 0.30       | propose (blocks the create)                  |
| 6a   | email equal, names *incompatible*               | 0.30       | warning only (never blocks, never binds)     |
| —    | phone equal, names incompatible                 | none       | not a candidate                              |

**Names gate phones and emails.** A shared phone or email is a household signal: spouses share a home number, couples share an email. Steps 3–4 count only when the names are compatible (`NameCompatibility`, below); with incompatible names a shared phone is no candidate at all, and a shared email is an advisory 0.3 that prints a warning ("… shares an email with People/Jane Doe.md, but the names differ …") and does not block the contact's note. So a husband's contact is never held back by his wife's hand-written note that carries the same home number, and the create gate (≥ 0.5) lets the wife's opted-in note become a contact even though the husband's contact shares that number. Cached-id corroboration (§6 *Stamping is optional*) ignores advisory matches too. For notes, a person without name parts is read from the title (`Jane Doe` → Jane / Doe), since hand-written notes often have only a title, but only when the title plainly is a name (one word is a given name): `Dr. Jane Doe`, `John Smith Jr.`, `Doe, Jane` or `Jane Doe (Acme)` count as no person name, so their shared emails and phones still propose a match instead of creating a second note.

**Name compatibility** (`ContactModel.NameCompatibility`). Two contacts' person names are compatible when either has no person name (organization-only or empty), or the family names agree **and** the given names agree. Family names agree when their comparison keys are equal, when one hyphenated or compound name contains the other (`García-López` / `Garcia`, `van der Berg` / `Berg`, particles ignored), or through a maiden name (`previousFamilyName`, alias `maiden_name`). Given names agree when equal, when one is an initial or a short form of the other (a prefix of at least three letters that leaves at least three more, or a pet form ending in -ie/-y/-ey: `J.` / `James`, `Chris` / `Christopher`, `Ann` / `Annie`, but not `Paul` / `Paula` or `Daniel` / `Danielle`), when they are a nickname pair from a built-in table of about 100 common English nicknames (`Bob` / `Robert`, `Liz` / `Elizabeth`, `Ted` / `Edward` or `Theodore`, …), or when either is empty. A nickname alias counts as another given name, a plain two-word alias as another full name. Everything is case- and diacritic-folded. A nickname maps to its formal names, and two names match only when those sets meet, so `Christopher` and `Christine` stay different although both are `Chris`. Two compound given names agree word by word (`Jean-Luc` / `Jean-Pierre` differ; `Mary` / `Mary Ann` agree). Same family name with different given names (spouses, siblings) is incompatible, and so are two different generational suffixes (`Sr.` / `Jr.`).

**Cached ids (step 2).** iCloud card identifiers were stable in every spike run, including through linking and through enabling another account. A card we create in a Google container gets a new identifier once Google sync replaces it, so its id is not cached until a later snapshot finds the card again by its stamp. A cached id that disappears means "re-resolve by stamp and cascade", never "deleted" (see the Apple delete rail in §9).

**Create gate.** Before creating anything on either side, the candidate runs through the cascade against the whole other side *and* against unstamped person notes in the vault. Any hit ≥ 0.5 blocks auto-creation and moves the item to Review.

### Unlinked duplicate clusters

Union-find over unified contacts (card-precedence values). Two contacts are joined by an edge when:

- their full names are equal (comparison key of `given family suffix`), and so are their organizations when both have one; two organization-only contacts join on an equal organization name; **or**
- they share an email **and** their names are compatible.

A shared phone never creates an edge. A shared personal number (mobile, iPhone, unlabeled) is listed among the reasons of an email edge; household and office numbers (`home`, `main`, `work`, `other`, faxes, pagers, custom labels) are ignored altogether. Every edge keeps its reasons for display, for example `same email jane@doe.example · same mobile +1 303 555 0122 · names match (Jane / Jane)` or `same name "Jane Doe"`. So spouses who share a home phone, each with an unlinked Google duplicate, form two clusters (one per person) rather than one cluster of four; siblings sharing a mobile with different given names never cluster. Edges are judged pair by pair, but an edge that would put two incompatible names in one cluster is dropped: a card that fits both spouses (an organization card or `J. Doe` on the family email) joins only one of them. Only the user's own decisions join incompatible names.

A cluster with more than one unified contact is a suspected unlinked duplicate (typically the same person in iCloud and Google). Before first export, and whenever one appears, the Duplicates view offers:

- **Open in Contacts to link** (`addressbook://` URLs), then rescan;
- **a partition** (`cluster-resolve`): the user selects cards and says which are the same person, which are different people, and which are not synced;
- **Not Duplicates** (`distinct-people`) → every member a different person; never flagged again;
- **Ignore for Now** → snoozed until the next sync.

Until resolved, a cluster produces at most one file (the iCloud-backed member, never one a decision left out) so the first import never fans out duplicates. Members are numbered in card order, not by the volatile unified id, so `resolve:` numbers name the same contacts from one plan to the next.

**Cluster resolution** (`cluster-resolve` decision). It stores, for the cluster's members (referenced by `ContactRef`: underlying card ids, never the volatile unified id), `groups: [[ContactRef]]` and `excluded: [ContactRef]`, plus every member in `contacts`. Each group is one person and syncs to one note: the member that already has a note, else the group's primary (iCloud-backed, then local, then lowest card id); the other members are skipped silently ("same person as … (decision); link the cards in Contacts"). A member that is itself held back (its note detached, …) never keeps the person's note. Notes are never dropped: when several members of a group already have notes, each keeps syncing until the cards are linked in Contacts and one note is kept (the merge-records review), which the Apply confirmation and `review decide` say. Different groups are different people: a pair in different groups of the latest resolution naming both is never joined again (a later resolution putting them together lifts that). Excluded members are not synced: a contact without a note is skipped, one with a note is treated like a contact leaving the sync scope (detached when `scope.on_leave_scope` is `detach`, else skipped). Members of one group are joined even without an edge, so a group stays together when the member that linked them is moved elsewhere.

A contact's *role* is its place in the latest cluster decision naming it: `cluster-resolve` (its group, or excluded; a contact holding a kept card is that person even when an excluded card was linked into it later), `distinct-people` without a path (a group of its own), or `sync-only` (`contacts[0]` a group, the rest excluded; a legacy exclusion only ever applied to contacts without a note, so one with a note is a person of its own, also in review). Two contacts matching one reference are the halves of a contact unlinked since the decision: nobody answered for them separately, so they are undecided and their cluster is asked again. A cluster is settled, and not reported, when every member has a role and every edge joins two members whose roles come from the same decision. Otherwise it is reported again: a new member, or a new edge between members answered separately, re-opens it. The review item then carries each member's earlier answer (`ClusterMember.prior`: `person(N)` or `excluded`), so the app and `review list` show the earlier partition with the newcomer undecided; a member that disappeared simply drops out and the rest stays settled. The item id is a hash of the members' card ids, so a changed membership is a new item.

Because Contacts links same-name iCloud and Google cards by itself, most cross-account duplicates arrive already unified. Clustering is the safety net for the rest: cards whose names differ (nickname, maiden name, typo), Google-only and iCloud-only contacts, and same-name cards Contacts didn't link.

### Stamping and write targets

The Apple-side value of a field is computed from the underlying cards, not read from the unified view:

- **Multi-valued fields**: the union of every card's values, de-duplicated by comparison key.
- **Single-valued fields**: the first non-empty value in precedence order: stamped card, then iCloud card, then other writable cards, then read-only cards, ties broken by card id. The order is deterministic, so a Google re-save that flips the unified display is not an Apple-side change.

Write targets:

- Stamp lives on the iCloud underlying card; if none, the first writable card. Google-only contacts get the stamp on the Google card (stamp survival on Google is still being verified, [spike S1](spikes.md#s1-stamp-survival)). Stamping is optional (see *Stamping is optional* below).
- **Additions** go to the iCloud card (for Google-only contacts, the Google card).
- **Edits/deletes of existing values** go to **every** writable underlying card that holds a value with that comparison key. A value often exists on both linked cards (the shared email case), and editing only one card would let the other copy come back through the union.
- **Single-valued fields** are written to the iCloud card and to every other writable card that has a non-empty value for the field, all in one `CNSaveRequest`, so the cards agree whichever one wins the unified display. After save, each written card is re-fetched and checked. A card that doesn't keep the value (server rejection or rewrite outside its comparison key) gets the field marked `unapplyable` for that card and is not retried: the main Apple-side anti-ping-pong guard.
- **Never save a mutable copy of a unified contact.** Spike S4 showed that it writes the change to every linked card (the same new email, with the same labeled-value id, appeared on both cards, and the Google card's own job title was overwritten). All saves target underlying cards fetched with `unifyResults = false`.
- **New contacts** (opted in from markdown) are created in the iCloud container.

### Stamping is optional

`stamp_contacts: true` in `.c2mdsync/config.yaml` turns stamping on. The default is off, because a single device does not need stamps. Stamps are Apple writes, so they also need `apple_writes: enabled` (§9). Without them they are reported as held.

Without stamps, identity rests on this device's state and on matching:

- Cached underlying card ids (cascade step 2). iCloud ids were stable in every spike run. A Google id is trusted once a snapshot found it with the stamp or, without stamps, once the contact still matched the record's base (a strong key or the name) in a snapshot at least 10 minutes after the id was first seen (`BoundCard.confirmed`). Before that, a Google id binds only with that corroboration.
- Strong keys and names (steps 3–6) re-find a contact whose cards all changed (relocation, §6 "What M2 implements").
- A vanished card id is re-matched through the cascade before anything counts as deleted (§9).

Stamps matter when several devices share a vault, because each device's cached card ids are its own. When `.c2mdsync/devices/` lists more than one device and stamping is off, every sync prints one `WARNING identity` line ("2 devices share this vault; enable stamp_contacts so devices agree on identity"), and `StoredStatus.identityWarning` carries the same text for the app. Nothing turns stamping on by itself.

Turning `stamp_contacts` on stamps every bound record on the next sync. That sync takes a vCard backup first, and each stamp counts toward the blast-radius limit, so a large address book needs `--max-apple-changes` once. Turning it off never removes stamps. Stamps already on cards still identify contacts when they are read. `contacts2md export --stamp` remains as the M1 one-shot.

### Linking/unlinking after the fact

- Two stamped contacts become linked → two stamps on one unified contact → *merge-records proposal* in Duplicates: user picks the surviving file; on confirm, the other file is deleted (Trash) and its stamp removed. With automatic linking this is a common path, not an edge case: it happens when the user links cards by hand, when a Google account is enabled after the first export, or when a card is renamed so the names match. Headless runs report it as a `WARNING duplicate` line and leave both files alone.
- User unlinks a stamped contact → the stamped card keeps identity; the other card looks new, matches ≥ 0.9 against the existing file, and appears as "possible duplicate", not a new file.

### Vault-side duplicates

- Two files with the same `c2mdsync.id` → sync paused for that id; UI: keep one, assign a new id to the other, or delete one.
- Duplicate titles → warned (mbr resolves ties by URL sort, so links become ambiguous).

### First import

Always a dry-run plan first: N files to create, M existing notes to adopt, K clusters to review, J ambiguous matches. Nothing is written until the user clicks **Run First Sync**. A vCard backup of all contacts (`CNContactVCardSerialization`) is written to Application Support before every session that writes to Apple; the last 10 are kept.

### What M2 implements

Adds to the M1 export below:

1. **Identity cascade** (`ExportPlanner` + `Matching`): stamp on any card → cached underlying card ids → matching against unbound notes. Several different stamps on one unified contact → `merge-records` review (`WARNING duplicate`), both notes left alone. Cached ids: a record is claimed by the contact sharing its strongest card (trusted beats untrusted, iCloud beats others; a tie leaves both unbound for the cascade and clustering). Untrusted ids (Google cards never seen with their stamp) are kept as *provisional* hints and bind only when the record's base (else its note) shares a name or strong key with the contact. The unified id is stored but never used for identity.
2. **Relocation**: a record whose cards all vanished (Google churn, lost ids) leaves an *orphaned* note; an unbound contact matching it at ≥ 0.9 with no rival is rebound to it silently (`relinked`). Never treated as a delete.
3. **Adoption**: unbound contacts are scored against hand-written contact notes (no `c2mdsync.id`) and orphaned notes. Name keys on the note side are the title, aliases and person name (hand-written notes often have only a title); a bare nickname never counts. ≥ 0.9 with exactly one candidate each way is adopted automatically on the device's first import for the vault (`--auto-adopt first-import|always|never`); any other match — including name-only (0.3) — blocks creation and becomes a `possible match` review item. An adopted note keeps its path, title, body, unknown keys and markdown-only values, and gains a `c2mdsync.id`.
4. **Clusters** now run on card-precedence values and skip pairs declared distinct; members excluded by a sync-only decision are left out (no review, not exported). A cluster with every member decided is not reported again. (Superseded by the rules in *Unlinked duplicate clusters* above: names gate emails, phones never join, `cluster-resolve` partitions.)
5. **Decisions** (above) are honoured by the planner and recorded with `contacts2md review decide` / `adopt-all` (§15).
6. **Vault index**: incremental scan with the file cache (unchanged non-contact and problem files are not re-read; contact notes always are), duplicate ids (paused unless a `dup-id-keep` decision picks the copy), mbr name resolution (title → alias → stem), duplicate titles warned across all contact notes, `scope.markdown.exclude_paths` globs skipped. Dataless files (iCloud `ubiquitousItemDownloadingStatus`, the `SF_DATALESS` flag, or legacy `.Name.md.icloud` placeholders) are never read: known ones keep their cached facts (a bound note that is dataless is skipped, not missing); unknown ones are asked to download and hold back *new* notes for that run (`WARNING icloud`, override `--allow-undownloaded`). A record whose note is not found while unknown placeholders exist is skipped, not reported missing. Notes written by an export are added to the file cache immediately.
7. **Invalid YAML**: contact-looking files (`type: person|organization` or `c2mdsync:` in the text) are review items; other notes are reported once per content hash (`WARNING yaml`) and never affect the exit code.
8. **Moves**: a moved note is updated in place; when only its relative `image:` changed, the update is a `fixup` (not a content change); the record's path is updated.
9. **Apple values by card precedence** (`AppleContact.cardMergedContact`): the adapter reads every underlying card's fields (no images) and the engine applies the precedence in *Stamping and write targets*; with any card's values unknown it falls back to the unified view.
10. **Backups**: every note about to be rewritten is copied to `<state>/<vault_id>/backups/notes-<timestamp>/` first (last 10 kept); vCard backups moved to the same folder.

### What M1 implements (one-way export)

`ExportPlanner` → `ExportPlan` → `ExportExecutor` (SyncEngine). The plan holds final, validated bytes; executing it only writes.

1. **Identity**: stamp on any card, else the per-device `RecordMap` (unified id, then any card id; ambiguous card overlap → unbound). From M2 the card ids come first and the unified id is only a hint, because a linked contact's unified id is synthesized and volatile (spike S4). Several different stamps on one unified contact → review, skipped. A stamp from another vault (no binding here) simply reuses that id for the new note.
2. **Clusters**: union-find on email key, E.164 phone key (≥ 7 digits) and exact name+organization. Name+organization requires a non-empty organization; name-only never clusters (two distinct "John Smith"s would otherwise block each other with no way to resolve in M1). Since the household fix, equal names do cluster (a partition or Not Duplicates resolves them) and phones never do; see *Unlinked duplicate clusters*. Until resolved, a cluster yields one note: if a member already has a note, no other member gets one; otherwise the primary does (iCloud-backed, then local, then lowest unified id). Every cluster is a review item.
3. **Notes**: a bound record's note is found by `c2mdsync.id` anywhere under the root and patched in place (moves are free). A bound record whose note is gone is reported as `missing` and not re-created unless `--restore-missing`. A copied note (duplicate `c2mdsync.id`) pauses that record.
4. **Create gate**: an unbound contact is not created when it matches a contact note nobody is bound to: by strong key (email, phone, name+organization) for any such note, and also by plain title for *orphaned* notes (they carry an `c2mdsync.id` no Apple contact is bound to — e.g. the device state was lost). This makes a lost record map fail safe: nothing is duplicated, everything is reported for review.
5. **Filenames** avoid every stem in the vault (mbr resolves links by stem globally), then planned ones.
6. **Executor**: images first, then config, then notes; every note write is compare-and-swap (`.absent` for new, `.unchanged(sha)` for updates), so a note edited between plan and execute is reported, not overwritten. Bindings are saved only for notes that were written or already identical.
7. **Stamping** (the only Apple write in M1) requires a `BackupReceipt`, which only `VCardBackup.backup` can create, and is off unless the user passes `--stamp`.

Per-device state for M1 was `~/Library/Application Support/Contacts2MdSync/<vault_id>/records.json`. M2 replaces it with `state.sqlite` in the same folder; on first open an existing `records.json` is imported (cards marked trusted, account kinds refreshed by the next export) and renamed `records.json.imported`.

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

### What M3 implements

`RecordMerger` merges one record from three field views: the Apple side by card precedence, the note, and the base.

- **Scalars** (name parts, nickname, maiden name, company, department, job title, phonetics, birthday) follow the table. Without a base, an empty side takes the other side's value and two different values conflict.
- **Lists** are merged in slots. Each base element is one slot. For each side the merger notes whether the element was kept, relabeled, edited or removed. A removed element and an added element with the same label on one side count as an edit. With an M2 base, whose labels are unknown, the only removed/added pair on a side also counts as an edit. Elements added on either side get their own slots. The note keeps its order, and Apple additions are appended. A Contacts-side edit replaces the markdown element in place.
- **Label conflicts** offer Keep Contacts and Keep Markdown only. Keep Both would need the same value twice under one comparison key. A delete against an edit, or two different edits, offer Keep Both where both sides still have a value.
- **Tags** use a three-way set merge over managed tags. Without a base the result is the union.
- **Body** is merged only when notes are synced (§8). The merger runs a line diff3 against the base body. Overlapping hunks conflict, and Keep Both writes the markdown text, a `---` line, then the Contacts text. A body pushed to Contacts is written through to every writable card whose note differs (notes are per card). A body without a base (first sync with notes, adopted notes) follows the first-bind rule; this is the enablement migration in §8.
- **Image** compares hashes. A thumbnail-only Apple image, a URL, a missing file or an evicted iCloud file is unknown and never compared.
- **Title** is regenerated only when Apple's name changed this run and the title still equals the title generated at the last sync (`RecordBase.generatedTitle`; for M2 bases the folded name keys). The old title becomes a plain alias, and `to: "[[Old]]"` links in other synced notes that resolve to the record are rewritten.

`SyncConflict.id` is a stable string (`conflict-<10 hex>` from record, field and element), not a random UUID, so a decision made in one run finds the same conflict in the next. Resolutions are `resolve-conflict` decisions carrying both side hashes. A side hash covers the comparison key and label of that side.

**The agreed base.** After a run the base of each field or element is what Apple (from the post-write snapshot) and the note (as written) agree on. A held write, a failed write, an unresolved conflict or a refused value keeps the previous base for that field, so the same change is found again next run. It is never mistaken for a change on the other side. An M2 base (`version` nil) is read as follows. Emails, phones, URLs, addresses and the plain scalars keep their keys with unknown labels. Company, social, IM, dates, birthday, relationships, tags, body and image have no base, and the first-bind rule applies once.

**Unapplyable values.** After the Apple batch, the executor re-reads each written card. A scalar it did not keep becomes an alias: while the card still shows the observed value, the merge treats it as the value we wrote, so it is neither rewritten nor raised as a conflict. A list write it did not keep (add, remove, replace, relabel) is skipped for that card from then on. A managed tag that no iCloud or On My Mac card can carry is recorded the same way and reported once. An entry expires as soon as either side changes the value.

**Apple write targets** follow *Stamping and write targets* (§6): additions go to the target card, edits and deletes go to every writable card holding the key, and single values go to the target card plus every writable card that has the field. A list edit names the card's current value, so the adapter changes that `CNLabeledValue` with `settingLabel(_:value:)` and keeps its identifier. When the markdown label still maps to the card's label, the card's label is kept, so labels do not flap. Values the canonical model cannot represent, and the stamp URL, are always kept.

## 8. Relationships, groups, notes

**Relationships** — see [markdown-schema.md §6](markdown-schema.md#6-relationships). On a title rename: old title appended as plain alias; `to:` references in managed records rewritten; Apple relation names on other cards updated. Non-contact notes linking `[[Old]]` are reported in the UI with a one-click update; the alias and filename stem keep them resolving meanwhile.

In M3 both sides' targets resolve to record ids through note titles, aliases and the Apple contacts' name variants, so "Jane Q. Doe" in Contacts and `[[Jane Doe]]` in markdown are the same element. A relation written to Apple carries the target contact's Apple display name, not the note title. Markdown-only types (`employer`, `employee`, `manages`, `assists`), `from:` edges and edges without `to:` never reach Apple. M3 does not yet rewrite Apple relation names on other cards after a rename. Those relations still resolve by record id, so nothing churns.

**Groups** — see [markdown-schema.md §7](markdown-schema.md#7-tags-and-groups). Tracked by CN group id per device; shared config keyed by group name. Apple-side group rename updates the map and renames the tag in managed files. Groups in non-iCloud/Local containers are ignored.

In M3 a managed tag added in markdown adds the contact's first iCloud or On My Mac card to a group with that name in the same container. A removed tag removes every card of the contact in that group's container. A tag that no card can carry stays in markdown and is reported once (`WARNING blocked`). Group renames in Apple are not followed yet: a renamed group appears as a new group with a new tag.

**Notes** — a record's body maps to the Contacts note when notes are synced on this Mac. There are two sources, chosen per run (`VaultSession.notesSetup`):

1. **The notes entitlement** (`com.apple.developer.contacts.notes`), when present: `CNContactNoteKey` in the snapshot, `.note` edits in the same save request as every other field. Feature-detected at runtime (`capabilities.notesAvailable`): probe-fetch one card with `CNContactNoteKey`, then check `isKeyAvailable(CNContactNoteKey)`. An un-entitled build gets no error: the fetch succeeds and the key is silently missing (spike S2, macOS 27). Error 102 is still treated as unavailable in case an entitled-but-revoked build reports it. Never read `.note` without the `isKeyAvailable` check: an unfetched key raises `CNContactPropertyNotFetchedException`. Ad-hoc/Nix-built binaries never have it; the notarized Developer ID release will once Apple approves the request (still not granted).
2. **Contacts.app scripting** (Apple Events, [spike S12](spikes.md#s12-findings-2026-10-22)), when the entitlement is missing, this Mac's `notes_sync` setting is on, and macOS reports the Automation permission for Contacts as granted. The permission is checked when the run first reads notes, not before: a run that reads no notes (an incremental run with nothing touched) never launches Contacts.app.

Otherwise the body is markdown-only and excluded from the merge. Notes wanted but not permitted are *skipped* for the run with a warning; that is not the same as off (below).

### As implemented (notes scripting)

**Provider seam.** `NotesProvider` (ContactModel) reads and writes notes per underlying card: `availability()`, `currentPermission()` (no side effects), `requestPermission()`, `readAll(cardIDs:)` (card id → text; `nil` = every card; a card the provider did not see is *absent*, never reported as empty), `write(_:)` (per card; `nil` or `""` clears; per-card failures in the result), `finishSession()`. ContactsAdapter has `ScriptingNotesProvider` and `EntitlementNotesProvider`; the latter exists for status and one-off use, since with the entitlement the snapshot already carries notes. Tests use `FakeNotesProvider` over the fake store's card notes.

**Apple Events.** `ScriptingNotesProvider` sends raw Apple Events with object specifiers (`ContactsScriptingEvents`), the same events AppleScript sends. It does not use `NSAppleScript` (the S12 spike did): `NSAppleScript` belongs on the main thread, and syncs run on background threads in the app. Raw events also take explicit timeouts (60 s per event) and go through an injectable `AppleEventSending`, so tests never send one. Codes come from `Contacts.app/Contents/Resources/Contacts.sdef`: class `person` = `azf4`, property `note` = `az37`, property `id` = `ID  `, `save` = `core`/`save`. Card ids travel as descriptors and are never spliced into script source. Events are sent with `neverInteract`.

- Contacts.app's `person` is an underlying card and its `id` is the CNContact card identifier (S12: 3,785 of 3,785). Notes are per card.
- **Bulk read**: `id of every person`, `note of every person`, then the ids again. If the two id lists differ (a person was added or removed in between), the read is retried, at most 3 times; then it fails. About 0.5 s for 3,785 cards. `missing value` reads as no note.
- **Partial read**: up to 40 cards one event each (≈9 ms per card), more as one bulk read filtered to the cards. A card that does not resolve (`-1728`) is left out (unknown).
- **Write**: `set note of person id X to T`, then `save`, card by card; then the written cards are read back and compared after line-ending normalization. A card that kept a different note, or does not resolve, is a per-card failure.
- **Errors**: `-600`, `-609`, `-1708`, `-1712`, `-1743`, `-1744` and `-903` concern the session (permission, Contacts.app not reachable, timeout) and become `NotesUnavailableError`. Any other error concerns one card.

**Permission.** `AEDeterminePermissionToAutomateTarget` for `com.apple.AddressBook`: `0` granted, `-1743` denied, `-1744` not decided yet, `-600` Contacts.app not running. Because macOS answers only for a running app, the first notes read of a run (and `availability()`) launches Contacts.app first when needed, then checks; without permission the read fails with `NotesUnavailableError(permissionDenied:)` and the run skips notes with the permission warning. A refusal is remembered for 15 minutes in the process (`NotesRefusalMemo`): while Contacts.app is not running, the next runs skip notes without launching it just to be told again; `requestPermission()` and a granted check clear it. While notes are skipped, the cached mirror has no notes, so runs read Contacts with a full snapshot (`notes turned on or off`) until notes can be read again. Sync never prompts. Only `requestPermission()` (Settings ▸ Advanced ▸ Contact notes, a user action) asks with `askUserIfNeeded = true`. The app declares `NSAppleEventsUsageDescription` and the entitlements `com.apple.security.automation.apple-events` and `com.apple.security.temporary-exception.apple-events = [com.apple.AddressBook]` (sandboxed, hardened runtime).

**Contacts.app lifecycle.** When Contacts.app is not running, the provider launches it hidden and without activating it (`NSWorkspace.OpenConfiguration`: `activates = false`, `hides = true`, not added to recent items), waits until it finished launching, and retries a cheap `count every person` until it answers (15 s). After the run, `finishSession()` quits it only if this provider launched it, it is still hidden and not frontmost (the user is not using it), and `quit_contacts_after_sync` is on (the default). The session ends through `NotesRunHandle.finish()` at the end of `executeSync` and `recordSyncPlan`, and at the latest when the prepared run is released.

**The bridge.** `NotesBridgedStore` (SyncEngine) is a `ContactStore` that wraps the Contacts.framework store and adds notes:

- `snapshot()` reads the framework snapshot, then every note in one bulk read. `refetch` and `fetch` read only the cards of the contacts they return. Each card's note goes into its `values.body`.
- The record's Contacts note is the note of the first card in precedence order that has one (stamped, iCloud, other writable, read-only, ties by card id), as for every single-valued field. A different note on another card does not count, so a linked card that disagrees never causes ping-pong.
- A card missing from the read makes that contact's notes unknown (`AppleContact.notesUnknown`). The merge then leaves the body alone on both sides and the base keeps its body; an unknown note is never read as empty.
- `apply` takes the `.note` edits out of the batch, saves the rest through the framework store, then writes each note to its card (for a created contact, to the new card). Before any note is written, the notes about to be overwritten are saved to `<state>/<vault_id>/backups/apple-notes-<time>.json` (last 10 kept): the vCard backup cannot hold them without the entitlement. A failed backup writes no note.
- `AppleWritePlanner` writes a pushed body through to **every** writable card whose note differs, not only to cards that already have one.

**Failures.**

- A failed read (no permission, Contacts.app not answering, the bulk read never settling) leaves the run without notes: `snapshot.notesAvailable = false`, the plan is a *skipped* notes run with a warning, and nothing about bodies changes on either side.
- A write that fails for the whole session reports those operations as failed. They are retried next run, since the base is unchanged.
- A card that refuses its note keeps the operation applied. The executor's post-write snapshot re-reads every note in bulk, and its verification marks `body` unapplyable for that card (not retried until either side changes). Notes are verified only when that re-read succeeded. A note for a newly created card that fails never fails the create; the next sync writes it.

**Own writes.** Contacts.app saves are not tagged with our `transactionAuthor`, so author exclusion does not apply. The executor reads the history token after the Apple batch, notes included, so the events of our note writes are older than the token the next run starts from (S12: one `UpdateContactEvent` on the target card, recorded when `save` returns). As a second line, `NotesOwnWrites` remembers (card id, hash of the text) for 30 s. If a late event makes the next run re-read that card and the note hashes to what we wrote, it is counted as our own echo (`ownWritesSeen`); the merge finds no change because the base was refreshed from the same text. The registry never replaces a read: the user may edit the same note in Contacts right after our write, and only a read sees that edit.

**Incremental runs** (§10). The history marks a card changed when its note changes in Contacts, so the patch re-reads that contact, and the bridge re-reads only its cards' notes. Records whose markdown changed are re-read the same way. The mirror (`meta.apple_cache`) carries the notes and `notesAvailable`. When the run expects notes and the cache was made without them, or the other way round, the run takes a full snapshot (reason `notes turned on or off`).

**Enablement migration.** There is no body base when notes start: the first sync with notes on this Mac, or the first after notes were off. The device state keeps `meta.notes_source`, the source of the last executed sync that synced notes. A sync with notes off (setting off, no provider) removes it; a skipped run leaves it alone, so a headless run without permission does not reset the base. With notes active and no `notes_source`, the run is a *fresh start* (`NotesStatus.freshStart`): every record's stored body base is dropped for the merge and the body follows the first-bind rule:

| Markdown body | Contacts note | Result |
|---------------|---------------|--------|
| empty | non-empty | the note goes into markdown |
| non-empty | empty | the markdown body goes into Contacts (an Apple change: counts toward the blast radius, held while `apple_writes` is disabled) |
| equal (by comparison key) | | adopted as the base, nothing written |
| non-empty | non-empty, different | conflict: Keep Contacts / Keep Markdown / Keep Both |

The plan carries a `NotesBaseline` for every record merged without a body base: bodies into markdown, bodies into Contacts (title, path, characters, lines), kept-both, already equal, conflicts. `contacts2md plan` prints it with every markdown body bound for Contacts and its size; the app shows it before the first notes sync. Records that get a body base later (an adopted hand-written note) appear in it too. Held or conflicting records keep no body base, so they show again on the next run.

**Long notes.** Notes are never truncated. S12 saw up to 49,152 characters. Diff3 handles them line by line (the LCS table is bounded at 4 million cells; beyond that the whole text is one hunk). `\r\n` and lone `\r` are normalized for comparison. A pulled note replaces the body after the blank lines it started with.

**Not covered.** The first export (`export`) does not read notes; the first sync after it takes them. Whether notes propagate to iCloud.com and Google after a scripted write is not verified (S12). The raw Apple Events have not yet run against the real Contacts.app (S12 used `NSAppleScript`).

## 9. Safety rails

| Rail                     | Rule                                                                                                 |
|--------------------------|------------------------------------------------------------------------------------------------------|
| Apple delete             | uuid must be missing in 2 full snapshots ≥ 10 min apart and unmatched by cascade → queued for user. On confirm: markdown file moved to Trash. |
| Markdown delete          | file gone (not dataless) → queued. Options: Restore File (re-export), Unlink (keep contact, clear stamp), Delete iCloud card (destructive confirm). |
| Mass-vanish breaker      | > 10 records or > 5 % vanish from either side in one run → halt everything, ask. Covers iCloud toggled off, account removed, root unmounted/evicted. |
| Blast radius             | > 25 Apple changes in one run → show plan, require approval. A record whose body goes into Contacts notes counts once, like any update (the notes enablement migration can push many). |
| Create gate              | §6 — any match ≥ 0.5 blocks auto-create.                                                             |
| Backups                  | vCard of whole store before any Apple write session; keep 10.                                        |
| Notes backup             | with Contacts.app scripting, the notes about to be overwritten are saved to `backups/apple-notes-<time>.json` before any note write (the vCard has no notes without the entitlement); keep 10. No backup, no note write. |
| Unknown notes            | a card Contacts.app scripting did not see makes the contact's note unknown, never empty; a failed notes read skips notes for the run (§8). |
| File writes              | `NSFileCoordinator`, temp file + `replaceItemAt`, CAS on (mtime, size, sha), skip identical bytes, re-parse before write. |
| Invalid YAML             | never written; listed in Activity.                                                                   |
| Unapplyable fields       | fields Apple refuses or that don't stick are recorded and not retried until they change.            |

A card id that vanishes while its stamp shows up on another card is identifier churn, not a delete (Google replaces cards we create, spike S9): the record is rebound silently. Only a card that is gone by id, stamp and cascade counts toward the Apple delete rail.

### As implemented (M3)

- **Gating.** `sync` writes to Apple Contacts only with `apple_writes: enabled` in `.c2mdsync/config.yaml` (default disabled). Without it the run writes markdown and reports every Apple change as `held … apple writes disabled`. Held changes are not errors, and the agreed base keeps them pending. Stamps are Apple changes too.
- **Backups.** An Apple write needs a `BackupReceipt`, which only `VCardBackup.backup` creates. No receipt means no write at all.
- **Apple delete.** A record that no contact references by stamp or card id, and whose note matches no unbound contact at 0.5 or more, is recorded in `vanished_records`. It is queued only when it is still missing at least 10 minutes after it was first seen. A contact that reappears clears it. The queue choices are `trash` (move the note to the Trash), `keep` (set `c2mdsync.status: detached`) and `restore` (create the contact again from the note, after the create gate).
- **Markdown delete.** The `missing-…` item offers `restore` (write the note again), `unlink` (forget the record, remove its stamps, never export the contact again) and `delete-contact` (delete every writable card of the contact).
- **Mass-vanish breaker.** It counts records newly missing on one side in this run. More than `mass_vanish_count` (10), or more than `mass_vanish_percent` (5 %) when at least 3 records vanished, stops the run before anything is written (exit 4). `--allow-mass-vanish` overrides it. Deletions are still only queued.
- **Blast radius.** Each record with Apple writes counts once (an update, create, delete, stamp or unstamp). More than the limit holds all Apple writes, the markdown writes still run, and the exit code is 2. `--max-apple-changes N` approves up to N.

## 10. Change detection and echo suppression

- M3 compared a full snapshot with the merge base on every run. M5 adds history-token acceleration (below, "As implemented (M5)").
- **Markdown**: canonical-model hash vs base (bytes never compared directly). FSEvents (file-level) triggers a debounced run. Own writes are remembered as (path, sha) for 30 s and ignored.
- **Apple**: full snapshot diff through M4 (thousands of contacts ≈ 1 s). From M5 the ObjC-shimmed change-history enumerator narrows the set; history fetch excludes `com.zmre.contacts2mdsync.*` authors (spike S3: works); a `DropEverything` event, a nil token, or error 603/604 → full snapshot. `DropEverything` is the main reset signal: a garbage token raised no error and no exception, it just returned `DropEverything` plus the full snapshot (S3). Group events arrive even with `includeGroupChanges = false`, so events are filtered by type. Saves made by Google sync after our own writes (for example, replacing a card we created) are not authored by us and show up as changes; comparison keys and the stamp-based re-fetch absorb them. `CNContactStoreDidChange` is only a debounced "go look" signal.
- **Server echo** (iCloud/Google reformatting our writes) is neutralized by comparison keys plus refreshing the base from a post-write re-fetch.
- **Notes through Contacts.app scripting** (§8): Contacts.app's saves carry no `transactionAuthor` of ours, so author exclusion does not cover them. The token read after the Apple batch (notes included) does; a late echo is recognized by `NotesOwnWrites` (card id and text hash, 30 s) but still read. A history event on a card triggers the re-read of that card's note, and only of the notes of re-read contacts.
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
- If the Contacts history token is expired or invalid (603/604, or a `DropEverything` event), the next run of any kind falls back to a full snapshot.
- When the app isn't running at all, the launchd schedule (§15) is the only trigger.

### As implemented (M5)

**History acceleration** (`SyncEngine.AppleChangeTracker`, used by `VaultSession.prepareSync` and so by the app, `sync`, `plan` and `watch`):

- The device state keeps a mirror of Apple Contacts in `meta.apple_cache`: the snapshot without image bytes, image sha256 per contact, the settings key (hash of `config.yaml` text and decision ids) and the history token it is current as of, lzfse-compressed JSON. Token and snapshot are one blob, so they can never disagree.
- An incremental read (`SyncRequest.appleMode = .incremental`, the default) asks `ContactStore.changes(since:excluding:)` for card-level events (`shouldUnifyResults = NO`) without this device's own authors (`com.zmre.contacts2mdsync.<deviceID>` and the export stamper's `…cli`; `excludedTransactionAuthors` takes exact names, so other devices' writes are *not* excluded). Changed cards, plus the cards of records whose note changed since the last scan (file-cache diff), are re-read with `ContactStore.refetch(cardIDs:siblingHints:)`: each card's unified contact (`unifiedContact(withIdentifier:)`) with all its cards (cache siblings, same-name cards, `isUnifiedWithContact`), plus all containers and groups. The patched mirror is what the planner sees.
- A full snapshot is taken instead, with the reason in the output and the session (`apple_read` full/incremental), when: the run asks for one (`.full`: launch, wake, sweep, Sync Now, `--full`); there is no cache or no token (first run, `.unsupported` history); `DropEverything`, a `nil` token or error 603/604 (`.reset`); the history read throws; **any card was deleted**; a group was added, renamed or deleted (group membership events only mark the member as changed); more than max(100, 20 %) cards changed; the config or the decisions changed; a possibly-deleted record is due for its confirming snapshot; a synced record has no card left in the patched mirror; or the plan would create a note for a contact whose image was not re-read (re-planned, `images-needed`).
- **Incremental runs never conclude deletions.** Deleted cards force a full snapshot. The planner gets `SyncInputs.appleSnapshotComplete = false` for patched snapshots: `planAppleDeletes` then only carries existing `vanished_records` entries forward — it records no newly vanished record, confirms nothing (no queue item, no trash) and adds nothing to the mass-vanish count. A vanished record whose 10 minutes have passed forces the next run to be full, so the two-snapshot rule still completes on its own. The vault side is always enumerated in full (parse cache), so note deletions are detected as before.
- Images of contacts that were not re-read have no bytes in the mirror; the patched snapshot marks them `imageUnavailable` ("unknown": never compared, never removed, the base keeps its hash). A note whose image changed is a vault change, so its contact is re-read with bytes.
- After a run that wrote to Apple, the mirror is the executor's post-write full snapshot and the token read just before it (`SyncResult.postWriteSnapshot` / `postWriteHistoryToken`), so our saves are never reported back. Otherwise the mirror is what the run read. A dry run (`plan`) advances the mirror too (it describes Contacts, not the sync), except when the breaker tripped.
- `meta.last_full_compare` records the last run *planned* on a full snapshot (any process on this device); the sweep window uses it.
- Not covered by events: linking or unlinking cards in Contacts.app (no history event type; S3 did not observe what is reported). A stale link in the mirror lasts until the next full compare (launch, wake, sweep, Sync Now). To verify with a scratch account (see Open issues in the M5 report).

**Triggers** (`SyncTriggers`):

- `SyncCoordinator` (actor) runs one request at a time through a `SyncRunner`. Live events (`.live`, `.rescanVault`) wait for 3 s of quiet (each event restarts the window, capped at 30 s after the first); `.launch`, `.wake`, `.sweep`, `.manual` start at once and absorb pending live events. Coalesced requests run full when any part needs it. Triggers during a run coalesce into one follow-up run. Status is published as an `AsyncStream<SyncCoordinatorStatus>`: `idle`, `scheduled(kind, startsAt)`, `running(kind, phase?)`, `finished(SyncRunSummary)`, `blocked(reason)`, `failed`, `skipped(kind, reason)`; from M6 also `following(device, check)` and `followingEnded` (§11).
- Another run on this Mac (local lock, waited `lockWait` = 5 s) → `blocked(.localRunInProgress)`, retried after 30 s up to 3 times. Another device's lease, the breaker, or a vault that is not ready → `blocked`, no retry (the next trigger or the sweep tries again).
- Sources: `ContactsChangeSource` (`CNContactStoreDidChange` → `.live`; our own saves post it too, and that run is a no-op because the history excludes our author), `VaultChangeSource` (FSEvents, file-level, recursive, `WatchRoot`; `.c2mdsync/` and dot paths ignored; `MustScanSubDirs`, `UserDropped`, `KernelDropped`, `RootChanged` → `.rescanVault`; own writes ignored through `OwnWriteRegistry`), `WakeSource` (`NSWorkspace.didWakeNotification` + 30 s, restarted by another wake), `SweepScheduler` (`NSBackgroundActivityScheduler`, repeats every `sweepInterval`, tolerance ¼) or `ClockSweepSource` (a plain timer, for `watch`), `LaunchCatchUp` (one `.launch`).
- FSEvents only trigger runs: every run enumerates the whole vault (the parse cache keeps it cheap), so merged or dropped events lose nothing; `.rescanVault` is a normal run tagged as such.
- **Own-write suppression:** `VaultSyncRunner` records every note and image a run wrote (path, sha256) and every note it trashed (path, no hash) in an `OwnWriteRegistry`; an FSEvent for such a path within 30 s is ignored while the file still has that content (or is still gone). An edit made right after our write has another hash and triggers a run.
- The sweep fires every interval; the coordinator skips it when `lastFullCompare` is within the interval (`skipped(.sweep, "full compare N min ago")`).
- **Settings** (`TriggerSettings`, `<state>/triggers.json`, per device and vault-independent, next to `device.json`): `live_sync` (default on; gates live, rescan, launch and wake triggers; Sync Now always works) and `sweep_interval_seconds` (default 7200, clamped to 1–6 h, `null` = off). Not in the vault's `config.yaml`, because that file is shared by every device through iCloud while watching and sweeping are properties of one Mac (laptop vs desktop, leader vs follower).
- Not implemented: the "network reachable after wake" condition (the 30 s delay stands in for it).

### Hosting in the app

The app wires these after the folder is chosen and the first sync is done:

1. Keep the folder's security scope open (`RootBookmark.open()`) for as long as live sync runs; FSEvents needs it.
2. `let ownWrites = OwnWriteRegistry()`; `let runner = VaultSyncRunner(root: root.url, environment: env, ownWrites: ownWrites)` with `env = CLIEnvironment.live()` and `env.trigger = "GUI"` (the runner overrides `trigger` per run with the kind: `Live`, `Launch`, `Wake`, `Sweep`, `Manual`, `Rescan`). `options` defaults to `SyncRequest(policy: .gui)`.
3. `let settingsStore = TriggerSettingsStore(directory: env.stateDirectory)`; `let coordinator = SyncCoordinator(runner: runner, settings: settingsStore.load())`.
4. `await coordinator.start([LaunchCatchUp(), ContactsChangeSource(), VaultChangeSource(root: root.url, ownWrites: ownWrites), WakeSource(), SweepScheduler()])`.
5. Observe `for await status in await coordinator.statusUpdates()` on the main actor for the menu bar and Overview; `lastSummary` holds the last run; refresh review data on `.finished`.
6. Sync Now → `await coordinator.syncNow()` (full, never debounced). Settings toggles → `settingsStore.save(s)` then `await coordinator.update(s)`.
7. Any other vault write the app makes outside the coordinator (export, review decisions) may record its files in `ownWrites`, or simply cause one no-op run.
8. On folder change or quit: `await coordinator.shutdown()` (stops the sources, waits for a run in progress, releases the vault lease), then close the scope.

From M6 the coordinator also owns the vault lease: the app creates it with `SyncCoordinator(runner: runner, settings: …, leaseKeeper: try? runner.makeLeaseKeeper())` (`LiveSyncController`). It heartbeats every 5 minutes while it runs, reports `following(device:check:)` when another device leads, and offers `takeOver()`, `releaseLease()` and `leaseStatus` (§11 "As implemented (M6)"). The app's Take Over goes through `coordinator.takeOver()` while live sync is hosted (Sync Now with `takeOver` otherwise), and Release Lease through `coordinator.releaseLease()` (`VaultSession.releaseLease()` otherwise).

## 11. Multi-device

- **Lease** `.c2mdsync/lease.json`: `{device_id, device_name, acquired_at, heartbeat_at, expires_at}`; heartbeat 5 min, TTL 20 min. Acquire: expired or explicit "Take Over"; write, wait ~60 s, re-read, proceed only if still ours. Advisory — an accidental double leader converges because merges are idempotent and identical writes are skipped.
- M3 (`LeaseManager`) renews its own unexpired lease without waiting. It skips the 60 s wait while no other device has ever used the vault and the lease was not someone else's. A sync refreshes the heartbeat when it finishes and leaves the lease in place until it expires. `contacts2md sync --take-over` takes it. The wait and the sleep are injectable (`CLIEnvironment.leaseSettle`, `sleep`), and tests use 0.
- **Followers** are read-only: they show status and dry-run diffs; user actions go to their own `decisions.jsonl`.
- **iCloud conflict versions** (`NSFileVersion`): canonically equal → auto-resolve keeping current; else raise a record conflict.
- **Handover** is safe because each device keeps its own base.

### As implemented (M6)

**Lease** (`SyncEngine.LeaseManager`, `LeaseKeeper`):

- `lease.json` gains `released_at` (markdown-schema §8). A lease is *free* when it is released or past `expires_at`. TTL 20 min, heartbeat 5 min. A holder whose heartbeat is older than 10 min (two missed heartbeats, or iCloud delivering them late) is *stale*: still the leader, but the UI and `status` offer Take Over.
- `LeaseManager.status()` gives this device's `LeaseRole` (`leader`, `follower`, `vacant`) and, for a follower, a `LeaseHolder` (device name, acquired, last heartbeat, expiry, stale).
- Acquire is write, settle (60 s), re-read: the re-read must show this device *and* the same `acquired_at`. Heartbeat and release are compare-and-swap on the bytes just read, so a take-over that landed in between is never overwritten. `heartbeat()` reports `renewed` or `notHeld`. `release()` writes `released_at`. `takeOver()` is acquire with `takeOver: true`.
- Every lease write goes through `VaultFS.write` (`NSFileCoordinator`, temp file + replace). When two devices write at once, iCloud keeps one write as `lease.json` and the other as a conflict version. Each lease read first resolves those versions by keeping the current contents, so after the settle wait both devices read the same winner. The simulation tests check that the loser follows.
- `LeaseKeeper` wraps a manager for one device and vault. `SyncCoordinator(…, leaseKeeper:)` calls `heartbeat()` every `heartbeatInterval` while it is alive. The loop is independent of runs, so a long first sync keeps the lease fresh. `shutdown()` releases the lease. `takeOver()` takes it and starts a Sync Now. A heartbeat (or a Take Over lost to another device) that sees a different leader than the last one reports `following(device:check: nil)`. When a heartbeat finds that the leader it was following has let the lease go (released or expired), the coordinator reports `followingEnded` and submits a `launch` catch-up run ("Mac B stopped leading; taking over"), which takes the lease (with live sync off that run is skipped; the report still tells the app it no longer follows).
- `executeSync` still refreshes the heartbeat at the end of every run, so the CLI and launchd keep the lease without a coordinator.
- **Exports take the lease too.** `contacts2md export --yes`, the app's first export (`UIVaultReader.sync` before this Mac has synced) and onboarding's export plan first (Contacts is read, nothing is written to the folder), then call `VaultSession.beginExport(takeOver:)`: the local lock (`sync.lock`, or `first-export.lock` in the state root for a folder that has no config yet) and `LeaseManager.acquire`. While another device holds an unexpired lease nothing is written: the CLI prints `note     following <name>: … export skipped (nothing written) …` and exits 0, the app gets `UISyncOutcome.leaseHeldElsewhere` (banner "Mac B is syncing this folder; this Mac will follow", with Take Over), and onboarding shows the same message (`ExportBlocked`). A vault with no lease, or a free one, gets this device's lease; the export refreshes its heartbeat at the end and keeps it until it expires, as after a sync. `export --yes --take-over` (and Take Over in the app) takes the lease first. A run that cannot read Contacts writes nothing, not even the lease.

**Follower mode**:

- When another device holds the lease, `VaultSyncRunner` returns `SyncRunOutcome.following(holder, check)` instead of `blocked`. It runs `VaultSession.followerDryRun`: scan, read Contacts, plan, and record the observations in this device's state (review queue, file cache, Contacts mirror, an Activity row with command `follow`). Nothing is written to the vault or to Contacts. `check` is `FollowerCheck.checked(summary)`, whose counts are what the leader still has to do as seen from here (held Apple changes are counted as held, as in the leader's own summary; `changeCount` adds images, iCloud version resolutions and the config file), or `.failed(message)` when the dry run could not be made (no Contacts access, first sync not done on this Mac, folder unreadable); a failure is reported, never swallowed. The coordinator publishes `following(device: LeaseHolder, check:)` (`check` is `nil` when a heartbeat noticed the leader) and keeps `lastFollowerSummary` / `lastFollowerError` (both cleared by a run of its own). It does not retry; the next trigger checks again.
- The app folds the check into `UILiveState.followerCheck` (dropped when another device starts leading, cleared by `followingEnded`). Check for Changes and review answers made while following re-plan and replace it (`UIPlanSummary.planned`). The Overview shows "Mac B leads; it still has N changes to apply" (or "nothing left to apply"), and in red "Mac B leads; this Mac could not check what is left" with the message; the toolbar then says "Following Mac B: check failed".
- Review decisions made on a follower go to that device's own `decisions.jsonl` (one writer per file). The leader reads the union on its next run and executes them. Conflict resolutions are bound to side hashes computed from the values, so a decision made on the follower applies on the leader when both see the same data.
- `contacts2md sync` on a follower prints a `note following …` line, runs the same dry run (so `review list` works there), prints `follow   leader still to do: …` and exits 0.
- A follower's merge base is never refreshed, because it does not execute. When it takes over, both sides look changed *to the same value* and the run converges with no writes (§4). A test leads three rounds of edits on one device, hands over, and checks that the new leader writes nothing.

**Decision log across devices** (`DecisionLog.read`):

- *Union*: every device's log plus the lines of its unresolved iCloud conflict versions. An append-only log loses nothing when versions are merged. Decisions with the same id are read once.
- *Order*: time, then device id, then the order the lines were appended. Every device sees the same order, so "latest wins" means the same thing everywhere.
- *Partial lines*: an unterminated last line that does not parse is a line iCloud is still delivering. It is skipped without a warning (`partialLines`) and read once it is complete. Unreadable *complete* lines are still reported. Appending to this device's log drops such a fragment instead of burying it, and merges the log's conflict versions first (`mergeConflictVersions`, also run after every executed sync). Only the owning device rewrites its log.
- *Conflicts*: `DecisionSet` keeps only the latest decision per review item (`itemID`), so an item re-decided on one device, or decided differently on two, never applies both answers. When the competing decisions come from different devices within an hour of each other (they could not have seen each other), `read` reports a `DecisionConflict`: `item … decided differently on Mac A (trash) and Mac B (keep); the latest (Mac B: keep) wins`. `readAll` adds it to the warnings, so the CLI prints `WARNING decision`.

**iCloud conflict versions** (`NSFileVersion`):

- `VaultFS.unresolvedConflictVersions(_:)` and `resolveConflictVersions(_:keeping:)`. `LocalVaultFS` uses `NSFileVersion.unresolvedConflictVersionsOfItem`, `replaceItem(at:)`, `isResolved` and `removeOtherVersionsOfItem` inside a coordinated write. Enumeration reads `ubiquitousItemHasUnresolvedConflicts`, so versions are only fetched for flagged files (`FileEntry.hasUnresolvedConflicts`, `VaultEntry.conflictVersions`). Versions are identified by the sha256 of their bytes, which is the same on every device.
- Notes: a version that is canonically equal to the current note (the same normalized contact, so quoting, key order and formatting do not count; for other notes the same text up to line endings and trailing whitespace) is resolved by keeping the current contents, without asking. Otherwise the plan raises `ReviewItem.fileVersionConflict(FileVersionConflict)` (`version-…`, choices `keep-current` / `keep-other:N`, with each version's device name and changed keys) and pauses the note's record, like a copied note. `keep-other:N` makes that version the current contents and pauses the record for that run. The next run syncs the result as an ordinary markdown edit. A decision applies only while the current contents and the version set are still the ones it was made against. A later edit or another version asks again.
- `.c2mdsync/config.yaml`: equal settings resolve silently. Different settings raise the same review item (no record paused). `lease.json` and `devices/<id>.json` keep the current contents. Decision logs are merged as above.
- Resolutions are planned (`ExportPlan.versionResolutions`) and executed only by the leader (`SyncExecutor` and `ExportExecutor`, before any note write). Followers never write the vault.
- *Conflicted copies*: iCloud sometimes keeps the losing side as a sibling file (`Jane Doe 2.md`). It carries the same `c2mdsync.id`, so it is a copied note (§6 "Vault-side duplicates"): the record pauses and nothing is duplicated. `ReviewItem.conflictedCopyPaths` names such copies, and the summary says `(iCloud conflicted copy: …)`. `keep:N` keeps one. The other is ignored and stays on disk, so no edit is lost.
- `LocalVaultFS` cannot be tested against real iCloud conflicts here: there is no public API to create a conflict version. Its code path is exercised only for "no versions". The engine logic runs against `InMemoryVault` versions and the `SimulatedICloud` replicas.

**Identity when a device joins**: covered by tests in both stamp modes. With `stamp_contacts` on, the joining device's first import binds every contact by its stamp (even one renamed in Contacts since) and creates nothing. With stamps off, it re-finds notes as orphans by strong keys at ≥ 0.9 and creates nothing; two same-name contacts without strong keys are blocked by the orphan title gate and go to review, never duplicated. The existing `WARNING identity` line still asks for stamps.

**Not done**: the "conflicted copy" files iCloud creates are only recognised by name (`<stem> <n>.md` next to `<stem>.md`) and only when they share the `c2mdsync.id`. A conflicted copy of a markdown-only note is just another markdown-only note.

**Open issues** (after the M6 follow-ups):

- A Mac that has never synced a folder another device leads cannot follow: follower mode needs this Mac's merge base, which only its first export creates, and that export waits for the lease. It shows the export plan (Check for Changes) and the follow banner, and its first sync runs once the leader quits (released lease) or its lease expires, or on Take Over. Nothing retries the first export by itself; the user runs it again.
- An export plans before it takes the lease (so a run without Contacts access leaves no lease behind). When the settle wait (≈ 60 s) runs, the plan is that old when it is written. Note writes are compare-and-swap (`WriteExpectation`), so a note edited meanwhile is not overwritten: its write fails (reported, exit 5 in the CLI) and the next run plans it again.
- Release Lease while live sync runs here only frees the lease until this Mac's next run, which takes it again. Stopping this Mac from leading for longer means pausing live sync (or quitting).
- Real iCloud: lease contention, `NSFileVersion` conflict versions and their `keep-other:N` resolution are still only exercised against `InMemoryVault` versions and `SimulatedICloud`; spike S6 is open.

## 12. Scope

See `scope:` in [markdown-schema.md §8](markdown-schema.md#config-yaml-sketch). Precedence: contact rule > group rule; exclude > include. Leaving scope never deletes anything: `on_leave_scope: detach` sets `c2mdsync.status: detached` and stops syncing that file.

`sync` enforces it (`SyncScope`). `exclude_contacts` wins over everything. `markdown.include_paths` limits where synced notes may live. `include_contacts` then wins over groups, containers and `require_tag`. `exclude_groups` wins over `include_groups`. `containers` lists account kinds (`icloud`, `google`, `local`, `exchange`, `carddav`), and a contact needs a card in one of them. `require_tag` checks the note's tags (or, for a contact without a note, its managed tags). An unbound contact outside scope is not exported. A bound one is detached. Contacts of detached notes are never synced, in `export` too, and a detached note is never adopted automatically.

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
- Scenario DSL (`SyncTestSupport.SyncHarness`, `World` in the tests): one test per row of the merge table; echo convergence; unapplyable; delete queues; breakers. The scenario suites run with `stamp_contacts` off and on.
- Property tests: random edits on both sides → sync twice → fixpoint, no duplicates, no data loss beyond explicit deletes.
- Multi-device simulation: two state stores, shared `InMemoryVault` with propagation delay, one Apple store with delay. As implemented (M6): `SimulatedICloud` gives each device its own vault replica. A change reaches the others after a delay. Two devices changing one file before seeing each other's change is a conflict, kept as an unresolved version or as a `Name 2.md` copy. `SimulatedContactsCloud` does the same for Contacts, one replica per device. Tests cover alternating leaders with edits on the follower (convergence, one note per contact, no duplicate contacts, no conflicts at all), lease contention, a user edit racing the leader's write, and follower decisions.

## 15. Headless CLI (cron / launchd)

After the GUI has been set up and one sync has completed, `contacts2md sync` runs unattended. Anything that needs a human decision is **skipped**, left queued for the GUI, and printed to stdout as a warning.

### Packaging: the CLI is the app binary

macOS ties both Contacts permission (TCC) and the sandboxed security-scoped folder bookmark to the app's code identity. A separate CLI binary would need its own Contacts grant, which it can't request without a UI, and it couldn't read the app's bookmark. So:

- The app executable takes subcommands. `Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync sync` runs headless: no `NSApplication`, no windows, no Dock icon.
- The nix package (and a `just` recipe) installs a `bin/contacts2md` wrapper that `exec`s that binary.
- It shares the app's sandbox container, so it reads the same bookmark, device state DB and config.
- If Contacts access hasn't been granted, the CLI fails fast (exit 3) and tells you to open the app once. It never prompts.
- **[spike S11, partial]** Started directly by launchd or cron, a binary is its own responsible process: the spike binary, authorized when run from the terminal, reported `notDetermined` under both and never prompted. So a terminal's grant does not carry over. Still to verify: whether the *app's* executable, exec'd directly by launchd, uses the app bundle's grant. Until then, keep the fallback: launch via `open -g -a Contacts2MdSync --args sync --wait`, which keeps the app as the responsible process.

### Commands

| Command                       | Does                                                                         |
|-------------------------------|------------------------------------------------------------------------------|
| `contacts2md status`          | Configured?, last sync time and device, lease holder, pending review counts  |
| `contacts2md plan`            | Dry run: what a sync would change, plus what would be skipped                 |
| `contacts2md sync`            | Run one sync cycle unattended                                                |
| `contacts2md export` (M1)     | One-way Apple → markdown; dev/testing                                        |
| `contacts2md config` (M3)     | Show or set `apple_writes` and `stamp_contacts`; `--notes on|off` (this Mac) |
| `contacts2md lease` (M6)      | Show, take over or release the vault lease                                   |

Flags: `--quiet` (warnings and errors only), `--json` (one JSON document on stdout for scripting), `--verbose`.

**M1 as implemented** (`Contacts2MdCLI` library; `contacts2md` dev executable; app binary dispatches when its first argument is `status`, `plan`, `export` or `help`, otherwise starts the GUI):

```
contacts2md status --root <dir>
contacts2md plan   --root <dir> [--default-folder Inbox] [--region US] [--restore-missing]
contacts2md export --root <dir> [--default-folder Inbox] [--region US] [--restore-missing] [--yes [--stamp]]
common: --quiet  --verbose
```

- `--root` is required in M1 (security-scoped bookmarks arrive with the GUI setup flow).
- `export` without `--yes` prints the plan and writes nothing (same as `plan`).
- `--stamp` requires `--yes`; it takes a vCard backup to `<state>/backups/` first and refuses to stamp if that fails (nothing is written at all in that case).
- `--default-folder` / `--region` are saved into `.c2mdsync/config.yaml`.
- Plan lines: `create md`, `update md <path>  (changed keys)`, `write image`, `write config`, `stamp apple`; executed lines: `created`, `updated`, `wrote`, `backup`, `stamped`. Then `WARNING …` lines, the `summary` line, and for dry runs a `note` line.
- `--json` arrived in M3 (see below).
- Usage errors exit 64 (ArgumentParser's `EX_USAGE`), in addition to the table below.

**M2 as implemented** (app binary also dispatches on `review`):

```
contacts2md status [--root <dir>]
contacts2md plan   [--root <dir>] [--default-folder F] [--region R] [--restore-missing]
                   [--auto-adopt first-import|always|never] [--allow-undownloaded]
contacts2md export [same as plan] [--yes [--backup] [--stamp]]
contacts2md review [list] [--root <dir>]
contacts2md review decide <item-id> <choice> [--root <dir>]
contacts2md review decide <dup-id> --group 1,2 [--group 3 …] [--exclude 4,5] [--root <dir>]
contacts2md review adopt-all [--min-confidence 0.3] [--root <dir>]
common: --quiet  --verbose
```

- `--root` is optional: without it the folder chosen in the app is used (an app-scope security-scoped bookmark in `<state>/root.bookmark`; the CLI resolves it and calls `startAccessingSecurityScopedResource`). With `--root` inside that folder the bookmark is still used for sandbox access. No bookmark and no `--root`, or a bookmark that no longer resolves → exit 3 with a message to open the app. Never prompts.
- The header is `contacts2md <command>  <time>  device=<computer name>  root=<path>`.
- `plan` and `export` save the pending review queue to the device state; `review list` reads it (no Contacts access needed) and prints `item <id>  <summary>` plus its choices. Item ids are stable (`dup-…`, `match-…`, `copy-…`, `merge-…`, `missing-…`, `invalid-…`, `icloud-…`). `review decide` appends a decision to this device's log; it takes effect on the next `plan`/`export`. Choices: duplicates `distinct` | `only:N`, or a partition with `--group` / `--exclude` (member numbers as `review list` prints them under the item, with each member's accounts, note, earlier answer and why it is linked; each `--group` is one person with one note, different groups are different people, `--exclude` members are not synced; every member needs a group or `--exclude`, otherwise the command exits 64 naming the missing ones; recorded as `cluster-resolve` with choice text `resolve:1,2/3;exclude:4`, which `review decide <id> resolve:1,2/3;exclude:4` also accepts); possible matches `adopt` | `distinct` | `ignore`; copied notes `keep:N`; merge-records, missing and invalid items have no CLI choice. `review adopt-all` adopts every pending match whose note is claimed by one contact.
- `export --yes` copies every note it will rewrite to `<state>/<vault_id>/backups/notes-<time>/` first; `--backup` also saves a vCard backup (always done before `--stamp`; the app's first export always does it).
- New output lines: `adopt md <path>  ← "<title>" adopted (reasons)` / `adopted`, `fixup md <path>  (image path after move)` / `fixed`, `backup md <folder>`, `WARNING match|duplicate|copied|missing|invalid|icloud|yaml|decision …  [<item-id>]`, and `adopted N` in the summary.
- Exit 1 only for contact-related review items or skipped contacts that need a decision; non-contact notes with invalid YAML and contacts excluded by decisions do not count.
- `status` adds `review <n> pending (as of …)` and Apple `linked=` / `cards=` counts.
- `bin/contacts2md` in the nix package (and `just app-cli`) execs the app binary.

**M3 as implemented** (app binary also dispatches on `sync` and `config`):

```
contacts2md sync   [--root <dir>] [--max-apple-changes N] [--allow-mass-vanish] [--allow-undownloaded] [--take-over]
contacts2md plan   [--root <dir>] [--one-way] [--max-apple-changes N] [export options]
contacts2md config [--root <dir>] [--apple-writes enabled|disabled] [--stamp-contacts true|false]
                   [--notes on|off] [--quit-contacts true|false]     # notes: this Mac only
contacts2md review decide <item-id> <choice>
common: --quiet  --verbose  --json
```

- `sync` waits up to 60 s for the local lock (`<state>/<vault_id>/sync.lock`, `flock`), then takes the lease. If another run holds the lock or another device holds the lease, it prints a `note` and exits 0. It needs a vault exported or synced on this device before, else exit 3.
- `plan` shows the two-way plan once the vault has been exported or synced on this device. Before that, or with `--one-way`, it shows the export plan.
- Plan lines add `update apple`, `create apple`, `delete apple`, `stamp apple`, `unstamp apple`, `trash md`, `detach md`, `link md` and `held apple … — <reason>`. Executed lines are `updated apple …`, `created apple`, `deleted apple`, `stamped apple`, `unstamped apple`, `trashed md`, `detached md`, `linked md`, `backup apple` and `backup md`. Held stamps are summarized in one line.
- New warnings: `WARNING conflict`, `WARNING delete`, `WARNING unapplyable`, `WARNING blocked`, `WARNING identity`, `WARNING limit` (blast radius) and `WARNING create`. The breaker message goes to stderr.
- `summary  apple c/u/d …  md c/u/d …  skipped …  pending-review …  held …  <time>`: for markdown, `d` counts notes moved to the Trash.
- `--json` prints one document: `command`, `started_at`, `device`, `root`, `exit_code`, `items` (`verb`, `side`, `text`), `warnings`, `notes`, `errors`, `summary`, `reviews`, `conflicts`, `settings`. Errors also go to stderr.
- Review choices: conflicts `apple | markdown | both`; deleted in Contacts `trash | keep | restore`; note deleted `restore | unlink | delete-contact`; markdown-only notes `add | ignore`. Markdown-only items are informational and never make the exit code 1.
- `status` adds `sync apple_writes=… stamp_contacts=… devices=N`, the lease holder, the identity warning, and counts of conflicts, deletions and markdown-only notes.
- Exit codes follow the table below. Write failures give 5. A tripped breaker gives 4 even for `plan`.

**M5 as implemented** (app binary also dispatches on `watch`):

```
contacts2md sync  [--full] [M3 options]
contacts2md plan  [--full] [M3 options]
contacts2md watch [--root <dir>] [--debounce 3] [--sweep 2|off] [--no-catch-up] [--lock-wait 5]
```

- `sync` and `plan` read Apple through the change history when the token is valid, else a full snapshot. They print `apple    incremental: N changed cards, M contacts re-read` or `apple    full snapshot (<reason>)`; `--json` adds the setting `apple_read` (`full`/`incremental`). `--full` forces a full snapshot.
- `watch` (development and testing; also useful headless) runs the `SyncCoordinator` with every source (`LaunchCatchUp` unless `--no-catch-up`, Contacts notification, FSEvents on the root, wake, a clock sweep timer) until Ctrl-C or SIGTERM, keeping the main run loop running. Lines: `watch    live  debounce=…  sweep=…  catch-up=…`, `running  <kind>`, `synced   <kind>  <time>  apple c/u/d …  md c/u/d …  review N  (<apple read>)  <seconds>`, `WARNING  held …`, `WARNING  pending …`, `note     blocked: …`, `ERROR    …` (breaker, failures), and `--verbose` adds `scheduled`, phases, `skipped` and `idle`. It needs a vault synced on this Mac before (exit 3), uses the headless decision policy, and exits 0.
- Sessions carry per-side counts (`SessionRecord.sides`: Apple and markdown created/updated/deleted, held count and reason, `apple_read`); older rows decode with `sides == nil`.

**M6 as implemented** (app binary also dispatches on `lease`):

```
contacts2md lease [status|take-over|release] [--root <dir>]
contacts2md status    # adds role and heartbeat to the lease line, one line per other device
contacts2md sync      # as a follower: dry run, info lines, exit 0
```

- `status`: `lease    <holder> until <time>[ (expired)| (released)]  role=leader|follower|vacant  heartbeat=<time>[  STALE (no heartbeat for over 10 min)]`, or `lease    none  role=vacant`; then `device   <name>  last sync <time>` for every other device. `--json` adds the setting `lease_role`.
- `lease take-over` takes the lease (write, settle about 60 s when other devices use the vault, re-read). It prints `took     lease …`, or exits 5 when another device wrote at the same moment and kept it. `lease release` prints `released lease …`, or a note when this Mac did not hold it. Both end with the `lease` line.
- `sync` while another device leads: `note     following <name>: it leads syncing for this vault until <time>[ (stale: …)]; this Mac only checks (dry run, nothing written). Decisions recorded here are carried out by <name>. …`, then (once synced on this Mac) `follow   leader still to do: apple N changes  md N new, N updates  review N`. Exit 0. `--take-over` still takes the lease first.
- New lines: `resolve md <path>  (identical iCloud versions; current kept | current kept (decision) | iCloud version kept (decision))` in plans, `resolved md …` after a run, and `WARNING version <summary> — record paused; keep one in the app or `review decide` [version-…]`. Copied-note warnings name iCloud conflicted copies.
- Review choices: iCloud versions `keep-current | keep-other:N`.
- `export --yes [--take-over]` takes the local lock and the lease after planning, like `sync` (§11 "Exports take the lease too"). While another device leads: `note     following <name>: it leads syncing for this vault until <time>[ (stale: …)]; export skipped (nothing written). …`, exit 0. Another run holding the lock: a note, exit 0. `--take-over` requires `--yes` (exit 64 otherwise).

**Contacts notes (notes scripting) as implemented** (§8):

```
contacts2md config [--root <dir>] [--notes on|off]   # this Mac's setting, not the vault config
```

- `--notes` writes `notes_sync` (`"on"`/`"off"`) to `<state>/notes.json`, next to `triggers.json`, together with `quit_contacts_after_sync` (default true). It is per Mac because the Automation permission is. `--quit-contacts true|false` sets `quit_contacts_after_sync`. `config` prints `wrote    settings notes_sync=on  quit_contacts_after_sync=true (this Mac)` and `notes    notes_sync=on  source=Contacts.app scripting  permission=granted  quit_contacts_after_sync=true` (`source=off (bodies are markdown-only)` when off; `source=Contacts entitlement` without the permission and quit fields when entitled). Turning it on without permission adds a note: the command line never asks; allow it in the app (Settings ▸ Advanced ▸ Contact notes), or in System Settings ▸ Privacy & Security ▸ Automation when denied. It also points at `contacts2md plan` to preview the first notes sync. The permission shown is read without launching Contacts.app, so it can be `unknown`.
- `status` prints the same `notes` line.
- `plan` and `sync`, after the `apple` line:
  - `notes    Contacts.app scripting: first notes sync on this Mac; every body is merged without a base`, then `notes    12 into markdown, 3 into Contacts (largest 4,812 chars: Jane Doe), 140 already equal, 2 conflicts` on a fresh start; later only when records without a body base move or conflict (`notes    Contacts.app scripting; no notes base yet: …`).
  - `notes    apple  <title>  (markdown body → Contacts: <n> chars, <l> lines)  <path>` for every markdown body bound for Contacts; with `--verbose` also `notes    md     <path>  (Contacts note → markdown: <n> chars)`.
  - `note     <n> markdown bodies held for Contacts — <reason>` when Apple writes are held.
  - `update apple <title>  (body 1,234 chars)` (or `body cleared`) instead of a bare `body`.
  - `WARNING  notes      Automation permission for Contacts not granted; notes skipped` when notes are on but not permitted, or `… Contacts notes could not be read (…); notes skipped`. Not a change on either side; the exit code is unaffected.
  - After a sync: `WARNING  notes      note for card <id> not kept: …` per refused card; with `--verbose`, `notes    read N bulk + M cards, own echoes K, written W`.
- `--json` adds the setting `notes` (`entitlement`, `scripting`, `skipped` or `off`); `config` and `status` add `notes_sync` and `notes_source`.
- Sessions record `sides.notes` and `sides.notes_to_contacts` / `notes_to_markdown`; `SyncRunSummary` carries `notesToContacts`, `notesToMarkdown` and `notesWarning` for the app.

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
| Another device holds the lease                             | Dry run only (M6: status and review queue refreshed here, nothing written), info line, exit 0. `export --yes` writes nothing either (note, exit 0) |
| GUI instance on this Mac is syncing                        | Wait up to 60 s for the local lock, then no-op as above                            |
| Not configured / first sync not done                       | Error, exit 3                                                                      |
| `notes_sync: on` without Automation permission for Contacts | Notes skipped (never prompts), `WARNING notes`, no body change on either side, exit code unaffected |

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
  };
  ```

  This creates the user agent `org.nixos.contacts2mdsync-sync`, which runs `contacts2md sync --quiet`. The log goes to `<primaryUserHome>/Library/Logs/Contacts2MdSync.log` by default. launchd needs an absolute path there, so the module requires `system.primaryUser`.
- **cron may work** (`0 * * * * /Applications/Nix\ Apps/Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync sync`), subject to spike S11. In the spike, cron behaved the same as launchd (`notDetermined` for an ungranted binary).
- Settings ▸ General gets a "Sync every [1 hour ▾] in the background" toggle that installs the same LaunchAgent via `SMAppService` for non-nix installs.

### Shared engine guarantees

- Headless and GUI runs share one `SyncEngine` code path. The only difference is a `DecisionPolicy`: GUI = queue and present; headless = queue and report. There's no separate "CLI logic" to drift.
- A local lock file (`flock` in the app container) serializes GUI, CLI and launchd runs on one Mac. The vault lease serializes devices.
