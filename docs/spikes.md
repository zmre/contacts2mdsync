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
| S12| Notes without the entitlement: can we read and write the Notes field by scripting Contacts.app with Apple Events (`note` and `id` of `person`)? How long do a bulk read and a per-person read take for about 2,500 contacts? Do AppleScript ids match CNContact card ids or unified ids? Which card of a linked pair gets the write? | Body ↔ notes mapping while S2 is blocked on Apple. | Bulk read of all notes takes a few seconds or less, writes keep the text exactly, no other fields or ids change, the linked-pair write target is predictable, and the Automation prompt is acceptable. Then Apple Events become the fallback notes path in architecture §8. | todo |

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
