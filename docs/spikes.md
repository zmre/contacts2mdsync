# Spikes (run before M1)

Each spike is a throwaway target under `Spikes/` with a written result here. Run them against a **test Apple ID or a few scratch contacts**, not the real address book, until the write paths are proven.

| #  | Question                                                                                  | Why it matters                                     | Pass criteria / decision                                                                 | Status |
|----|-------------------------------------------------------------------------------------------|----------------------------------------------------|------------------------------------------------------------------------------------------|--------|
| S1 | Does a URL with custom label `c2mdsync` and value `x-c2mdsync:<uuid>` survive on iCloud and Google cards? Check second Mac, iPhone, contacts.google.com, iCloud.com, and after a web edit. | Identity strategy depends on it.                  | Survives on iCloud → keep plan. If Google strips it: stamp iCloud card only; Google-only contacts rely on cached CN id + strong keys. | **partial**: iCloud passes. Google stamp not tested (no Google container at the time); indirect evidence that custom-label URLs survive on Google |
| S2 | Notes entitlement: can `com.apple.developer.contacts.notes` be included in a Developer ID provisioning profile; does the notarized app read/write notes; does an un-entitled build get error 102 rather than crash? | Body ↔ notes mapping.                             | Document the exact behavior both ways; confirm runtime feature-detect works.            | **blocked** on Apple approval. Un-entitled CLI: no error 102; the key is silently unavailable |
| S3 | Change-history shim: enumerate via ObjC, persist token, verify `excludedTransactionAuthors`, force 603/604, measure drop-everything size. | M5 live watch efficiency.                         | Shim compiles (done in M0 skeleton); behavior documented.                                | **done** (iCloud only, before Google was enabled). 603 not provoked; a bogus token gives no 604 |
| S4 | Unified-contact write semantics: saving to the iCloud card when a linked Google card has a different value — what does the unified view show? Does saving a mutable copy of a unified contact route values predictably? Are `CNLabeledValue.identifier`s stable across saves and iCloud round trips? | Anti ping-pong, write targeting.                  | Rules in architecture §6 confirmed or revised.                                           | **done** for local save semantics. **Partial** on round-trip id stability (longest gap was about 4 min) |
| S5 | Server normalization catalog: how iCloud and Google rewrite phones, addresses, URLs, labels, birthdays without year, images. | Comparison keys + fake-store fixtures.            | Table of before/after values committed as fixtures.                                     | **partial**: iCloud checked about 70 s after create. Google not captured (card id changed; the check looked up by id, now fixed) |
| S6 | iCloud Drive: does `.c2mdsync/` sync? How do dataless files appear in enumeration and FSEvents? Do two devices writing identical bytes create conflict copies? Is `NSFileVersion` populated? | Vault state + multi-device.                       | If dot-dirs don't sync, switch to visible `_c2mdsync/` (mbr would then show it — check mbr ignore config). | todo |
| S7 | Yams emitter byte-stability and round-trip of comments/key order.                         | Minimal diffs, preserving user edits.             | Decide: Yams for parse only + own emitter for managed keys (expected).                   | done (M1): Yams parses only; own emitter + span patching; see markdown-schema §4 |
| S8 | Build/TCC: does ad-hoc signed Nix build re-prompt for Contacts after each rebuild? Does Xcode Debug signed with the team keep the grant? | Dev ergonomics, install path.                      | Expected: ad-hoc re-prompts; use team-signed Debug for daily dev; Developer ID release for nix-darwin. | todo (no evidence yet; S11 never granted the binary itself) |
| S9 | Is `CNContact.identifier` stable across Contacts.app link/unlink and across iCloud sign-out/in on this Mac? | Validates cascade step 2 confidence.              | Record observed behavior.                                                                | **partial**: only a 30 s compare with no experiment in between. Side evidence: Google card ids change once after create; iCloud ids stayed stable through the Google enable |
| S10| Does the real `mbr` render our fixture files with zero contact problems (incl. `[[Title]]` relationships after moving files into subfolders)? | Format contract.                                   | Add mbr as flake input + check derivation in M1.                                         | done (M1): `checks.mbr` / `just mbr-check` — 59 fixture notes, 0 problems with mbr 0.7.0 |
| S11| Headless TCC + sandbox: does the app binary run with a `sync` argument from Terminal, cron and a launchd user agent keep the app's Contacts grant and read its security-scoped bookmark? | Headless CLI (architecture §15).             | Works from launchd at minimum. Otherwise fall back to `open -g -a … --args sync`. | **partial**: Terminal is authorized. launchd and cron report `notDetermined`; `--request` was never tried, so prompting and granting are untested. Bookmark not tested |
| S12| Notes without the entitlement: can we read and write the Notes field by scripting Contacts.app with Apple Events (`note` and `id` of `person`)? How long do a bulk read and a per-person read take for about 2,500 contacts? Do AppleScript ids match CNContact card ids or unified ids? Which card of a linked pair gets the write? | Body ↔ notes mapping while S2 is blocked on Apple. | Bulk read of all notes takes a few seconds or less, writes keep the text exactly, no other fields or ids change, the linked-pair write target is predictable, and the Automation prompt is acceptable. Then Apple Events become the fallback notes path in architecture §8. | **pass** (2026-10-22) |
| S13| Real M3 write path on scratch cards: does `CNContactStoreAdapter.apply` → `CardWriter` (behind a harness-only guard) add, edit and delete list values, write single-valued fields through to linked cards, stamp, manage group membership and edit relations correctly on real iCloud and Google cards? Labeled-value ids kept, no unified save, `transactionAuthor` excluded from history, values intact after a server round trip? | Go/no-go for `apple_writes: enabled` on the real address book. | `run`: every row PASS (WARN in steps 8–9 only if explained by a concurrent Google re-save). `check` after 15–30 min: values, stamps and ids survive, or each server rewrite is understood and covered by comparison keys. | todo |
| S14| Production notes provider on the real Contacts.app: does `ScriptingNotesProvider` (raw Apple Events, `LiveContactsApp`) read every card's note identically to the S12 `NSAppleScript` reader (bulk and per-card paths, ids = CN card ids), write notes exactly (CRLF/Unicode/quotes/backslashes/emoji, ~49k chars, clear, both cards of a linked pair in one call), fail per card on an id that does not exist, and launch Contacts.app hidden and quit it after? | Go/no-go for notes scripting in the app (architecture §8 "As implemented (notes scripting)"). | `check`: every row PASS (parity by per-card SHA-256, no note text printed). `write`: every row PASS; WARN in case 1 only if Contacts rewrites line endings (then the body normalization covers it); CN identifiers and other fields unchanged, history only on target cards. | **pass** (2026-10-22; launch-hidden cosmetic fail) |
| S15| CNSaveRequest on cards that HAVE a note, without the notes entitlement: reports (forums 723695, FB23452026, mattt/iMCP#148) say updates fail with `NSCocoaErrorDomain 134092` "Unhandled error … occurred during faulting". S13 passed only because its scratch cards had no notes; ~1,572 of 3,781 real cards have one. Exactly which operations fail (names/job title, add email, in-place phone edit, group add/remove, URLs + stamp, delete), does a failed save leave partial changes, do cheap variations (minimal keys, `shouldRefetchContacts = false`, fresh store, `CNContactNoteKey`) avoid it, does the kit adapter fail, and can Contacts.app scripting do each failing operation instead (ids kept, history only on the target, scripting labeled-value ids = `CNLabeledValue.identifier`?) | Go/no-go for `apple_writes` on a real address book without the entitlement; which writes must go through Contacts.app scripting (architecture §6/§8). | `run`: a matrix of card × operation × path. Decision: for every operation that fails with 134092 on noted cards, either a scripting path that verifies (fields, labeled-value ids, card id, history only on target, note intact) or the planner refuses that write for noted cards. No `PARTIAL` after a failed save. | **done** (2026-10-24) |
| S16| Production write routing on scratch cards: does `CardWriteRouter` (real `CNContactStoreAdapter` + real `ScriptingCardWriter`, one `ContactsAppSession` shared with the notes provider, `cardNotes` from the provider) route and write correctly against the real Contacts.app? Noted card: names/job title, in-place phone edit, new email, URL delete + stamp, group add/remove, in-place address / related name / social profile / IM edits, clearing a field, an unlabeled value; what raw `_$!<Work>!$_` / `_$!<Mobile>!$_` / custom labels are stored as; element ids kept; image and birthday skipped; un-noted card via the framework (removeMember via scripting); one history event per card per batch | Go/no-go for the write routing in architecture §6 on a real address book without the notes entitlement; closes the S15 open items. | `run`: every row PASS (WARN in step 8 only if explained by concurrent sync); the label and element-id answers recorded; B's note byte-exact at the end; Contacts.app left as found. | **pass, 1 gap** (2026-10-24) |

## Results (2026-10-21 UTC run)

The raw terminal output has moved, verbatim, to [`Spikes/results/raw-2026-10-21.md`](../Spikes/results/raw-2026-10-21.md). It contains no real PII; nothing was redacted. Supporting files are in `Spikes/results/`: `ids-2026-10-20T2231.json` (S9, hashed), `s4-state.json`, `s5-before.json`, `s5-2026-10-20T2230.md` and `token.bin` (the S3 token saved at 04:03Z, **before Google was enabled**).

Environment: macOS 27.0.1 (26A434). Harness: ad-hoc signed debug build of `c2m-spike`, run from WezTerm. These runs used the pre-rename marker spelling: stamp label `mdsync`, value `x-mdsync:<uuid>`, marker `x-mdsync-spike:`. The shape is the same as the final `c2mdsync` / `x-c2mdsync:` markers.

### Account timeline (matters for every result)

| Time (UTC)       | Containers present                        | What ran                                                    |
|------------------|-------------------------------------------|-------------------------------------------------------------|
| 02:50            | iCloud (2427 cards, 32 groups), On My Mac (1) | `inventory` baseline: 2428 cards, 2428 unified, **0 links**  |
| 03:1x–03:40      | same                                      | S1 iCloud create + 2 checks; `s1-stamp create --container google` failed with "0 candidates" |
| 04:01–04:03      | same (2429 cards in the history snapshot) | S3 nil / `--since` / bogus token                            |
| ? (not timestamped) | probably the same                      | S3 `--author` (iCloud-only test)                            |
| 04:03–04:17      | **Google ("Gmail") contacts enabled**     | nothing logged                                               |
| 04:17–04:26      | iCloud, Gmail, On My Mac                   | S4 create, link, 4 write runs                               |
| 04:29–04:30      | same                                      | S5 create, check ~70 s later                                |
| 04:31–04:32      | same (3787 cards, 2531 unified)           | S9 record + compare                                         |
| 04:33–04:36      | same                                      | S11 Terminal, launchd, cron                                 |
| after 04:36      | same                                      | `cleanup` (not in the log)                                   |
| 04:48            | Gmail 1353 / iCloud 2427 / local 1        | read-only `inventory` run while writing this up: 3781 cards, 2526 unified, 1255 linked pairs, **0 harness cards** |

So inventory, S1 and S3 ran **before** Google was enabled. S4, S5, S9 and S11 ran **after**.

### Cross-cutting finding: iCloud and Google cards were linked automatically

- Before Google was enabled: `cards per unified contact: 1:2428`, 0 linked.
- About 15–30 min after enabling it: 3787 cards → 2531 unified. Of the unified contacts, **1256 are 2-card iCloud+Google pairs** (1255 real, plus the S4 pair) and 1275 are single cards. No cluster has more than 2 cards, and nothing is linked within one container. Inventory at 04:48 after cleanup: `1:1271 2:1255`, all 1255 spanning iCloud+Google.
- Single cards: 1172 iCloud-only, 98 Google-only, 1 On My Mac.
- No one links 1255 pairs by hand, so the linking was automatic. For the S4 pair alone, the log can't tell whether the user also linked it by hand: it showed `linked: YES` at 04:21, 3.7 min after creation.
- The two S5 cards were **not** linked. They shared both emails but had different family names (`S5 google C6FD` and `S5 icloud C6FD`). So the automatic linking needs at least a matching name. Whether a matching name alone is enough was not tested.
- A linked contact's unified id is **neither card's id**, and has a different format: `B190DC45-…` with no `:ABPerson` suffix. For single cards, unified id = card id in all 1275 cases. This contradicts the research note "unified contact id is one of its linked card ids".

### Cross-cutting finding: a Google card's identifier changes once after it's created

- S4: the Google card was `D19D22FA-…:ABPerson` right after save (ledger.json). By 04:21 it was `6B8DDB86-…:ABPerson`, found by its marker. iCloud card `8EF25D5A-…` never changed.
- S5: the Google card `74EF41DD-…` was `NOT FOUND (deleted or identifier changed)` 70 s after creation. S9 at 04:31 found the card by marker under a different id: sha256 `dd0b0449…` ≠ sha256(`74EF41DD…`) = `0787bd55…`.
- The existing S4 Google card was updated afterwards (Write B, a job title and an email). Its id stayed `6B8DDB86` through 04:31. So far the churn shows up **only after create**. That fits the Google CardDAV sync replacing the locally created record with the server's copy.
- No iCloud card id changed in any run: S1, S3, S4 and S5 all matched by hash at 04:31. That includes the S1 and S3 cards, which existed before Google was enabled.

### S1: stamp survival

- **iCloud: passes.** `ZZ Spike S1 icloud 51D0` was checked at 03:20 and 03:40: `marker intact | stamp label intact | x-mdsync:8d10b13e-…`, with the same identifier as the ledger. According to the user, the card was also edited on iCloud.com and on the iPhone, and both the stamp and the marker survived. The second-Mac check was not done.
- **Google: not tested directly.** `s1-stamp create --container google` failed because no Google container existed yet. Indirect evidence after Google was enabled: the S4 Google card kept its custom-label URL (`url | mdsync-spike | x-mdsync-spike:s4:google:… | Google`) after its identifier changed, which suggests the server round trip happened. The S5 Google card was still found by its `x-mdsync-spike:` marker URL 2 min after creation. The S5 Google card also carried a `mdsync` stamp URL, but nothing recorded whether that URL survived. Nobody checked contacts.google.com.
- Confidence: high for iCloud. Low to medium for Google: there's evidence that a custom-label URL survives, but the stamp itself wasn't observed and no web edit was made.

### S2: notes (un-entitled CLI)

- Fetching `CNContactNoteKey` on one card **did not fail with error 102 and did not crash**. The fetch succeeded, and `isKeyAvailable(CNContactNoteKey)` returned false: `notes readable: no (key unavailable)`. The result was the same before and after Google was enabled.
- Implication: detect the feature with `isKeyAvailable`, not by catching error 102. Reading `.note` without that check would raise `CNContactPropertyNotFetchedException`. The entitled behavior is still blocked on Apple approval.

### S3: change history (iCloud only, before Google)

| Run                 | Events                                              | Time   | Notes                                    |
|---------------------|-----------------------------------------------------|--------|------------------------------------------|
| nil token           | 2462 = 2429 AddContact + 32 AddGroup + 1 DropEverything | 0.12 s | `includeGroups=false`, but group adds still came through |
| `--since` (saved)   | 1 UpdateContact                                     | 0.11 s | returned only the one edit               |
| `--bogus-token`     | 2462, identical to nil                              | 0.12 s | **no NSError, no exception**: treated as a reset |
| `--author …spike`   | authored edit: unfiltered 1, excluding the author 0; unauthored control edit: still visible (1) | – | `RESULT: … hides authored edit: YES` / `control edit still visible: YES` |

- The token was 579 bytes and changed after every fetch. At 04:48, with 3 containers, it was 636 bytes.
- Author exclusion works. One caveat: the control fetch also starts from the pre-edit token. If the two edits had coalesced, `ours 1` would still be printed, so the clean evidence is the authored-only step (1 → 0).
- Not observed: error 603 (needs a token several days old), error 604, the history produced by **enabling an account**, and the drop-everything size at 3787 cards. `Spikes/results/token.bin` still holds the token from before Google was enabled, so the account-enable history can still be measured (see the follow-ups).

### S4: unified write semantics (linked pair, after Google)

Setup: iCloud card with `S4 baseline icloud`, phone …0141. Google card with `S4 baseline google`, phone …0142. Both cards had the same email.

- **Single-valued fields: the most recently saved card seems to win the display.** Before any write, the unified jobTitle was the **Google** value (`S4 baseline google`), even though iCloud is the default container. The Google card had just been re-saved by Google sync (the id change). After every save to the iCloud card, the unified view showed the iCloud value (`-> shows iCloud card value`, 4 of 4 runs). Every observation fits "last saved card wins", but nothing proves it. Not observed: a later Google sync re-saving the Google card and flipping the display back.
- **Multi-valued fields are a union, with exact duplicates across cards collapsed.** Both phones showed (…0141 iCloud, …0142 Google). The shared email showed **once**: first with the Google card's lv id `904DE76C`, and after the iCloud write with the iCloud card's lv id `07513904`. So which card supplies a collapsed value, and its id, can change. A second email only appeared after Write B added one. Duplicates within one card are not collapsed: the harness added the same `s4-added` …0149 phone on every `--yes` run, and all 4 copies are visible. That's a harness quirk, not a Contacts finding.
- **Saving a mutable copy of the unified contact writes to every linked card.** `new email landed on: iCloud=true Google=true`, with the same lv id `5CD600EC` on both cards, and jobTitle was set on both. This overwrote the Google card's own value, so never use it as a targeted write.
- **Labeled-value ids:** an in-place edit kept its id (`edited-in-place id stable: true`, 5/5). A new value's id in the saved object equals its id after refetch (`added value id kept after refetch: true`). Across runs 30 s to 2 min apart, all ids were kept: `unified lv ids kept 9/9`, Google `4/4`. **Not measured:** stability over a real round trip (the longest gap was about 4 min), after web or phone edits, or across the Google create churn (the first check already came after it).
- The unified id `B190DC45` stayed the same through all writes.

### S5: normalization catalog

- **iCloud** (checked 71 s after create, which may be too early for a full server round trip): 34 of 42 values were unchanged. These include all 11 phone formats, the labels (including custom and nil labels), email case, URLs without a scheme or in uppercase, the stamp URL, all 4 addresses (lowercase `state=ca`, `iso=us`, `sw1a 2aa`), names, `&` and `/` in org and department, IM and relations. The 8 changed values:
  - dates and birthdays: `-----02-29` → `-----02-29 cal=gregorian`, and the same for the anniversary and the yearless date. The **local refetch** shows this too, so the framework adds the calendar at save time; the server doesn't.
  - social profiles: Twitter `url=` → `url=http://twitter.com/zzspike`, also in the local refetch. Both social profiles' **lv ids changed** after the save; their values didn't.
  - image: `imageDataAvailable yes → no` and `image png 256x256 6013B → ∅`, with a new `thumbnail png 256x256 6025B sha=2000e26e…`. The full-size image disappeared, at least for now. A thumbnail re-encoded from it is all that's left.
- **Google: no data.** The check looked the card up by its creation-time id, which had changed, so all 42 rows read `∅`. That's a harness limitation, not something Google did. The check now falls back to the marker (see Follow-up runs).
- Confidence: medium for "iCloud keeps text values verbatim", given the short wait. Low for the image behavior.

### S9: identifier stability

- `record` at 04:31:50, then `compare` at 04:32:20 with **no experiment in between**: 3787/3787 card ids, 2531/2531 unified ids and 3/3 containers kept, and all 6 harness cards matched. This is a null result.
- Side evidence from the other runs: iCloud card ids didn't change when Google was enabled. The iCloud card of the S4 pair kept its id through being linked. Google card ids change once after a local create. A linked contact's unified id is a synthesized id distinct from both card ids.
- **Not run:** unlink and relink, iCloud sign-out and sign-in, and turning the Google account off and on.

### S11: headless TCC

| Context              | Parent           | Env markers                                  | Status (before)   | Count       | Prompt?                      |
|----------------------|------------------|----------------------------------------------|-------------------|-------------|------------------------------|
| Terminal (WezTerm)   | `/bin/zsh`       | `__CFBundleIdentifier=com.github.wez.wezterm` | `authorized`      | 2531        | n/a                          |
| launchd user agent   | `/sbin/launchd`  | `XPC_SERVICE_NAME=com.zmre.c2m-spike.s11`    | `notDetermined`   | skipped (exit 3) | none; `--request` not passed |
| cron                 | `/bin/bash` (cron `sh`) | `SHELL=/bin/sh`, no XPC/TTY           | `notDetermined`   | skipped     | none; `--request` not passed |

- The launchd result comes from `/tmp/c2m-spike-s11-launchd.log`; it's in the appendix of the raw file. SSH was not tried.
- A grant held by the terminal doesn't carry over to launchd or cron. In those contexts the binary is its own responsible process, and it has no TCC record yet. That's why nothing appears under System Settings ▸ Privacy & Security ▸ Contacts: a TCC entry only appears after something calls `requestAccess`, and the harness only does that with `--request`.
- Still open: does `--request` under launchd show a prompt, and does a grant to the bare binary persist? An ad-hoc rebuild would invalidate it (S8). Does the real app bundle's grant apply when its executable is exec'd directly by launchd? The security-scoped bookmark was not tested (the harness has none).

### Design changes applied

These findings are now folded into the design docs:

- [architecture §3](architecture.md#3-canonical-model): comparison keys for dates (calendar ignored), social profiles and IM (service + username; synthesized `urlString` ignored), and images (unavailable data with a thumbnail counts as unknown, never as removed).
- [architecture §6](architecture.md#6-identity-and-duplicate-prevention):
  - automatic linking, the synthesized unified id, and the blended unified view;
  - cached-id rules for Google cards;
  - field values computed from the underlying cards with a fixed precedence;
  - edits and deletes go to every card holding the value; single-valued fields are written to all linked cards that have them;
  - never save a unified mutable copy;
  - two stamps on one unified contact is a common path.
- [architecture §5 / §9](architecture.md#9-safety-rails): re-fetch new Google cards by stamp; a vanished id whose stamp reappears on another card is churn, not a delete.
- [architecture §8](architecture.md#8-relationships-groups-notes): notes detection via `isKeyAvailable`.
- [architecture §10](architecture.md#10-change-detection-and-echo-suppression): `DropEverything` is the reset signal; group events are filtered by type.
- [architecture §15](architecture.md#15-headless-cli-cron--launchd): the S11 partial result.
- [markdown-schema §2–§3](markdown-schema.md), [plan.md](plan.md) and [research.md](research.md): updated to match.

### Cleanup status

- `inventory` at 04:48Z reports `harness cards: 0  name-only (marker lost): 0  marker-only: 0`. The unified count dropped by exactly 5 (2531 → 2526), which matches removing the S1, S3, S5-iCloud and S5-Google cards and the S4 pair. All scratch cards are gone from this Mac. Nobody has checked iCloud.com or contacts.google.com for leftovers.
- The LaunchAgent is no longer loaded (`launchctl print` can't find it), but `~/Library/LaunchAgents/com.zmre.c2m-spike.s11.plist` still exists. No cron line remains. The logs `/tmp/c2m-spike-s11-{launchd,cron}.log` are still there.

## Follow-up runs

The harness now uses the final marker names: scratch-card marker `c2mdsync-spike` / `x-c2mdsync-spike:…` and stamp `c2mdsync` / `x-c2mdsync:<uuid>`. It still recognizes the legacy `x-mdsync-spike:` and `mdsync` spellings on old cards. `s5-normalize check` now falls back to finding the card by marker when its recorded id is gone, and prints `card identifier CHANGED: <old> -> <new> (found by marker)`.

Run the steps in this order. Steps 2–7 touch the real address book, but only scratch cards are written.

1. **Rebuild.** The `.build` binary predates the rename. A rebuild also changes the ad-hoc signing identity. That doesn't matter for terminal runs (the grant belongs to the terminal), but it does for S11.

   ```sh
   cd /Users/pwalsh/src/sideprojects/mbr-apple-contact-sync
   nix develop path:$PWD -c swift build --package-path Spikes
   alias c2m-spike=$PWD/Spikes/.build/debug/c2m-spike
   ```

2. **S3: history across the Google enable.** Do this first. `Spikes/results/token.bin` is still the 04:03Z token from before Google was enabled, and both commands below overwrite it.

   ```sh
   cp Spikes/results/token.bin Spikes/results/token-pre-google-0403Z.bin
   c2m-spike s3-history --since    # account enable + all spike churn + cleanup: AddContact x1353? DropEverything?
   c2m-spike s3-history            # nil token: drop-everything size at ~3781 cards
   ```

3. **Create the scratch cards.** Move the old state files aside first; the new runs overwrite them.

   ```sh
   mv Spikes/results/s4-state.json  Spikes/results/s4-state-2026-10-21T0426.json
   mv Spikes/results/s5-before.json Spikes/results/s5-before-2026-10-21T0429.json
   c2m-spike s1-stamp create --container google --yes && c2m-spike s1-stamp check
   c2m-spike s4-unified create --yes          # do NOT link the pair by hand
   c2m-spike s5-normalize create --yes
   ```

4. **After at least 15 minutes,** with both cards opened once on contacts.google.com and iCloud.com:

   ```sh
   c2m-spike s1-stamp check            # Google: c2mdsync label + x-c2mdsync: value intact? id changed vs ledger?
   c2m-spike s4-unified check          # "linked: YES" with no manual link = automatic linking confirmed
   c2m-spike s4-unified check --yes    # one iCloud-card write; saves s4-state.json
   c2m-spike s5-normalize check --all  # Google catalog (via marker fallback) + iCloud after a real wait
   ```

   Then, on contacts.google.com: confirm the S1 card shows the `x-c2mdsync:` URL and note the label it shows. Edit that card's job title, wait for the sync, and run `c2m-spike s1-stamp check` again. Optionally, look at the card on the iPhone.

5. **After at least 30 more minutes:** run `c2m-spike s4-unified check` (no `--yes`). It answers two questions: are the labeled-value ids kept after a real round trip, and did the unified job title flip back to the Google value? Optional: edit the S4 contact's job title in the Contacts.app UI, then run `check` again to see which card or cards the UI wrote to.

6. **S9: one experiment per record/compare pair.**

   ```sh
   c2m-spike s9-ids record
   #   Contacts.app: select "ZZ Spike S4 Linked …" → unlink the cards
   c2m-spike s9-ids compare            # also: did Contacts re-link them by itself?
   c2m-spike s9-ids record
   #   select both cards → Card ▸ Link Selected Cards
   c2m-spike s9-ids compare
   c2m-spike s9-ids record
   #   System Settings ▸ Internet Accounts ▸ Google: Contacts off, wait for the count to drop, on, wait 15–30 min
   c2m-spike s9-ids compare            # Google card id churn; do pairs re-form with new unified ids?
   ```

   iCloud sign-out and sign-in is optional; it's the riskiest of these experiments.

7. **S11 with a prompt, and S8 evidence.**

   ```sh
   rm -f /tmp/c2m-spike-s11-launchd.log
   /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --request" ~/Library/LaunchAgents/com.zmre.c2m-spike.s11.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.zmre.c2m-spike.s11.plist
   launchctl kickstart -k gui/$(id -u)/com.zmre.c2m-spike.s11
   #   prompt? whose name does it show? approve it, then:
   launchctl kickstart -k gui/$(id -u)/com.zmre.c2m-spike.s11 && cat /tmp/c2m-spike-s11-launchd.log
   #   S8: touch a Spikes source file, rebuild (step 1), kickstart again: is the grant gone?
   launchctl bootout gui/$(id -u)/com.zmre.c2m-spike.s11 && rm ~/Library/LaunchAgents/com.zmre.c2m-spike.s11.plist
   ```

8. **Clean up.** Afterwards, check contacts.google.com and iCloud.com for leftover "ZZ Spike" cards.

   ```sh
   c2m-spike cleanup          # dry run
   c2m-spike cleanup --yes
   ```

### S12 run steps

`c2m-spike s12-notes` sends Apple Events to Contacts.app. The first command that does so triggers the macOS prompt "<terminal> wants to control Contacts". Allow it. If it's refused, the command prints error -1743 and the steps to fix it. Rebuild first (step 1); the new `Info.plist` key is `NSAppleEventsUsageDescription`. For what each command prints and what to look for, see [`Spikes/README.md`](../Spikes/README.md#s12-notes-through-contactsapp-apple-events).

1. **Probe (read-only).** It prints counts and timings only, never note text or names.

   ```sh
   c2m-spike s12-notes probe --quit-if-launched
   ```

2. **Single scratch card.** The first `--yes` creates `ZZ Spike S12 Notes <id>` in iCloud. The second `--yes` sets its note via AppleScript.

   ```sh
   c2m-spike s12-notes write --yes     # creates the card
   c2m-spike s12-notes write           # dry run: AppleScript resolution + plan
   c2m-spike s12-notes write --yes     # set note + save; re-read; CN diff; change history
   ```

   Within about 5 minutes, check the note on iCloud.com and on the iPhone.

3. **Linked pair.** This step creates an iCloud + Google pair with the same name and waits for automatic linking. If an S4 pair from step 3 above is still linked, the command uses that instead.

   ```sh
   c2m-spike s12-notes write --linked --yes    # creates the pair if no linked harness pair exists
   #   wait about 15 min (or link by hand), then:
   c2m-spike s12-notes write --linked          # dry run: are they linked? which AppleScript id?
   c2m-spike s12-notes write --linked --yes
   ```

   Record which card the change history names, and where the note shows up: on iCloud.com, on contacts.google.com, or on both.

4. **Clean up:** `c2m-spike cleanup --spike s12 --yes`.

### S13 run steps

`c2m-spike s13-writes` runs the app's real write path, `CNContactStoreAdapter.apply` → `CardWriter`, against the real Contacts store. Every batch first goes through the harness guard, which fetches each target card again (unified results off) and refuses the whole batch unless every card is an S13 scratch card. Run S13 before you set `apple_writes: enabled` on your real address book. For what each step checks, see [`Spikes/README.md`](../Spikes/README.md#s13-the-real-write-path-m3-contactstoreapply-on-scratch-cards).

1. **Rebuild** (step 1 above). The harness now links `ContactModel` and `ContactsAdapter` from `Packages/Contacts2MdSyncKit`, so it builds whatever kit is in the working tree.

2. **Setup.** This creates a linked iCloud + Google pair, an iCloud-only card and a Google-only card.

   ```sh
   c2m-spike s13-writes setup          # dry run
   c2m-spike s13-writes setup --yes
   ```

3. **Wait about 15 minutes** for automatic linking and the Google id change. Then:

   ```sh
   c2m-spike s13-writes run            # dry run: "linked pair: YES"?
   c2m-spike s13-writes run --yes      # PASS/FAIL table → Spikes/results/s13-<date>.md
   ```

   If the pair never links, link it by hand in Contacts.app, or pass `--allow-unlinked`.

4. **After 15–30 minutes,** with the S13 cards opened once on iCloud.com and contacts.google.com:

   ```sh
   c2m-spike s13-writes check          # read-only → Spikes/results/s13-check-<date>.md
   ```

   Look for these:

   - the Google-only card's `x-c2mdsync:` stamp (this is the S1 Google answer);
   - labeled-value ids after the round trip;
   - which card's job title the unified view shows.

   You can also look at the cards on the iPhone.

5. **Clean up:** `c2m-spike cleanup --spike s13 --yes`. This deletes the cards and `ZZ Spike S13 Group`. Then check iCloud.com and contacts.google.com for leftover "ZZ Spike S13" cards.


### S14 run steps

`c2m-spike s14-notes` runs the app's real notes provider, `ScriptingNotesProvider`, against the real Contacts.app. Writes go only to harness scratch cards: before every `provider.write`, the harness fetches each target card again (unified results off) and asks Contacts.app for the same person; both must show the `ZZ Spike ` prefix and the card's marker with spike tag `s14` (or `s13` for the reused S13 linked pair). For what each row checks, see [`Spikes/README.md`](../Spikes/README.md#s14-the-production-notes-provider-scriptingnotesprovider-on-scratch-cards).

1. **Rebuild** (step 1 above). The harness builds whatever kit is in the working tree.

2. **Check (read-only).** Prints counts, timings, opaque ids and hash comparisons only. If Contacts.app is not running, the provider launches it hidden and `finishSession()` quits it.

   ```sh
   c2m-spike s14-notes check          # → Spikes/results/s14-check-<date>.md
   ```

   If it reports `scripting(not-determined)`, run `c2m-spike s14-notes check --request-permission` once and allow the prompt.

3. **Write.** If the S13 linked pair still exists, case 4 uses it and puts its notes back afterwards. Otherwise the first `--yes` creates an S14 pair and skips case 4.

   ```sh
   c2m-spike s14-notes write          # dry run: plan only, no Apple Events
   c2m-spike s14-notes write --yes    # → Spikes/results/s14-write-<date>.md
   #   only if it created an S14 pair: wait ~15 min for automatic linking, then
   c2m-spike s14-notes write --yes
   ```

   Within about 5 minutes, check the S14 solo card's note (emoji, quotes, line breaks) on iCloud.com and on the iPhone.

4. **Clean up:** `c2m-spike cleanup --spike s14 --yes`. Then check iCloud.com and contacts.google.com for leftover "ZZ Spike S14" cards.

### S15 run steps

`c2m-spike s15-noted-writes` checks which CNSaveRequest writes fail on cards that have a note (error 134092 without the notes entitlement) and whether Contacts.app scripting can do them instead. Writes go only to `ZZ Spike S15 …` scratch cards and `ZZ Spike S15 Group`: every CNSaveRequest fetches its target again (unified results off) and needs the S15 marker; every scripting write first checks the card in CNContactStore and in Contacts.app (the S14 guard). For what each row checks, see [`Spikes/README.md`](../Spikes/README.md#s15-cnsaverequest-on-cards-that-have-a-note-error-134092).

1. **Rebuild** (step 1 above).

2. **Setup.** Creates A (no note), B (note), an iCloud + Google pair C (note on the iCloud card), D (note) and E (no note) for the delete test, and the scratch group. The notes are written by the production `ScriptingNotesProvider` (Contacts.app is launched hidden and quit afterwards).

   ```sh
   c2m-spike s15-noted-writes setup          # dry run
   c2m-spike s15-noted-writes setup --yes    # → Spikes/results/s15-setup-<date>.md
   ```

3. **Wait about 15 minutes** for Contacts to link the C pair (or link the two "ZZ Spike S15 C Linked" cards by hand). Then:

   ```sh
   c2m-spike s15-noted-writes run            # dry run: "C pair linked: YES"?
   c2m-spike s15-noted-writes run --yes      # matrix + checks → Spikes/results/s15-<date>.md
   ```

   Add `--allow-unlinked` if the pair never links, and `--scripting-all` to also run the scripting path for operations CNSaveRequest did not fail on (for example, to compare labeled-value ids on the control card).

   Look for these:

   - `134092` cells for B and C-iCloud where A is `ok`; whether C-Google (no note, linked) fails too;
   - `PARTIAL` after any failed save, and `NOTE CHANGED` anywhere;
   - whether any variant (V1–V5) or the kit adapter (K) succeeds on a noted card;
   - for the AS column: verified, phone labeled-value id kept, history only on the target card;
   - the `ID` rows: do Contacts.app email/phone/url ids equal `CNLabeledValue.identifier`?

4. **Clean up:** `c2m-spike cleanup --spike s15 --yes`. The noted cards (B, C-iCloud, and D if it survived) can't be deleted through CNSaveRequest, so `cleanup` deletes them through Contacts.app scripting after checking both sides. Then check iCloud.com and contacts.google.com for leftover "ZZ Spike S15" cards.

### S16 run steps

`c2m-spike s16-scripted-writes` runs the app's real write routing, `CardWriteRouter` → `ScriptingCardWriter` / `CNContactStoreAdapter`, against the real Contacts store and Contacts.app. Writes go only to `ZZ Spike S16 …` scratch cards and `ZZ Spike S16 Group`: before every `router.apply`, each target is checked in CNContactStore (the S13 batch guard, spike tag `s16`) and in Contacts.app (the S14 guard); one failing target refuses the whole batch. iCloud only; no Google account and no waiting needed. For what each step checks, see [`Spikes/README.md`](../Spikes/README.md#s16-the-production-write-routing-cardwriterouter--scriptingcardwriter-on-scratch-cards).

1. **Rebuild** (step 1 above). S16 also links `SyncEngine` from the working-tree kit.

2. **Setup.** Creates B (note, set by the production `ScriptingNotesProvider`; emails, phones, URLs, address, related name, Twitter profile, Skype IM) and A (same fields, no note), and the scratch group.

   ```sh
   c2m-spike s16-scripted-writes setup          # dry run
   c2m-spike s16-scripted-writes setup --yes    # → Spikes/results/s16-setup-<date>.md
   ```

3. **Run.**

   ```sh
   c2m-spike s16-scripted-writes run            # dry run: CNContactStore reads only
   c2m-spike s16-scripted-writes run --yes      # PASS/FAIL table → Spikes/results/s16-<date>.md
   ```

   Look for these:

   - steps 1–5 and 7 "routed via Contacts.app scripting", step 6 "routed via the Contacts framework" (and A's `removeMember` via scripting);
   - the labels: step-1 email = `CNLabelWork`? step-2 phones = `CNLabelPhoneNumberMobile` and `Summer`? step 5: the CN label of an email made with no label;
   - step 4: address, related name, social profile and IM edited under the same labeled-value id;
   - step 8: one `UpdateContactEvent` per card per batch, none for step 7, none on other cards;
   - step 9: B's note byte-exact.

   If `run` reports `scripting(not-determined)`, run `c2m-spike s14-notes check --request-permission` once and allow the prompt.

4. **Clean up:** `c2m-spike cleanup --spike s16 --yes`. B has a note, so `cleanup` deletes it through Contacts.app scripting after checking both sides; it also deletes `ZZ Spike S16 Group`. Then check iCloud.com for leftover "ZZ Spike S16" cards.

---

## S12 findings (2026-10-22)

**Verdict: pass. Contacts.app scripting is a viable notes path without the entitlement.** Raw output follows below.

| Question                         | Result                                                                                                  |
|----------------------------------|---------------------------------------------------------------------------------------------------------|
| Bulk read speed                  | 3,785 ids in 0.24 s + 3,785 notes in 0.28 s = **0.52 s total**. Per-person reads ~8.5 ms (≈36 s for all), so always use bulk. |
| Data shape                       | 1,572 non-empty notes, 2,213 `missing value`, 561 multi-line, median 49 chars, max 49,152 chars.       |
| Id mapping                       | AppleScript `person` = **underlying card**, and its `id` equals the CNContact card id **exactly** (3,785/3,785, `…:ABPerson`). Synthesized unified ids don't resolve (-1728). |
| Write fidelity                   | `set note … ; save` in ~22 ms; re-read matches the written multi-line/Unicode text exactly.            |
| Side effects                     | Card identifier and unified id unchanged; 0 other fields changed; exactly 1 `UpdateContactEvent` on the target card only. |
| Linked pair                      | Notes are **per card**. Writing the Google card left the iCloud card's note `missing value`. We choose the target card explicitly. |
| Automation prompt                | One-time "control Contacts" prompt; warm-up incl. launch 2.0 s. Contacts.app is launched if not running (`--quit-if-launched` quits it after). |
| CNContactNoteKey                 | Still unreadable without the entitlement (as expected).                                                 |

Propagation: confirmed by the user on a re-run (2026-10-22) — a scripted note appears on iCloud.com and iPhone like any Contacts edit. The S13 linked pair (which got a test note on its Google card) was not cleaned up by `cleanup --spike s12` — run `c2m-spike cleanup --spike s13 --yes`.

Design consequences (architecture §8): read notes per card in one bulk call; a record's Apple note = precedence card (stamped/iCloud first), with differing notes on other cards handled like any single-valued field; write through to every writable card of the record and verify per card; launch Contacts.app hidden and quit it if we launched it; headless runs without Automation permission skip notes with a warning (never prompt). These are implemented: see [architecture §8 "As implemented (notes scripting)"](architecture.md#as-implemented-notes-scripting).

## S12 raw output

❯ nix develop path:$PWD -c swift build --package-path Spikes
alias c2m-spike=$PWD/Spikes/.build/debug/c2m-spike
c2m-spike s12-notes probe --quit-if-launched   # read-only; approve the "control Contacts" prompt
c2m-spike s12-notes write --yes                # creates a ZZ Spike scratch card
c2m-spike s12-notes write --yes                # writes a note to it via scripting
c2m-spike s12-notes write --linked --yes       # optional: creates an iCloud+Google pair; wait ~15 min, re-run
c2m-spike cleanup --spike s12 --yes

Building for debugging...
[129 / 131] c2m-spike-product

Build complete! (7.30 sec)
c2m-spike s12-notes probe  2026-10-22T14:35:59Z
CNContactStore: underlying cards=3785 unified contacts=2529
Contacts.app running before: no
Automation permission (pre-check, no prompt): unknown: Contacts.app not running (procNotFound)
warm-up `count every person`: 3785 people in 2.04s (includes launch/prompt)
Automation permission (after warm-up): granted

## Bulk fetch
`id of every person`:   3785 ids   in 0.24s
`note of every person`: 3785 notes in 0.28s
bulk total: 0.52s
people=3785 non-empty notes=1572 empty/whitespace-only=0 missing value=2213
non-empty note length (chars): median=49 max=49152
non-empty notes containing line breaks: 561

## Per-person fetch (`note of person id X`)
20 calls: min=7.1ms median=8.5ms max=28.1ms mean=9.6ms
extrapolated per-person read of 3785 people: 36.3s (vs bulk 0.28s)

## AppleScript `id` vs CNContact identifiers
AppleScript ids: 3785 (distinct 3785)
format: ends with ":ABPerson"=3785 bare UUID=0 other=0
CN: underlying=3785 unified=2529 linked (synthesized unified id)=1256
AS id = card id AND unified id (unlinked card):       1273
AS id = underlying card id only (member of a link):  2512
AS id = synthesized unified id only (linked contact): 0
AS id matches neither:                                0
CN unified contacts with no AS id:   1256
CN underlying cards with no AS id:   0
linked contacts with an AS id equal to their unified id: 0/1256
Reading: AS persons == CN unified contacts when unifiedOnly ≈ linked count and cardOnly = 0;
AS persons == underlying cards when cardOnly ≈ 2 x linked count and unifiedOnly = 0.
Contacts.app running after: yes (launched by this run: yes)
Contacts.app: terminate requested (--quit-if-launched)
c2m-spike s12-notes write  2026-10-22T14:36:02Z
PLAN: s12-notes write: create scratch card
  - create "ZZ Spike S12 Notes <id>" in iCloud container D72A148B-2A8F-4494-A9A1-D7AD30890905:ABAccount (marker kind solo)
  - then re-run `c2m-spike s12-notes write` (dry run) and `--yes` to write the note
  (only cards named "ZZ Spike …" carrying a x-c2mdsync-spike: or x-mdsync-spike: URL are ever modified)
created S12 card identifier=91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson
NEXT: c2m-spike s12-notes write          (dry run)
      c2m-spike s12-notes write --yes
c2m-spike s12-notes write  2026-10-22T14:36:04Z
target: single card "ZZ Spike S12 Notes E867"
  s12/solo card identifier=91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson
  unified id=91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson
  unified members: 1 (all harness cards)
Contacts.app running before: no
AppleScript persons named "ZZ Spike S12 Notes E867": 1
  ids: ["91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson"]
  `person id <91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson>` resolves -> AS id 91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson
AppleScript target person id: 91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson
note before (AppleScript): missing value
CNContactStore can read CNContactNoteKey on this card: no (expected without entitlement)
PLAN: s12-notes write
  - re-verify every underlying card (CNContactStore) and the AppleScript person (name prefix + marker URL)
  - AppleScript: set note of person id "91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson" to <88-char synthetic text>; save
  - re-read via AppleScript; compare CN fields, identifiers and change history before/after
  (only cards named "ZZ Spike …" carrying a x-c2mdsync-spike: or x-mdsync-spike: URL are ever modified)

## Write
set note + save: OK in 23ms
re-read via AppleScript: MATCHES written text

## CNContactStore view after the AppleScript write
s12/solo card: identifier unchanged=true other fields changed=0
s12/solo card found by marker under same id: true
unified id unchanged: true
change history since pre-write token (unify=false): 1 events
  s12/solo card: UpdateContactEvent
  other contacts with events: 0 (unrelated activity or sync)

Verify off-device (after 1-5 min of sync):
  - iCloud.com > Contacts > "ZZ Spike S12 Notes E867": is the note there?
  - iPhone Contacts: same card, Notes field.
Then: c2m-spike cleanup --spike s12 [--yes]
c2m-spike s12-notes write --linked  2026-10-22T14:36:09Z
target: linked pair "ZZ Spike S13 Linked 1A5A"
  s13/linked-google card identifier=9DE301D0-802D-4273-8598-B98AFE0566E2:ABPerson
  s13/linked-icloud card identifier=9F4C5B2F-FFAB-413B-888B-DF07E6FAB669:ABPerson
  unified id=4F0249AF-75DA-4A8E-9A45-A5915AAD7560
  unified members: 2 (all harness cards)
Contacts.app running before: yes
AppleScript persons named "ZZ Spike S13 Linked 1A5A": 2
  ids: ["9DE301D0-802D-4273-8598-B98AFE0566E2:ABPerson", "9F4C5B2F-FFAB-413B-888B-DF07E6FAB669:ABPerson"]
  `person id <9DE301D0-802D-4273-8598-B98AFE0566E2:ABPerson>` resolves -> AS id 9DE301D0-802D-4273-8598-B98AFE0566E2:ABPerson
  `person id <9F4C5B2F-FFAB-413B-888B-DF07E6FAB669:ABPerson>` resolves -> AS id 9F4C5B2F-FFAB-413B-888B-DF07E6FAB669:ABPerson
  `person id <4F0249AF-75DA-4A8E-9A45-A5915AAD7560>` -> AppleScript error -1728: Can't get person id "4F0249AF-75DA-4A8E-9A45-A5915AAD7560".
AppleScript target person id: 9DE301D0-802D-4273-8598-B98AFE0566E2:ABPerson
note before (AppleScript): missing value
CNContactStore can read CNContactNoteKey on this card: no (expected without entitlement)
PLAN: s12-notes write
  - re-verify every underlying card (CNContactStore) and the AppleScript person (name prefix + marker URL)
  - AppleScript: set note of person id "9DE301D0-802D-4273-8598-B98AFE0566E2:ABPerson" to <88-char synthetic text>; save
  - re-read via AppleScript; compare CN fields, identifiers and change history before/after
  (only cards named "ZZ Spike …" carrying a x-c2mdsync-spike: or x-mdsync-spike: URL are ever modified)

## Write
set note + save: OK in 21ms
re-read via AppleScript: MATCHES written text
  `note of person id <9F4C5B2F-FFAB-413B-888B-DF07E6FAB669:ABPerson>`: missing value

## CNContactStore view after the AppleScript write
s13/linked-google card: identifier unchanged=true other fields changed=0
s13/linked-icloud card: identifier unchanged=true other fields changed=0
s13/linked-google card found by marker under same id: true
s13/linked-icloud card found by marker under same id: true
unified id unchanged: true
change history since pre-write token (unify=false): 1 events
  s13/linked-google card: UpdateContactEvent
  s13/linked-icloud card: no events
  other contacts with events: 0 (unrelated activity or sync)

Verify off-device (after 1-5 min of sync):
  - iCloud.com > Contacts > "ZZ Spike S13 Linked 1A5A": is the note there?
  - contacts.google.com > "ZZ Spike S13 Linked 1A5A": is the note there (Google calls it Notes)?
  - iPhone Contacts: same card, Notes field.
Then: c2m-spike cleanup --spike s12 [--yes]
PLAN: cleanup (1 cards, 0 scratch groups)
  - delete "ZZ Spike S12 Notes E867" identifier=91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson
  (only cards named "ZZ Spike …" carrying a x-c2mdsync-spike: or x-mdsync-spike: URL are ever modified)
deleted 91C0612F-64BC-4FD8-823C-16EB69CF5489:ABPerson

## S14

❯ nix develop path:$PWD -c swift build --package-path Spikes
alias c2m-spike=$PWD/Spikes/.build/debug/c2m-spike
c2m-spike s14-notes check            # read-only: reads all notes, compares with the S12 method (hashes only)
c2m-spike s14-notes write --yes      # scratch cards only: tricky text, 49k-char note, clear, linked pair, fake-ID safety

Building for debugging...
[1 / 1]

Build complete! (0.25 sec)
c2m-spike s14-notes check  2026-10-22T19:54:06Z
CNContactStore underlying cards: 3781

## Permission and availability
Contacts.app before: not running
  [PASS] currentPermission() launches nothing: unknown
  [PASS] currentPermission() is unknown while Contacts.app is not running: unknown
availability(): scripting(granted)
Contacts.app after availability(): running (hidden false, frontmost false)
  [FAIL] Contacts.app launched hidden, not frontmost: running (hidden false, frontmost false)
  [PASS] availability() == scripting(granted): scripting(granted)

## Bulk read: readAll(cardIDs: nil)
read 3781 cards in 1.32s (non-empty 1572, nil 2209)
  [PASS] bulk read returns notes: 3781 cards, 1572 non-empty
  [PASS] bulk read under 5 s: 1.32s (includes the readiness probe on first use)
  [PASS] Contacts.app ids round-trip to CN card ids: provider 3781, CN 3781, provider-only 0, CN-only 0

## Bulk read: readAll(cardIDs: <every CN card id>)
read 3781 of 3781 cards in 0.67s
  [PASS] every CN card id seen: missing 0
  [PASS] same notes as readAll(nil) (hashes): same 3781, differ 0, only-left 0, only-right 0

## Parity with the S12 NSAppleScript bulk read (per-card SHA-256)
NSAppleScript: 3781 cards in 0.79s
  [PASS] provider bulk == NSAppleScript bulk (ids): provider 3781, NSAppleScript 3781
  [PASS] provider bulk == NSAppleScript bulk (note hashes): same 3781, differ 0, only-left 0, only-right 0
  digest provider:      415b057c80d0f4ce
  digest NSAppleScript: 415b057c80d0f4ce

## Per-card read: readAll(cardIDs: <39 random + 1 bogus>)
read 39 of 40 ids in 0.66s (16.6 ms per id)
  [PASS] every sampled card returned: 39/39
  [PASS] per-card notes == bulk notes (hashes): same 39, differ 0, only-left 0, only-right 0
  [PASS] unknown id is absent (unknown), not empty: absent
  [PASS] 41 ids (bulk + filter) == bulk notes: 41 returned in 0.66s; same 41, differ 0, only-left 0, only-right 0

## finishSession()
Contacts.app before finishSession(): running (hidden true, frontmost false); after: not running
  [PASS] launched by the provider → quit by finishSession(): not running

## Summary: PASS 15  FAIL 1  WARN 0  INFO 0  SKIP 0
| Step | Check | Result | Detail |
|---|---|---|---|
| 0 | currentPermission() launches nothing | PASS | unknown |
| 0 | currentPermission() is unknown while Contacts.app is not running | PASS | unknown |
| 0 | Contacts.app launched hidden, not frontmost | FAIL | running (hidden false, frontmost false) |
| 0 | availability() == scripting(granted) | PASS | scripting(granted) |
| 1 | bulk read returns notes | PASS | 3781 cards, 1572 non-empty |
| 1 | bulk read under 5 s | PASS | 1.32s (includes the readiness probe on first use) |
| 1 | Contacts.app ids round-trip to CN card ids | PASS | provider 3781, CN 3781, provider-only 0, CN-only 0 |
| 2 | every CN card id seen | PASS | missing 0 |
| 2 | same notes as readAll(nil) (hashes) | PASS | same 3781, differ 0, only-left 0, only-right 0 |
| 3 | provider bulk == NSAppleScript bulk (ids) | PASS | provider 3781, NSAppleScript 3781 |
| 3 | provider bulk == NSAppleScript bulk (note hashes) | PASS | same 3781, differ 0, only-left 0, only-right 0 |
| 4 | every sampled card returned | PASS | 39/39 |
| 4 | per-card notes == bulk notes (hashes) | PASS | same 39, differ 0, only-left 0, only-right 0 |
| 4 | unknown id is absent (unknown), not empty | PASS | absent |
| 5 | 41 ids (bulk + filter) == bulk notes | PASS | 41 returned in 0.66s; same 41, differ 0, only-left 0, only-right 0 |
| L | launched by the provider → quit by finishSession() | PASS | not running |

wrote /Users/pwalsh/src/sideprojects/mbr-apple-contact-sync/Spikes/results/s14-check-2026-10-22T1354.md
c2m-spike s14-notes write  2026-10-22T19:54:11Z
PLAN: s14-notes write
  - create "ZZ Spike S14 Notes DC3C" in iCloud container D72A148B-2A8F-4494-A9A1-D7AD30890905:ABAccount (SafeWriter)
  - create "ZZ Spike S14 Linked DC3C" in iCloud D72A148B-2A8F-4494-A9A1-D7AD30890905:ABAccount and Google 9954162F-7192-4169-9E2C-1B31F2C06471:ABAccount (same name + email); case 4 is SKIPPED until Contacts links them
  - every provider.write: re-verify each target on CNContactStore AND in Contacts.app (name prefix + marker, spike tag s14); refuse otherwise
  - case 1: multi-line Unicode note (quotes, backslashes, emoji, CRLF) → read back via provider and NSAppleScript, exact
  - case 2: ~49,000-character note → exact
  - case 3: clear (nil) → reads back nil/empty
  - case 4: one provider.write with the same note for both linked cards → both read back
  - case 5: an injection-shaped id that exists nowhere → per-card failure, nothing changes
  - then: case-1 note left on the solo card for an off-device check; CN identifiers, fields, history and every other card's note (hashes) compared before/after
  (only cards named "ZZ Spike …" carrying a x-c2mdsync-spike: or x-mdsync-spike: URL are ever modified)
created S14 solo card identifier=6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson
created S14 icloud pair card identifier=1CE02C0F-ACF1-4E9E-B3F9-A742BD6141DD:ABPerson
created S14 google pair card identifier=3C9BB0DA-F73E-4D01-B273-21C1A8DF0FD2:ABPerson

## Permission and availability
Contacts.app before: not running
  [PASS] currentPermission() launches nothing: unknown
  [PASS] currentPermission() is unknown while Contacts.app is not running: unknown
availability(): scripting(granted)
Contacts.app after availability(): running (hidden false, frontmost false)
  [FAIL] Contacts.app launched hidden, not frontmost: running (hidden false, frontmost false)
  [PASS] availability() == scripting(granted): scripting(granted)

## Contacts.app sees the solo card
  [PASS] solo card resolves in Contacts.app: 6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson
baseline: 3784 cards, 3784 notes read, 1 target card(s)

## Case 1: multi-line Unicode note (CRLF, quotes, backslashes, emoji)
  [PASS] provider.write reports written: 199 ms; failed: [:]
  [PASS] provider read-back == written (270 chars): exact (356 UTF-8 bytes)
  [PASS] NSAppleScript read-back == written: exact (356 UTF-8 bytes)

## Case 2: ~49k-character note
  [PASS] provider.write reports written: 169 ms; failed: [:]
  [PASS] provider read-back == written (48999 chars): exact (59779 UTF-8 bytes)
  [PASS] NSAppleScript read-back == written: exact (59779 UTF-8 bytes)

## Case 3: clear the note (nil)
  [PASS] provider.write reports written: failed: [:]
  [PASS] provider reads nil/empty: 0 chars
  [PASS] NSAppleScript reads missing value/empty: 0 chars
  [SKIP] linked pair write: no linked harness pair yet; re-run once linked

## Case 5: injection-shaped id that exists nowhere
  id: ZZ-SPIKE-S14-NO-SUCH-CARD-F78486BF-4CA5-43E2-A0B4-FAC8D7E9372F:ABPerson" & (do shell script "touch /tmp/c2m-spike-s14-injected") & "\"; save; --
  [PASS] provider read: absent (unknown), not empty
  [PASS] provider.write: per-card failure, nothing written: Contacts.app scripting error -1728: Apple Event failed
  [PASS] failure is "no such object" (-1728): Contacts.app scripting error -1728: Apple Event failed

## Case 6: leave the case-1 note on the solo card (off-device check)
  [PASS] provider.write reports written: 158 ms; failed: [:]
  [PASS] provider read-back == written (270 chars): exact (356 UTF-8 bytes)
  [PASS] NSAppleScript read-back == written: exact (356 UTF-8 bytes)

## CNContactStore after the provider writes
  [PASS] card 6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson identifier unchanged and still a harness card
  [PASS] card 6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson other fields unchanged
  [PASS] no card added or removed: before 3784, after 3784
change history since the baseline token (unify=false): 1 events
  6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson: UpdateContactEvent
  [PASS] history events on target cards
  [PASS] history events only on target cards
  [PASS] every other card's note unchanged (hashes): 3783 cards
  [PASS] injection payload never ran: /tmp/c2m-spike-s14-injected

Verify off-device (1–5 min): iCloud.com and iPhone → the S14 solo card shows the case-1 note
(emoji, quotes, line breaks).
Then: c2m-spike cleanup --spike s14 --yes

## finishSession()
Contacts.app before finishSession(): running (hidden true, frontmost false); after: not running
  [PASS] launched by the provider → quit by finishSession(): not running

## Summary: PASS 27  FAIL 1  WARN 0  INFO 0  SKIP 1
| Step | Check | Result | Detail |
|---|---|---|---|
| 0 | currentPermission() launches nothing | PASS | unknown |
| 0 | currentPermission() is unknown while Contacts.app is not running | PASS | unknown |
| 0 | Contacts.app launched hidden, not frontmost | FAIL | running (hidden false, frontmost false) |
| 0 | availability() == scripting(granted) | PASS | scripting(granted) |
| 0 | solo card resolves in Contacts.app | PASS | 6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson |
| 1 | provider.write reports written | PASS | 199 ms; failed: [:] |
| 1 | provider read-back == written (270 chars) | PASS | exact (356 UTF-8 bytes) |
| 1 | NSAppleScript read-back == written | PASS | exact (356 UTF-8 bytes) |
| 2 | provider.write reports written | PASS | 169 ms; failed: [:] |
| 2 | provider read-back == written (48999 chars) | PASS | exact (59779 UTF-8 bytes) |
| 2 | NSAppleScript read-back == written | PASS | exact (59779 UTF-8 bytes) |
| 3 | provider.write reports written | PASS | failed: [:] |
| 3 | provider reads nil/empty | PASS | 0 chars |
| 3 | NSAppleScript reads missing value/empty | PASS | 0 chars |
| 4 | linked pair write | SKIP | no linked harness pair yet; re-run once linked |
| 5 | provider read: absent (unknown), not empty | PASS |  |
| 5 | provider.write: per-card failure, nothing written | PASS | Contacts.app scripting error -1728: Apple Event failed |
| 5 | failure is "no such object" (-1728) | PASS | Contacts.app scripting error -1728: Apple Event failed |
| 6 | provider.write reports written | PASS | 158 ms; failed: [:] |
| 6 | provider read-back == written (270 chars) | PASS | exact (356 UTF-8 bytes) |
| 6 | NSAppleScript read-back == written | PASS | exact (356 UTF-8 bytes) |
| 7 | card 6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson identifier unchanged and still a harness card | PASS |  |
| 7 | card 6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson other fields unchanged | PASS |  |
| 7 | no card added or removed | PASS | before 3784, after 3784 |
| 7 | history events on target cards | PASS |  |
| 7 | history events only on target cards | PASS |  |
| 7 | every other card's note unchanged (hashes) | PASS | 3783 cards |
| 7 | injection payload never ran | PASS | /tmp/c2m-spike-s14-injected |
| L | launched by the provider → quit by finishSession() | PASS | not running |

wrote /Users/pwalsh/src/sideprojects/mbr-apple-contact-sync/Spikes/results/s14-write-2026-10-22T1354.md

     ~/src/sideprojects/mbr-apple-contact-sync   main
❯ c2m-spike cleanup --spike s14 --yes                                                                                                                                                                                                                        19s  
PLAN: cleanup (3 cards, 0 scratch groups)
  - delete "ZZ Spike S14 Linked DC3C" identifier=9297FD02-5016-4D7C-A161-9B3040B945C7:ABPerson
  - delete "ZZ Spike S14 Notes DC3C" identifier=6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson
  - delete "ZZ Spike S14 Linked DC3C" identifier=1CE02C0F-ACF1-4E9E-B3F9-A742BD6141DD:ABPerson
  (only cards named "ZZ Spike …" carrying a x-c2mdsync-spike: or x-mdsync-spike: URL are ever modified)
deleted 9297FD02-5016-4D7C-A161-9B3040B945C7:ABPerson
deleted 6B62AB31-433C-4B8B-90F4-2B711026D432:ABPerson
deleted 1CE02C0F-ACF1-4E9E-B3F9-A742BD6141DD:ABPerson


## S14 findings (2026-10-22)

**Verdict: pass — the production `ScriptingNotesProvider` is safe to use on the real address book.**
Results: `Spikes/results/s14-check-2026-10-22T1354.md` (PASS 15, FAIL 1) and `s14-write-2026-10-22T1354.md` (PASS 27, FAIL 1, SKIP 1).

- Bulk and per-card reads match the S12 NSAppleScript method card-for-card (hash parity); unknown ids read as absent, not empty.
- Writes are byte-exact: 270-char multi-line/Unicode/CRLF note (356 bytes) and a 48,999-char note (59,779 bytes); clearing works; Contacts did not rewrite CRLF.
- Bogus/injection-shaped id: per-card `-1728`, nothing written, payload never executed.
- Only target cards changed (3,783 other notes' hashes unchanged; history events only on targets); no cards added/removed.
- `finishSession()` quit Contacts.app because the provider had launched it.
- Propagation: user confirmed the case-6 note reached the iPhone.
- **FAIL (cosmetic):** Contacts.app was running but not yet hidden right after launch (hidden later) → possible brief window flash. Fix assigned (reliable hide-on-launch).
- **SKIP:** linked-pair write (case 4) — the new S14 pair hadn't auto-linked yet; cards were then cleaned up, so case 4 was not run (S12 already showed notes are per card; write-through is covered by engine tests).
- Cleanup found all 3 S14 cards by marker, including the Google card whose id had changed after creation (`3C9BB0DA…` → `9297FD02…`) — another confirmation of Google id churn and that marker/stamp re-location handles it.


## S15 findings (2026-10-24)

Results: `Spikes/results/s15-2026-10-24T1003.md` (iCloud only; Google account off, so the "pair" was two unlinked iCloud cards).

| Card / operation                          | CNSaveRequest (V0–V5 and the kit's CardWriter) | Contacts.app scripting |
|-------------------------------------------|------------------------------------------------|------------------------|
| No note: names, email add, phone edit in place, URLs/stamp | ok (labeled-value ids kept)          | not needed             |
| No note: add to group                     | ok                                             | not needed             |
| No note: **remove from group**            | **saves without error but membership unchanged** (all variants, after waiting 8 s) | ok |
| **Noted: every update incl. group add/remove** | **134092 every time** (no partial change, note intact) | **ok** — one `UpdateContactEvent` on the target, note intact |
| Delete (noted or not)                     | ok                                             | not needed             |

- Scripting `id`s of emails/phones/urls **equal `CNLabeledValue.identifier`**; `phone id <CN id>` edits in place keeping the id; `make new email/url` return the new id. `group id <CNGroup.identifier>` resolves.
- Contacts' `CoreData: error … 134092` lines are printed to stderr by the framework on each failed save.
- Design consequence: card writes route through Contacts.app scripting for cards that have a note (or when a CN save fails with 134092), and group removals always go through scripting (CN `removeMember` is a silent no-op). Without Automation permission those writes are held with a clear reason.
- Implemented (2026-10-24): `CardWriteRouter` + `ScriptingCardWriter`, architecture §6 "Write routing". Still to check on scratch cards with the production writer: the raw-event forms (`make new … at end of …`, `delete … id`, `add/remove … group`), what label a raw `_$!<Work>!$_` is stored as, and element ids for addresses, related names, social profiles and IMs. These are spike S16 (`c2m-spike s16-scripted-writes`, [run steps](#s16-run-steps)).


## S16 findings (2026-10-24)

Results: `Spikes/results/s16-2026-10-24T1117.md` — PASS 91, FAIL 3, INFO 1. Production `CardWriteRouter` + `ScriptingCardWriter` on iCloud scratch cards.

- Noted card B, all via Contacts.app scripting, notes intact, exactly one `UpdateContactEvent` per batch, no other cards touched: names/job title, in-place phone edit (id kept), new email, URL delete, stamp, clearing a field with `""`, group add **and remove**, in-place address / related name / social profile edits (ids kept).
- **Labels:** raw `_$!<Work>!$_` / `_$!<Mobile>!$_` sent through scripting are stored as the built-in labels; custom `Summer` works; an email made with no label gets `_$!<Other>!$_`.
- Un-noted card A: updates and addMember via the framework (no 134092 retry); removeMember via scripting and it sticks.
- Image and birthday on noted cards: reported skipped/unapplyable, nothing written.
- **Gap (the 3 FAILs):** in-place edit of an **instant message** on a noted card fails with `-1728` (Contacts.app can't resolve the IM element by id). The other edits in the same batch were saved; the card reported as failed, so it would be retried every run. Fix: alternative IM addressing (delete + make) or unapplyable.
