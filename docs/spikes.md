# Spikes (run before M1)

Each spike is a throwaway target under `Spikes/` with a written result here. Run them against a **test Apple ID or a few scratch contacts**, not the real address book, until the write paths are proven.

| #  | Question                                                                                  | Why it matters                                     | Pass criteria / decision                                                                 | Status |
|----|-------------------------------------------------------------------------------------------|----------------------------------------------------|------------------------------------------------------------------------------------------|--------|
| S1 | Does a URL with custom label `c2mdsync` and value `x-c2mdsync:<uuid>` survive on iCloud and Google cards? Check second Mac, iPhone, contacts.google.com, iCloud.com, and after a web edit. | Identity strategy depends on it.                  | Survives on iCloud → keep plan. If Google strips it: stamp iCloud card only; Google-only contacts rely on cached CN id + strong keys. | **partial**: iCloud passes. Google stamp not tested (no Google container at the time); indirect evidence that custom-label URLs survive on Google |
| S2 | Notes entitlement: can `com.apple.developer.contacts.notes` be included in a Developer ID provisioning profile; does the notarized app read/write notes; does an un-entitled build get error 102 rather than crash? | Body ↔ notes mapping.                             | Document the exact behavior both ways; confirm runtime feature-detect works.            | **blocked** on Apple approval. Un-entitled CLI: no error 102; the key is silently unavailable |
| S3 | Change-history shim: enumerate via ObjC, persist token, verify `excludedTransactionAuthors`, force 603/604, measure drop-everything size. | M5 live watch efficiency.                         | Shim compiles (done in M0 skeleton); behavior documented.                                | **done** (iCloud only, before Google was enabled). 603 not provoked; a bogus token gives no 604 |
| S4 | Unified-contact write semantics: saving to the iCloud card when a linked Google card has a different value — what does the unified view show? Does saving a mutable copy of a unified contact route values predictably? Are `CNLabeledValue.identifier`s stable across saves and iCloud round trips? | Anti ping-pong, write targeting.                  | Rules in architecture §6 confirmed or revised.                                           | **done** for local save semantics. **Partial** on round-trip id stability (longest gap was about 4 min) |
| S5 | Server normalization catalog: how iCloud and Google rewrite phones, addresses, URLs, labels, birthdays without year, images. | Comparison keys + fake-store fixtures.            | Table of before/after values committed as fixtures.                                     | **partial**: iCloud checked about 70 s after create. Google not captured (card id changed; the check looks up by id) |
| S6 | iCloud Drive: does `.c2mdsync/` sync? How do dataless files appear in enumeration and FSEvents? Do two devices writing identical bytes create conflict copies? Is `NSFileVersion` populated? | Vault state + multi-device.                       | If dot-dirs don't sync, switch to visible `_c2mdsync/` (mbr would then show it — check mbr ignore config). | todo |
| S7 | Yams emitter byte-stability and round-trip of comments/key order.                         | Minimal diffs, preserving user edits.             | Decide: Yams for parse only + own emitter for managed keys (expected).                   | done (M1): Yams parses only; own emitter + span patching; see markdown-schema §4 |
| S8 | Build/TCC: does ad-hoc signed Nix build re-prompt for Contacts after each rebuild? Does Xcode Debug signed with the team keep the grant? | Dev ergonomics, install path.                      | Expected: ad-hoc re-prompts; use team-signed Debug for daily dev; Developer ID release for nix-darwin. | todo (no evidence yet; S11 never granted the binary itself) |
| S9 | Is `CNContact.identifier` stable across Contacts.app link/unlink and across iCloud sign-out/in on this Mac? | Validates cascade step 2 confidence.              | Record observed behavior.                                                                | **partial**: only a 30 s compare with no experiment in between. Side evidence: Google card ids change once after create; iCloud ids stayed stable through the Google enable |
| S10| Does the real `mbr` render our fixture files with zero contact problems (incl. `[[Title]]` relationships after moving files into subfolders)? | Format contract.                                   | Add mbr as flake input + check derivation in M1.                                         | done (M1): `checks.mbr` / `just mbr-check` — 59 fixture notes, 0 problems with mbr 0.7.0 |
| S11| Headless TCC + sandbox: does the app binary run with a `sync` argument from Terminal, cron and a launchd user agent keep the app's Contacts grant and read its security-scoped bookmark? | Headless CLI (architecture §15).             | Works from launchd at minimum. Otherwise fall back to `open -g -a … --args sync`. | **partial**: Terminal is authorized. launchd and cron report `notDetermined`; `--request` was never tried, so prompting and granting are untested. Bookmark not tested |

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
- **Google: no data.** The check looked the card up by its creation-time id, which had changed, so all 42 rows read `∅`. That's a harness limitation, not something Google did. Before re-running, the check needs a fallback that finds the card by marker.
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

### Proposed design implications (not yet applied to architecture.md)

1. Automatic linking turns most iCloud+Google duplicates into one unified contact. "One file ↔ one unified contact" still holds, and union-find clustering stays as a safety net for the remaining ~98 Google-only and ~1172 iCloud-only cards. "Two stamps on one unified contact" becomes a likely path: Contacts can link two already-stamped contacts on its own, for example when a Google account is enabled later.
2. Read single-valued fields per underlying card using a deterministic precedence: stamped or iCloud card first. Don't read them from the unified view, which can flip when Google re-saves its card.
3. When an edit or delete targets a value that exists on several linked cards, apply it to every card holding that value (matched by comparison key). Otherwise the copy on the other card comes back.
4. Never save a unified mutable copy. It writes to every linked card.
5. Don't trust a Google card's id until a later snapshot finds it again by its stamp. An id that disappears is not a delete.
6. Key on underlying card ids. Treat the unified id as a volatile cache.
7. Comparison keys:
   - dates: ignore the calendar;
   - social profiles: key on (service, username), and ignore a synthesized `urlString`;
   - image: treat `imageDataAvailable=false` with a thumbnail present as unknown, never as deleted;
   - never key anything on social-profile lv ids.
8. History: an invalid token doesn't raise an error. A `DropEverything` event is the reset signal.
9. Headless runs from launchd or cron don't inherit a terminal's grant. The question is still open for the real app identity.

### Cleanup status

- `inventory` at 04:48Z reports `harness cards: 0  name-only (marker lost): 0  marker-only: 0`. The unified count dropped by exactly 5 (2531 → 2526), which matches removing the S1, S3, S5-iCloud and S5-Google cards and the S4 pair. All scratch cards are gone from this Mac. Nobody has checked iCloud.com or contacts.google.com for leftovers.
- The LaunchAgent is no longer loaded (`launchctl print` can't find it), but `~/Library/LaunchAgents/com.zmre.c2m-spike.s11.plist` still exists. No cron line remains. The logs `/tmp/c2m-spike-s11-{launchd,cron}.log` are still there.
