# Contacts2MdSync — Plan

## Context
Greenfield SwiftUI app (macOS first, iPadOS/iOS later). Goal 1: export Apple Contacts into mbr-format markdown (`type: person|organization` frontmatter) under a user-chosen root (e.g. `~/Notes/Contacts`). Goal 2: two-way sync. Files may be moved freely into subfolders of the root; identity, relationships, and sync must survive. Groups ↔ tags. Strong guards against duplicates (user has iCloud+Google cards; Contacts links same-name pairs automatically: spike count 1255 linked pairs, 98 Google-only, 1172 iCloud-only). Nix flake for devShell + nix-darwin install.

M0 deliverable: scaffold the repo, `flake.nix`, XcodeGen project, empty Swift package skeleton, and commit the design docs below into `docs/`. No sync logic yet — that starts at M1.

## Research facts that drive the design
- **mbr** (zmre/mbr-markdown-browser `contact.rs`, `relationships.rs`): contact detected only by `type:`. Link resolution for `relationships[].to: "[[X]]"` and `company: "[[Org]]"` is **global by name** (title → alias → filename stem, case-insensitive) → wikilinks survive moves; path links break. Always write `title:`. Unknown frontmatter keys tolerated; YAML parse error drops whole frontmatter. Multi-value fields: emit list-of-single-key-maps (`- mobile: "+1…"`). Dot-dirs hidden by mbr. Note body = notes.
- **Contacts framework**: `CNContact.identifier` per-device, can change; no public modification date/etag; no public API to link cards. `CNChangeHistoryFetchRequest` enumerator is `NS_SWIFT_UNAVAILABLE` → ObjC shim w/ `@try`. No link/unlink events. Groups only in iCloud/Local containers. Notes key needs `com.apple.developer.contacts.notes` (request form, slow) else error 102. `CNContactRelation` is name-only. Unfetched-key access throws ObjC exception → fetch exact keysets.
- **Nix**: xcodegen 2.44, swiftlint, swift-format, xcbeautify, periphery, create-dmg in nixpkgs (aarch64-darwin). nix-darwin copies `Applications/` into `/Applications/Nix Apps` (signature preserved). User's Nix sandbox=false. Ad-hoc signatures re-trigger TCC each rebuild → stable Developer ID release is the long-term install path.

## User decisions
| Topic              | Decision                                                                                                                                                                                                                                                       |
|--------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Signing            | Paid account; Developer ID + notarize; request Notes entitlement now                                                                                                                                                                                           |
| Notes field        | Apple Notes ↔ entire markdown body (feature-detected; markdown-only body if not entitled)                                                                                                                                                                      |
| Identity           | Own UUID in `c2mdsync.id` + stamped on iCloud card as URL label `c2mdsync`, value `x-c2mdsync:<uuid>`                                                                                                                                                          |
| Write home         | iCloud underlying card; new contacts created in iCloud container                                                                                                                                                                                               |
| Trigger            | Sync Now + live watch (debounced CNContactStoreDidChange + FSEvents) + headless CLI `sync` for cron/launchd                                                                                                                                                    |
| Headless mode      | After setup + first sync, `contacts2md sync` runs unattended; anything needing a human is skipped, left queued for the GUI, and printed to stdout as a warning                                                                                                 |
| Devices            | Multiple devices from day one → per-device state + vault lease                                                                                                                                                                                                 |
| Tags ↔ groups      | Two-way for **managed tags only** (tags mapped to existing Apple groups in config)                                                                                                                                                                             |
| Deletes            | Never automatic. Apple delete → queued; on confirm, markdown file is deleted (move to Trash). Markdown delete → queued; on confirm delete iCloud card (or restore file / unlink)                                                                               |
| Unlinked dup cards | One markdown file ↔ one unified contact; clusters surfaced in Duplicates UI with "open in Contacts to link", "distinct", "sync only this one". No merge in v1. Most iCloud+Google pairs are linked by Contacts itself, so clusters are a residual review queue |

## Architecture (summary — full version goes to `docs/architecture.md`)
**Layout**
```
flake.nix  justfile  .gitignore  README.md
App/project.yml                 # XcodeGen (macOS target now, iOS in M7)
App/Contacts2MdSync/                     # SwiftUI app, Info.plist keys, entitlements (Dev / Release)
Packages/Contacts2MdSyncKit/             # local SwiftPM package — all logic, testable headless
  ContactModel  MarkdownCodec  ContactsShim(ObjC)  ContactsAdapter
  VaultIndex  SyncEngine  SyncTestSupport  contacts2md (CLI; see architecture §15)
docs/  plan.md architecture.md markdown-schema.md ui.md spikes.md
Spikes/
```
Deps: Yams (parse), PhoneNumberKit (comparison keys), GRDB (per-device state), swift-argument-parser (CLI). Engine sees only protocols: `ContactStore`, `VaultFS`, `SyncStateStore`, `Clock`, `DeviceIdentity`; fakes simulate unified cards, ID churn, server-normalization echo, missing entitlement.

**Three state tiers**
1. Note frontmatter (shared): standard mbr fields + `apple:` extras (phonetic names etc.) + `c2mdsync: {id, status?}`. No timestamps/device data → clean git diffs, no iCloud conflicts.
2. `<root>/.c2mdsync/` (shared, iCloud-synced): `config.yaml` (vault_id, default_folder, images_folder `_images`, region, group↔tag map, scope, limits), `lease.json`, `devices/<id>.json`, `devices/<id>/decisions.jsonl` (append-only user intents, single writer each).
3. Per-device SQLite (`~/Library/Application Support/Contacts2MdSync/<vault_id>/state.sqlite`): CN ids per record, base snapshot + per-field hashes, file cache, history token, pending queue, unapplyable fields. Per-device base fails safe on leader handover.

**Identity & duplicates**: matching cascade — stamp URL (1.0) → cached CN id (0.95; a Google card we just created is cached only after it is found again by stamp, because Google sync gives it a new id) → email/phone+name (0.9) → email/phone only (0.7) → name+org (0.5) → name (0.3). Any candidate ≥0.5 blocks auto-create on either side → review. Union-find over unified contacts on strong keys detects unlinked iCloud/Google pairs (the residue that Contacts' automatic linking misses). Records are keyed on stamp + underlying card ids; a linked contact's unified id is synthesized and volatile. First import = dry-run plan, applied only on confirm. vCard backup of all contacts before any Apple write session (keep 10). Copied files (duplicate `c2mdsync.id`) pause that record until resolved. Files are never renamed automatically; filename `<Title>.md` in default folder, collision → `Title (Company).md` → `Title 2.md`.

**Merge**: per-field three-way vs per-device base using normalized comparison keys (E.164 phones, lowercase emails, etc.). One-side change → apply; both-same → adopt; both-different scalar → conflict (Keep Contacts / Keep Markdown); multi-value additions union; element conflicts offer Keep Both; body uses diff3; `title` markdown-owned. Base refreshed from re-fetch after every write → server normalization stops echoing. Apple-side values are computed from the underlying cards (union for multi-value fields, fixed card precedence for single-value fields), never read from the unified view. Edits and deletes go to every card holding the value; single-value fields are written to all linked cards that have them; never save a unified mutable copy (it writes to every card). Verify-after-write per underlying card; fields that won't stick → `unapplyable` (anti ping-pong). Conflict resolutions bound to side hashes; stale → regenerated.

**Relationships**: Apple relation labels → mbr types (father/mother→parent+label, spouse, sibling, child, manager→reports_to, assistant, others → snake_case custom type). Names resolved to records → `to: "[[Title]]"`; unresolved → plain name. Never write reverse/derived edges. Title rename → old title added as alias, managed `to:` refs rewritten, Apple relation names on other cards updated; non-contact notes only via explicit UI action.

**Groups/tags**: managed set = groups map in config (seeded from iCloud/Local groups on first import). Set-based 3-way merge over managed tags; user tags untouched. Contact without iCloud card can't join group → unapplyable warning.

**Safety rails**: Apple delete must persist across 2 snapshots ≥10 min apart and not rematch before queuing. Mass-vanish breaker (>10 records or >5% gone either side → stop & ask). Blast-radius approval when >25 Apple changes. Dataless iCloud files never treated as deleted. Atomic coordinated writes with compare-and-swap; skip writes when bytes identical; re-parse emitted YAML before writing.

**Multi-device**: advisory lease in `.c2mdsync/lease.json` (heartbeat 5 min, TTL 20 min, write-wait-reread). Followers read-only; their decisions go to their own decisions.jsonl for the leader. `transactionAuthor = com.zmre.contacts2mdsync.<deviceID>`, excluded on history fetch.

**Scope (future, shape defined now)**: `scope:` in config.yaml — containers, include/exclude groups, include/exclude contacts (by c2mdsync id), markdown include/exclude path globs, optional `require_tag`; `on_leave_scope: detach`. Contact rules beat group rules; exclude beats include.

## UI (full mockups go to `docs/ui.md`)
Sidebar: Overview · Review (Conflicts, Markdown Only, Deletions, Duplicates — badged) · Library (All Contacts) · Activity. Toolbar: Sync Now (⌘R), Live toggle, lease/status, inspector. Overview: status line, Needs Review (only when nonzero), Since Last Sync (changed in Contacts / Markdown), This Session table (created/updated/deleted × side), totals. Conflicts: per-field Previous/Contacts/Markdown with segmented Keep choice + batch. Markdown Only: table with folder, possible match (default Link not Create), checkboxes, "Add N to Contacts". Deletions: two queues, non-destructive defaults, destructive confirm alert. Duplicates: side-by-side cards with match reasons. Onboarding: access → folders → read-only preview with counts → duplicate review → "Run First Sync". Settings: General/Folders/Accounts/Scope (disabled "Planned")/Advanced (notes entitlement status, lease, reset). MenuBarExtra compact status. iPhone: stack collapse, swipe actions, widget instead of menu bar.

## Milestones
- **M0 (this session after approval)** — repo scaffolding: `git init`; `flake.nix` (inputs nixpkgs-unstable; systems aarch64-darwin; `devShells.default` mkShellNoCC: xcodegen swiftlint swift-format xcbeautify periphery create-dmg just; shellHook unsets DEVELOPER_DIR/SDKROOT; `packages.default` impure xcodebuild build with `__noChroot`, `HOME=$TMPDIR`, ad-hoc sign in postFixup reusing mbr pattern from `/Users/pwalsh/src/sideprojects/mbr-markdown-browser/main/flake.nix` ~868–1025; `overlays.default`; `darwinModules.default` with `programs.contacts2mdsync.{enable,package}`; `checks` lint). `App/project.yml` with Info.plist `NSContactsUsageDescription`, sandbox + addressbook + user-selected rw + app-scope bookmarks entitlements; Release adds contacts.notes. Package skeleton w/ placeholder test. Hello-world SwiftUI window requesting Contacts access. `justfile` (gen, build, test, lint, fmt). Docs written into `docs/`. Bundle id placeholder `com.zmre.contacts2mdsync` (change if needed).
- **M0 spikes** (`docs/spikes.md`): URL stamp survival through iCloud + Google; Notes entitlement on Developer ID; history-enumerator shim + 603/604; unified-contact write semantics; server normalization catalog; iCloud Drive behavior of `.c2mdsync/` + dataless files; Yams byte-stability. **2026-10-21 run:** S3 and S4 done; S1, S5, S9 and S11 partial; S2 blocked; S6 and S8 todo. Follow-up runs are listed in `docs/spikes.md`; their findings are already folded into architecture §3, §6, §8, §10 and §15.
- **M1** one-way export + CLI (`plan`, `export`, `status`); golden files; round-trip; validate fixtures with real `mbr` (flake check). **Done** — see architecture §6 "What M1 implements" and §15. Pulled forward from M2: re-export idempotency, moved files updated in place, duplicate clusters, a create gate against unlinked/orphaned notes. Still M2: adopting existing notes, markdown-only candidates UI, GRDB state.
- **M2** vault index, idempotent re-export, moves, adoption of existing notes, duplicate clusters, markdown-only candidates. **Done** — see architecture §4 (state schema, decision log), §6 "What M2 implements" and §15 "M2 as implemented": GRDB device state (imports `records.json`), card-id identity with provisional Google ids, relocation, adoption (auto on first import), decisions + `contacts2md review`, incremental scan with dataless handling, image path fix-ups, note backups, minimal onboarding GUI (access → folder bookmark → preview → Run First Export, never stamps), CLI via the app binary with the saved folder (`bin/contacts2md` in the nix package).
- **M3** two-way merge, groups/tags, relationships, notes/body, deletes, breakers, scope; headless `contacts2md sync` with warnings + exit codes; property tests (random edits both sides → fixpoint, no dups).
- **M4** review UI (all screens above).
- **M5** live watch + menu bar; launch/wake catch-up + periodic safety sweep; `launchd` schedule option in nix-darwin module + Settings toggle; history-token acceleration; own-write suppression.
- **M6** multi-device lease, follower mode, NSFileVersion conflicts.
- **M7** iPadOS/iOS target (document picker bookmarks, foreground/BG refresh).

## Verification (M0)
- `nix flake check` passes; `nix develop -c just gen && just test` runs package tests green.
- `nix develop -c just build` builds the app via xcodebuild; launching shows window and Contacts permission prompt.
- `nix build .#default` produces `result/Applications/*.app`; `codesign -d --entitlements - ` shows expected entitlements.
- `darwinModules.default` evaluates (`nix eval .#darwinModules.default` / sample config in README).

## Action items for user
- Submit Contact Note Field Access request (developer.apple.com/contact/request/contact-note-field) — long lead time.
- Confirm bundle id / GitHub org for release URL.

## Naming & review gate
- App/product name: **Contacts2MdSync** (package `Contacts2MdSyncKit`, bundle `com.zmre.contacts2mdsync`, nix `programs.contacts2mdsync`).
- On-disk sync markers (final, decided before release): frontmatter `c2mdsync:`, vault dir `.c2mdsync/`, contact URL label `c2mdsync` with value `x-c2mdsync:<uuid>`. Settled before any release, so no migration exists.
- **Stop after M0**: user reviews `docs/` before any M1 implementation begins.
