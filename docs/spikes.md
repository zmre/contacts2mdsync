# Spikes (run before M1)

Each spike is a throwaway target under `Spikes/` with a written result here. Run them against a **test Apple ID or a few scratch contacts**, not the real address book, until the write paths are proven.

| #  | Question                                                                                  | Why it matters                                     | Pass criteria / decision                                                                 | Status |
|----|-------------------------------------------------------------------------------------------|----------------------------------------------------|------------------------------------------------------------------------------------------|--------|
| S1 | Does a URL with custom label `mdsync` and value `x-mdsync:<uuid>` survive on iCloud and Google cards? Check second Mac, iPhone, contacts.google.com, iCloud.com, and after a web edit. | Identity strategy depends on it.                  | Survives on iCloud → keep plan. If Google strips it: stamp iCloud card only; Google-only contacts rely on cached CN id + strong keys. | todo |
| S2 | Notes entitlement: can `com.apple.developer.contacts.notes` be included in a Developer ID provisioning profile; does the notarized app read/write notes; does an un-entitled build get error 102 rather than crash? | Body ↔ notes mapping.                             | Document the exact behavior both ways; confirm runtime feature-detect works.            | blocked on Apple approval |
| S3 | Change-history shim: enumerate via ObjC, persist token, verify `excludedTransactionAuthors`, force 603/604, measure drop-everything size. | M5 live watch efficiency.                         | Shim compiles (done in M0 skeleton); behavior documented.                                | todo |
| S4 | Unified-contact write semantics: saving to the iCloud card when a linked Google card has a different value — what does the unified view show? Does saving a mutable copy of a unified contact route values predictably? Are `CNLabeledValue.identifier`s stable across saves and iCloud round trips? | Anti ping-pong, write targeting.                  | Rules in architecture §6 confirmed or revised.                                           | todo |
| S5 | Server normalization catalog: how iCloud and Google rewrite phones, addresses, URLs, labels, birthdays without year, images. | Comparison keys + fake-store fixtures.            | Table of before/after values committed as fixtures.                                     | todo |
| S6 | iCloud Drive: does `.mdsync/` sync? How do dataless files appear in enumeration and FSEvents? Do two devices writing identical bytes create conflict copies? Is `NSFileVersion` populated? | Vault state + multi-device.                       | If dot-dirs don't sync, switch to visible `_mdsync/` (mbr would then show it — check mbr ignore config). | todo |
| S7 | Yams emitter byte-stability and round-trip of comments/key order.                         | Minimal diffs, preserving user edits.             | Decide: Yams for parse only + own emitter for managed keys (expected).                   | done (M1): Yams parses only; own emitter + span patching; see markdown-schema §4 |
| S8 | Build/TCC: does ad-hoc signed Nix build re-prompt for Contacts after each rebuild? Does Xcode Debug signed with the team keep the grant? | Dev ergonomics, install path.                      | Expected: ad-hoc re-prompts; use team-signed Debug for daily dev; Developer ID release for nix-darwin. | todo |
| S9 | Is `CNContact.identifier` stable across Contacts.app link/unlink and across iCloud sign-out/in on this Mac? | Validates cascade step 2 confidence.              | Record observed behavior.                                                                | todo |
| S10| Does the real `mbr` render our fixture files with zero contact problems (incl. `[[Title]]` relationships after moving files into subfolders)? | Format contract.                                   | Add mbr as flake input + check derivation in M1.                                         | done (M1): `checks.mbr` / `just mbr-check` — 59 fixture notes, 0 problems with mbr 0.7.0 |
| S11| Headless TCC + sandbox: does the app binary run with a `sync` argument from Terminal, cron and a launchd user agent keep the app's Contacts grant and read its security-scoped bookmark? | Headless CLI (architecture §15).             | Works from launchd at minimum. Otherwise fall back to `open -g -a … --args sync`. | todo |

## Results
### Baseline context
c2m-spike inventory  2026-10-21T02:50:04Z
authorization: notDetermined
Contacts access not determined; requesting (a TCC prompt should appear)...

#### Containers (2)
  resolved 500/2428 cards...
  resolved 1000/2428 cards...
  resolved 1500/2428 cards...
  resolved 2000/2428 cards...
| # | type | name | guessed kind | default | cards | groups | identifier |
|---|---|---|---|---|---|---|---|
| 0 | cardDAV | iCloud | icloud | yes | 2427 | 32 | D72A148B-2A8F-4494-A9A1-D7AD30890905:ABAccount |
| 1 | local | On My Mac | - |  | 1 | 0 | _local:ABAccount |
containers by type: cardDAV=1 local=1

#### Contacts
underlying cards:                2428
unified (fetch, unify=on):       2428
unified (distinct via mapping):  2428
cards per unified contact: 1:2428
linked unified contacts spanning >1 container: 0
linked unified contacts spanning iCloud+Google: 0
linked unified contacts within one container:  0

#### Notes key probe (CNContactNoteKey on one card)
notes readable: no (key unavailable) (content not printed)

#### Change history
currentHistoryToken: present (579 bytes)

#### Harness scratch cards
harness cards: 0  name-only (marker lost): 0  marker-only: 0

## S1
PLAN: s1-stamp create
  - create "ZZ Spike S1 icloud A994" in container D72A148B-2A8F-4494-A9A1-D7AD30890905:ABAccount (icloud, name iCloud)
  - URL mdsync-spike = x-mdsync-spike:s1:icloud:59303270-1409-4da7-a675-5c3380c68023
  - URL mdsync = x-mdsync:a816257d-eedb-48cb-8793-ec84f5d9833b
  (only cards named "ZZ Spike …" carrying a x-mdsync-spike: URL are ever modified)
DRY RUN: nothing written. Re-run with --yes to perform the steps above.

PLAN: s1-stamp create
  - create "ZZ Spike S1 icloud 51D0" in container D72A148B-2A8F-4494-A9A1-D7AD30890905:ABAccount (icloud, name iCloud)
  - URL mdsync-spike = x-mdsync-spike:s1:icloud:89d31cab-1f12-41e3-ab23-4945b15812f2
  - URL mdsync = x-mdsync:8d10b13e-696a-4dc8-982e-a7214b43a1a0
  (only cards named "ZZ Spike …" carrying a x-mdsync-spike: URL are ever modified)
created identifier=44EDB810-FC46-4AB6-8F1D-731343C85A9A:ABPerson (pre-save mutable id: 44EDB810-FC46-4AB6-8F1D-731343C85A9A:ABPerson)
Next: wait for sync, then run `c2m-spike s1-stamp check` here and on other devices;
also inspect the card on iPhone, iCloud.com and contacts.google.com, edit it on the web, re-check.

error: Could not pick a unique google container by name (0 candidates).
Pass --google-container <identifier>. Containers:
  D72A148B-2A8F-4494-A9A1-D7AD30890905:ABAccount  type=cardDAV  name=iCloud
  _local:ABAccount  type=local  name=On My Mac

s1-stamp check  2026-10-21T03:20:06Z  cards found: 1  ledger entries (this Mac): 1
| card | container | identifier | in ledger | marker | stamp label | stamp value | all URLs |
|---|---|---|---|---|---|---|---|
| ZZ Spike S1 icloud 51D0 | icloud | 44EDB810-FC46-4AB6-8F1D-731343C85A9A:ABPerson | yes (same id) | intact | intact | x-mdsync:8d10b13e-696a-4dc8-982e-a7214b43a1a0 | mdsync-spike=x-mdsync-spike:s1:icloud:89d31cab-1f12-41e3-ab23-4945b15812f2; mdsync=x-mdsync:8d10b13e-696a-4dc8-982e-a7214b43a1a0 |


