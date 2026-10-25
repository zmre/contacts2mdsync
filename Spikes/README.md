# c2m-spike: the spike harness

`c2m-spike` is a command-line tool for the spikes in [`docs/spikes.md`](../docs/spikes.md) that need a real address book: S1, S3, S4, S5, S9, S11, S12, S13, S14, S15 and S16. It also gives partial evidence for S2 (the notes-key probe in `inventory`). S1–S12 use Contacts.framework directly. S13–S16 link `ContactModel` and `ContactsAdapter` from `Packages/Contacts2MdSyncKit` (a path dependency) so they can run the app's real write path and its real notes provider; S16 also links `SyncEngine` for the real write routing (`CardWriteRouter`). The harness never modifies the kit.

## Safety model

- **Writes only touch scratch cards.** A card counts as a harness card only if both of these hold: its name (`givenName familyName`) starts with `ZZ Spike `, and one of its URL values starts with `x-c2mdsync-spike:`. That URL carries the label `c2mdsync-spike` and has the form `x-c2mdsync-spike:<spike>:<account>:<uuid>`. Scratch cards created before the rename carry the legacy marker `x-mdsync-spike:` (label `mdsync-spike`); the harness still recognizes those for checks and cleanup (the name prefix is still required), but never creates new ones. The harness never reads or writes the notes field through Contacts.framework. The exceptions are S12, S14, S15 and S16: they use Apple Events to Contacts.app to write synthetic notes, and only to scratch cards. (S15's `V5` variant also asks CNContactStore to fetch `CNContactNoteKey` on its scratch cards, to see whether the fetch fails; the value is never read.)
- **S12 writes go through Contacts.app, so they are checked on both sides.** Right before `set note`, `s12-notes write` verifies every underlying card behind the target with `SafeWriter.verifiedCard`. It also asks Contacts.app for the target person's `id`, first and last name, and `url` values, and refuses unless they show the `ZZ Spike ` prefix and one of the expected marker URLs. The handler arguments are passed as Apple Event descriptors, never pasted into script source.
- **S14 runs the app's real notes provider behind a two-sided guard.** `s14-notes write` calls `ScriptingNotesProvider.write` only through `S14NotesGuard` (`Sources/c2m-spike/Commands/S14Notes.swift`). Before every call it fetches each target card again by id with unified results off; the card must pass both checks and carry the `s14` spike tag (or `s13`, only for the reused S13 linked pair). It also asks Contacts.app (through the S12 `NSAppleScript` reader) for the person with that id, which must show the `ZZ Spike ` prefix and the same marker URL. One target that fails refuses the whole write. The one write that is not to a harness card is case 5: an injection-shaped id that the guard first proves exists nowhere (not a CN card id, and `person id <it>` does not resolve in Contacts.app). `s14-notes check` and `write` print note text only for the synthetic notes they write; real notes are compared by SHA-256 only.
- **Checks happen right before every write.** All writes go through `SafeWriter` (`Sources/c2m-spike/Support/Harness.swift`). It fetches the target card again by identifier with unified results off, refuses to continue unless the card passes both checks, and checks again after the mutation. A save to a unified contact (S4 `--unified-write`) requires every underlying card to pass.
- **S13 runs the app's real write path behind a harness guard.** `s13-writes` calls `CNContactStoreAdapter.apply` (which uses `CardWriter`) only through `HarnessGuardedStore` (`Sources/c2m-spike/Support/KitGuard.swift`). Before each batch, the guard fetches every target card again by id with unified results off. Every card must pass both checks and carry the `s13` spike tag, or the guard refuses the whole batch and nothing is saved. The guard also refuses a URL-list edit that would drop the marker, a name edit that would drop the `ZZ Spike ` prefix, note and image edits, a create without the prefix and an `s13` marker, and group operations on any group other than `ZZ Spike S13 Group`. After the save it checks the cards again. The wrapper exposes only `apply`, so the harness can't reach any other write entry point.
- **S15 writes are checked on both sides too.** Every CNSaveRequest in `s15-noted-writes run` fetches its target again by id (unified results off, in the store the variant uses) and refuses unless it is the expected S15 card: both checks, spike tag `s15`, and the marker recorded at setup. Group writes need the exact name `ZZ Spike S15 Group`; deletes are refused on any card except D and E. Every Contacts.app scripting write first runs the S14 guard (`S14NotesGuard.checkTargets`: CNContactStore and Contacts.app must both show the S15 harness card). The scripting handlers (`Support/S15Scripting.swift`) take person, group and labeled-value ids and values as Apple Event descriptors, never as script source.
- **S16 runs the app's real write routing behind both guards.** `s16-scripted-writes run` calls `CardWriteRouter.apply` (around the real `CNContactStoreAdapter`, with the real `ScriptingCardWriter`) only through `S16Runner.guarded` (`Sources/c2m-spike/Commands/S16ScriptedWrites.swift`). Before each batch it runs the S13 batch guard (`HarnessBatchGuard`: every target fetched again with unified results off, both checks, spike tag `s16`, marker kept by URL edits, `ZZ Spike ` prefix kept, groups only `ZZ Spike S16 Group`, no note edits, no creates or deletes) AND the S14 guard (`S14NotesGuard`: Contacts.app shows the same person with the prefix and marker). Image and birthday edits are allowed only on a card whose note the provider reads as present right now, so the router sends them to scripting, which skips them. One failing target refuses the whole batch; after the save the targets are checked again.
- **Writes are dry runs until you add `--yes`.** Every write subcommand prints its plan. Without `--yes`, nothing is written.
- **`cleanup` needs both markers.** It deletes only cards that pass both checks. It deletes a scratch group (`ZZ Spike S13 Group`, `ZZ Spike S15 Group`, `ZZ Spike S16 Group`) only if the group's name is exactly that and it is empty or holds only harness cards; this is checked again right before the delete. A card with a note can't be deleted through CNSaveRequest without the notes entitlement (S15), so when the CNSaveRequest delete fails, `cleanup` deletes the card through Contacts.app scripting (`delete person id X`, `save`), after CNContactStore and Contacts.app both confirm it is the same harness card. `--no-scripting` turns that off. If a card matches only one, `cleanup` lists it and you delete it by hand. This can happen when Google strips the marker URL during S1 or S5.
- **Read-only output contains no PII.** `inventory`, `s9-ids`, `s12-notes probe` and `s14-notes check` print counts, timings and opaque identifiers only. `s12-notes probe` and `s14-notes check` read every note but never print note text or names. Container names that contain `@` are redacted. S9 files store SHA-256 hashes of identifiers.

## Build

```sh
nix develop path:/Users/pwalsh/src/sideprojects/mbr-apple-contact-sync -c swift build --package-path Spikes
alias c2m-spike=$PWD/Spikes/.build/debug/c2m-spike   # from the repo root
c2m-spike --help
```

The linker embeds `Spikes/Info.plist` into the binary's `__TEXT,__info_plist` section (`-sectcreate`), so a bare CLI carries `NSContactsUsageDescription`. To check it:

```sh
launchctl plist __TEXT,__info_plist Spikes/.build/debug/c2m-spike
```

**Run it from Terminal** (or iTerm, Ghostty, and so on). TCC charges the Contacts grant to the terminal app, the "responsible process". The first command that touches Contacts triggers the prompt. You can also enable your terminal under System Settings ▸ Privacy & Security ▸ Contacts.

`Spikes/Info.plist` also carries `NSAppleEventsUsageDescription`, for S12. The first S12 command that sends an Apple Event makes macOS ask **"<your terminal> wants to control Contacts"** (sometimes it names `c2m-spike`). Click OK. The grant appears under System Settings ▸ Privacy & Security ▸ Automation ▸ <your terminal> ▸ Contacts. If you refuse it, Apple Events fail with error -1743; the command prints how to fix that. To ask again: `tccutil reset AppleEvents` (this resets Automation for every app). The binary is ad-hoc signed without the hardened runtime, so it doesn't need the `com.apple.security.automation.apple-events` entitlement. A notarized app would need it.

Results go to `Spikes/results/`. To write them somewhere else, set `C2M_SPIKE_RESULTS=/path`. The `*.json` and `*.bin` files there are local to this machine and gitignored.

## Picking accounts

iCloud and Google are both `cardDAV` containers, so the harness tells them apart by container name: a name containing `icloud` is iCloud, and one containing `google` or `gmail` is Google. If the guess fails or is ambiguous, run `inventory`, copy the container identifiers, and pass `--icloud-container <id>` and `--google-container <id>` to any subcommand that creates cards.

## Recording results

For each spike:

1. Change its **Status** cell in the table in `docs/spikes.md` from `todo` to `done`, or to `partial` with a note.
2. Under **## Results**, add a subsection `### S<n> (<date>, <macOS version>, <accounts used>)`. Paste the relevant tool output and the answer to the spike's question. Note anything that changes the plan, such as an architecture section to revise.

---

## 0. Inventory (do this first)

```sh
c2m-spike inventory
```

This is read-only. It reports:

- containers by type and name, marking the default one
- cards and groups per container
- underlying vs unified counts, and a histogram of cards per unified contact
- how many unified contacts are linked across iCloud and Google
- the notes-key probe
- whether a history token is present
- how many harness cards exist

**Observe:**

- **Notes probe.** `notes readable: no -- ... code 102` means no notes entitlement and no crash. A `yes` would be surprising for an unentitled binary.
- **Mapping check.** If `unified (fetch)` and `unified (distinct via mapping)` disagree, `unifiedContact(withIdentifier:)` doesn't map underlying cards the way the docs say.

**Record:** paste the output (it's PII-free) at the top of Results as baseline context. Put the notes-probe line under S2 as "un-entitled CLI behavior".

## S1: does the stamp URL survive?

```sh
c2m-spike s1-stamp create --container icloud          # dry run: shows the plan
c2m-spike s1-stamp create --container icloud --yes
c2m-spike s1-stamp create --container google --yes
c2m-spike s1-stamp check                              # right away: local baseline
```

Each card gets two URLs: the marker, and the stamp under test (label `c2mdsync`, value `x-c2mdsync:<uuid>`). `s1-stamp check` also recognizes the legacy stamp (label `mdsync`, value `x-mdsync:<uuid>`) on cards created before the rename.

1. Wait 5–15 minutes. Then look at both cards on your iPhone, at iCloud.com, and at contacts.google.com. Is the URL there, and what label does it show?
2. Run `c2m-spike s1-stamp check` again on this Mac. If a second Mac has the harness built, run it there too. Identifiers will differ on another device, and the ledger is local to each machine.
3. Edit a different field of each card on the web: the phone on iCloud.com and the job title on contacts.google.com. Wait for sync, then run `check` again.

**Observe**, per account:

- stamp label: `intact`, `CHANGED -> …`, or `MISSING`
- stamp value: exact or rewritten
- marker: intact or missing
- `in ledger`: does the identifier still match what was created?

If Google drops custom labels, the card shows up as a name-only match. It still appears in `check`, but `cleanup` won't touch it.

**Decide** using the S1 pass criteria in `docs/spikes.md`.

## S3: change history through the ObjC shim

```sh
c2m-spike s3-history                     # nil token: DropEverything + full snapshot; saves results/token.bin
c2m-spike s3-history --since             # edit any scratch card in Contacts.app first, then run
c2m-spike s3-history --bogus-token       # provoke the invalid-token error (expect 604?)
c2m-spike s3-history --author com.zmre.contacts2mdsync.spike          # dry run
c2m-spike s3-history --author com.zmre.contacts2mdsync.spike --yes    # creates or reuses an S3 scratch card
```

The tool prints only event counts by type, never contact data. The `--author` run works in four steps:

1. It edits the S3 card with `transactionAuthor` set.
2. It fetches since the pre-edit token, once without and once with `excludedTransactionAuthors`.
3. It makes a control edit with no author.
4. It fetches again with the exclusion.

**Observe:**

- The event count and elapsed time for the nil-token fetch. This is the "drop-everything size".
- Whether `--since` returns only your change.
- The error domain and code for the bogus token. Is it an NSError or an ObjC exception? The shim catches both.
- The two `RESULT:` lines from the `--author` run.
- Optionally, `--no-unify` and `--include-groups`.

To try for error 603 (token expired), keep `token.bin` for several days and run `--since` again.

## S4: unified-contact write semantics

```sh
c2m-spike s4-unified create --yes
```

This creates `ZZ Spike S4 Linked <id>` in both iCloud and Google. The two cards share an email but have different job titles and phones. Then:

1. **Link the cards by hand.** In Contacts.app, choose All Contacts, select both cards, then choose Card ▸ Link Selected Cards.
2. `c2m-spike s4-unified check`: read-only. It shows whether the cards are linked and which card the unified id equals. It also prints a table of the unified view's job title, phones and emails, with each labeled-value id and which card it came from. It saves `results/s4-state.json`.
3. `c2m-spike s4-unified check --yes`: writes to the iCloud card. It sets a new job title, changes the existing phone in place, and adds a new phone. Then it reports:
   - the phone labeled-value ids before the save, in the saved object, and after a refetch;
   - which card's job title the unified contact now shows.
4. `c2m-spike s4-unified check --yes --unified-write`: also saves a mutable copy of the unified contact with a new email and job title. It then reports which underlying card each value landed on.
5. Later, after the iCloud/Google round trip, run `c2m-spike s4-unified check` without `--yes`. It compares against the saved state: are the card ids, unified id and labeled-value ids still the same?

**Observe:**

- Does the unified view prefer the iCloud value or the Google value?
- Is the email shown once or twice?
- Do labeled-value ids stay stable through the save, the refetch and the server round trip?
- Which card does a write to the unified copy go to?

**Record:** confirm or revise the rules in architecture §6 ("Stamping and write targets").

## S5: server normalization catalog

```sh
c2m-spike s5-normalize create --yes          # iCloud + Google; or: --account icloud --yes
# wait 5-15 min; open both cards on iCloud.com and contacts.google.com to force a server round trip
c2m-spike s5-normalize check                 # changed rows only
c2m-spike s5-normalize check --all           # every row
```

The catalog covers:

- 11 phone formats: bare digits, punctuation, E.164, extensions, international numbers, custom and nil labels
- emails with mixed case and a label containing spaces
- URLs without a scheme, in uppercase, with query and fragment, and the `x-c2mdsync:` stamp
- 4 addresses: a multi-line street, a lowercase state and ISO code, a city alone, and a UK address with a lowercase postcode
- a yearless Feb 29 birthday, plus anniversary and yearless dates
- social profiles, IM handles and relations
- name prefix and suffix, phonetic name, and organization and department names containing `&` and `/`
- a 256×256 PNG image

`check` prints a markdown table with these columns: written → local refetch (immediately after the save) → now. It shows labels, values, and whether each labeled-value id is the same. It also writes the table to `Spikes/results/s5-<date>.md`.

**Observe:** for each account, every rewrite, and image re-encoding (format, size and hash).

**Record:** paste the table under S5 in Results. The `s5-*.md` file is the input for the `FakeContactStore` normalization fixtures.

## S9: identifier stability

```sh
c2m-spike s9-ids record        # results/ids-<date>.json: sha256 of card id, container id, unified id
# ...do ONE thing: link or unlink cards in Contacts.app (the S4 pair is ideal),
#    or sign out of iCloud on this Mac and back in (wait for full resync)...
c2m-spike s9-ids compare       # against the newest ids-*.json (or --baseline <file>)
```

**Observe:** counts of underlying card ids kept, gone and new. The same for unified ids and container ids. Cards whose unified id or container changed. Harness cards are matched by their marker, so you can see whether a scratch card kept its identifier through an unlink or a sign-out and sign-in.

Record a baseline before each experiment. Run each experiment separately.

**Record:** the compare output (it's PII-free) and the experiment you ran, under S9.

## S11: headless TCC

`s11-headless` prints:

- the pid, parent pid and parent process path
- the bundle id read from the embedded Info.plist
- whether stdin and stdout are TTYs
- a few environment markers: `TERM_PROGRAM`, `XPC_SERVICE_NAME`, `LaunchInstanceID`, and others
- the Contacts authorization status

If the status is authorized, it also prints a unified contact count. It never prompts unless you pass `--request`. The exit code is 0 on success, 3 when there's no access, and 5 when the fetch fails.

1. **Terminal:** `c2m-spike s11-headless`. Expect `authorized`, because the grant belongs to your terminal.
2. **launchd user agent:**
   ```sh
   cp Spikes/launchd/com.zmre.c2m-spike.s11.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.zmre.c2m-spike.s11.plist
   launchctl kickstart -k gui/$(id -u)/com.zmre.c2m-spike.s11
   cat /tmp/c2m-spike-s11-launchd.log
   ```
   The binary path is hard-coded to this checkout. Edit the plist if your checkout is somewhere else. To see whether a prompt appears in this context, add `--request` as a third `ProgramArguments` string. Then check whether the binary appears in System Settings ▸ Privacy & Security ▸ Contacts. Unload with `launchctl bootout gui/$(id -u)/com.zmre.c2m-spike.s11`.
3. **cron:** run `crontab -e` and add
   `* * * * * /Users/pwalsh/src/sideprojects/mbr-apple-contact-sync/Spikes/.build/debug/c2m-spike s11-headless >> /tmp/c2m-spike-s11-cron.log 2>&1`.
   Wait a minute, read the log, then remove the line.
4. Optionally, over SSH into this Mac.

**Observe** for each context:

- the authorization status, and whether the count succeeds;
- whether a prompt appears and who it names;
- the parent process.

The binary is ad-hoc signed, and its identity changes with every rebuild. If you grant the binary itself under launchd, rebuild it, and see the grant disappear, that is evidence for S8.

**Record:** a table with one row per context (Terminal, launchd, cron, ssh) and these columns: status, count ok, prompt?, parent. Put it under S11 together with the conclusion: direct exec works, or use the `open -g -a … --args sync` fallback.

## S12: notes through Contacts.app (Apple Events)

Question: without the `com.apple.developer.contacts.notes` entitlement, can we read and write the Notes field by scripting Contacts.app (`person` has `note` and `id` in its AppleScript dictionary), and is it fast enough for about 2,500 contacts?

```sh
c2m-spike s12-notes probe                       # read-only; launches Contacts.app if needed; first run prompts for Automation
c2m-spike s12-notes probe --quit-if-launched    # same, then quit Contacts.app if this run started it
c2m-spike s12-notes write                       # dry run; creates nothing. Plans the scratch card
c2m-spike s12-notes write --yes                 # creates "ZZ Spike S12 Notes <id>" in iCloud (no note yet)
c2m-spike s12-notes write                       # dry run against the card: resolves the AppleScript person, shows the plan
c2m-spike s12-notes write --yes                 # sets the note via AppleScript and reports
c2m-spike s12-notes write --linked              # finds a linked harness pair (S12, else S4), or plans an S12 pair
c2m-spike s12-notes write --linked --yes        # first run: creates iCloud + Google "ZZ Spike S12 Linked <id>"
#   wait about 15 min for automatic linking (or link them by hand in Contacts.app), then:
c2m-spike s12-notes write --linked --yes        # writes the note to the linked person
```

`probe` makes these Apple Event calls:

1. A warm-up `count every person`. This one absorbs the app launch and the permission prompt.
2. `id of every person` and `note of every person`, timed separately.
3. A sample of single `note of person id X` calls (`--sample`, default 20), with an extrapolation to the whole book.

It also fetches all CNContact identifiers twice, with `unifyResults` off and on, and counts how many AppleScript ids match each set.

Even a dry-run `write` sends **read-only** Apple Events to resolve and check the target person. Only `--yes` writes. Without `--linked`, `write` needs an S12 `solo` card and creates one only with `--yes`. If that card has been linked to anything, every member must be a harness card or the write is refused.

**Observe (`probe`):**

- **Permission.** Was there an Automation prompt, and did it name the terminal or `c2m-spike`? With error -1743, follow the printed steps.
- **Launch.** Was Contacts.app running before, and was it launched by this run?
- **Counts.** People, non-empty notes, notes with line breaks.
- **Timing.** Bulk ids and bulk notes, versus the per-person median and its extrapolation.
- **Id format.** Does `AS id = card id AND unified id`, plus `AS id = synthesized unified id only`, add up to the CN unified count? If so, AppleScript sees unified persons. If `AS id = underlying card id only` is about twice the linked count, it sees cards.

**Observe (`write`):**

- Did `set note` + `save` succeed? How long did it take, and does the AppleScript re-read match? It checks line endings, Unicode and quotes.
- Is CNContactNoteKey readable? Expect no.
- On the CN side: is the identifier unchanged, how many other fields changed, and is the unified id unchanged?
- The change-history events per underlying card (`unify=false`). For a linked pair, these show **which card got the note**. Also look at the per-id `note of person id <card id>` lines, and at whether `person id <card id>` resolves to the unified person.
- Off the device, look at the note on iCloud.com, on contacts.google.com (for the linked pair) and on the iPhone.

**Record:** the probe output (it's PII-free) and the write reports under S12. Then decide: can the body ↔ notes mapping use Apple Events when the entitlement is missing, and if so, read in bulk and write per person?

## S13: the real write path (M3 `ContactStore.apply`) on scratch cards

Question: does the app's real Apple write path (`CNContactStoreAdapter.apply` → `CardWriter`) do the right thing against the real Contacts store, iCloud and Google, before you turn on `apple_writes` for your real address book?

```sh
c2m-spike s13-writes setup                 # dry run: plan + containers
c2m-spike s13-writes setup --yes           # creates 4 scratch cards via CardWriter .create
#   wait about 15 min: automatic linking + Google id churn
c2m-spike s13-writes run                   # dry run: finds the cards by marker, shows whether the pair is linked
c2m-spike s13-writes run --yes             # scripted writes, PASS/FAIL table, results/s13-<date>.md
#   wait 15–30 min; open the S13 cards on iCloud.com and contacts.google.com
c2m-spike s13-writes check                 # read-only round-trip check, results/s13-check-<date>.md
c2m-spike cleanup --spike s13 --yes        # cards + "ZZ Spike S13 Group"
```

`setup` creates these four cards in a single `apply` batch. The marker URL is written through the kit's label mapping, so it shows the label `C2mdsync Spike`. Identity only depends on the URL value.

| Card | Container | Contents |
|---|---|---|
| `ZZ Spike S13 Linked <id>` | iCloud | shared email, shared phone …0113, phone …0114, job title `S13 baseline icloud`, relation `ZZ Spike S13 Assistant` |
| `ZZ Spike S13 Linked <id>` | Google | the same name and shared email, so Contacts links the pair; shared phone …0113, phone …0115, job title `S13 baseline google` |
| `ZZ Spike S13 iCloud <id>` | iCloud | its own email |
| `ZZ Spike S13 Google <id>` | Google | its own email and phone …0116 |

`run` refuses to start until the pair is linked; to run anyway, pass `--allow-unlinked`, which turns the unified-view checks into INFO. Every step finds the cards by marker again, so a Google id that changed is followed. The batches follow architecture §6, *Stamping and write targets*. They are built by hand because `AppleWritePlanner` is internal to the engine and covered by its unit tests. Here are the steps:

0. **Guard self-test.** Each of these batches must be refused before anything reaches the adapter: an unknown card id mixed with a valid edit (so the whole batch is refused), a URL edit that drops the marker, a name edit that drops the prefix, a non-harness create, and a group that isn't the scratch group.
1. **Add an email to the linked contact.** It should land on the iCloud card only. The Google card should not get it, because a unified save would put it on both (S4).
2. **Edit the shared email on both cards.** Each card should show the new value and keep its labeled-value id.
3. **Change the job title on both linked cards.** Check each card again and the unified view.
4. **Delete the shared phone from both cards.** The other phones should keep their ids.
5. **Add a `x-c2mdsync:<uuid>` stamp** to the linked iCloud card and the Google-only card. Check the label, the marker, and the ids of the other URLs. The linked Google card should get no stamp.
6. **Group membership.** The harness creates `ZZ Spike S13 Group` in iCloud, or reuses it. Then it runs `addMember` for both iCloud cards and `removeMember` for the iCloud-only card.
7. **Relations.** Rename the iCloud card's relation; its id and label should be kept. Add a relation to the Google-only card.
8. **No unified save.** Every operation should name an underlying card id, and the step 1 content should be right. The change history should record authored events only on the target cards (`unify=false`).
9. **`transactionAuthor`.** Each batch is tagged `com.zmre.contacts2mdsync.spike-s13`. Unfiltered history should show it, and history with `excludedTransactionAuthors` should hide it.

`run` prints the PASS/FAIL/WARN/INFO/SKIP table, writes `Spikes/results/s13-<date>.md`, and saves `results/s13-state.json`. If a step aborts, for example on a SAFETY refusal, it writes `s13-<date>-aborted.md`.

`check` writes nothing. For each card it reports:

- whether the id is the same or changed (found by marker);
- whether each email, phone, URL and relation value survived, with its labeled-value id, any server rewrites, and any new values;
- the job title and the stamp;
- whether the card is still in the group.

For the unified contact, it reports whether the pair is still linked, whether the unified job title is still the written value and which card supplies it, and whether any email shows twice. It writes `results/s13-check-<date>.md`.

**Observe:** any FAIL in `run`. A WARN in step 8 or 9 can come from Google sync saving the card again at the same moment; run `check` and read the log. In `check`, look for Google rewriting or dropping the stamp (this is also the missing S1 Google evidence), labeled-value ids that change after a round trip, and a unified job title that flips to the other card.

**Record:** the `run` and `check` tables under S13 in `docs/spikes.md`. Then decide whether `apple_writes: enabled` is safe to turn on for the real address book.

## S14: the production notes provider (`ScriptingNotesProvider`) on scratch cards

Question: does the app's real notes path, `ScriptingNotesProvider` (raw Apple Events built by `ContactsScriptingEvents`, Contacts.app launched and quit by `LiveContactsApp`), read every note the same way the S12 `NSAppleScript` reader does, write notes exactly, and leave Contacts.app the way it found it?

```sh
c2m-spike s14-notes check                        # read-only; may launch Contacts.app hidden, then quits it
c2m-spike s14-notes check --request-permission   # only if Automation was never decided: shows the macOS prompt once
c2m-spike s14-notes write                        # dry run: plan only, no Apple Events, nothing created
c2m-spike s14-notes write --yes                  # creates scratch cards if missing, runs cases 1–5
#   if it created an S14 pair: wait ~15 min for automatic linking (or link by hand), then
c2m-spike s14-notes write --yes                  # case 4 now runs on the linked pair
c2m-spike cleanup --spike s14 --yes
```

The provider runs on a background thread, as in the app, while the main run loop keeps turning. The S12 `NSAppleScript` reader runs on the main thread.

`check` sends read-only events and writes `Spikes/results/s14-check-<date>.md`:

0. `currentPermission()` (must launch nothing; `unknown` while Contacts.app is not running), then `availability()`. If the provider launched Contacts.app, is it hidden and not frontmost?
1. `readAll(cardIDs: nil)`: count, non-empty count, time; do the ids equal the CNContact card ids exactly?
2. `readAll(cardIDs: <every CN card id>)`: the bulk path filtered to a list. Every card seen, same notes as step 1?
3. Parity with the S12 `NSAppleScript` bulk read (ids, notes, ids again): same ids, same per-card SHA-256. It prints only a 16-hex digest over the sorted `id hash` lines for each side.
4. `readAll` of 39 random cards plus 1 bogus id: the per-card path (≤ 40). Same hashes as the bulk read; the bogus id is absent (unknown), not empty.
5. `readAll` of 41 random cards: bulk read plus filter.
6. `finishSession()`: Contacts.app quit if the provider launched it and it is still hidden; left running if it was already running.

`write --yes` uses `ZZ Spike S14 Notes <id>` (iCloud; created if missing) and a linked harness pair: an S14 pair if one is linked, else the S13 linked pair from `s13-writes setup`. With no linked pair and no S14 pair cards, it creates an iCloud + Google `ZZ Spike S14 Linked <id>` pair with the same name and email, and skips case 4 until Contacts links them. Every case goes through the guard, then `provider.write`, then reads back through the provider (per-card path) and through `NSAppleScript`:

1. A multi-line Unicode note with CRLF line breaks (and one bare LF), straight and curly quotes, backslashes, `\n` literals, a tab, ZWJ and flag emoji, a decomposed `é`, Hebrew and Arabic, and AppleScript-looking text. PASS means the same UTF-8 bytes. WARN means equal only after line-ending normalization (Contacts converted CRLF), with the CR/LF counts.
2. A deterministic 49,000-character note (S12's longest real note is 49,152). Exact.
3. Clear (`nil`): the provider reads nil or empty, and `NSAppleScript` reads `missing value` or empty.
4. One `provider.write` with the same note for both linked cards: both written, both read back exactly. An S13 pair gets its previous notes back afterwards.
5. An id shaped like an injection (`…:ABPerson" & (do shell script "touch /tmp/c2m-spike-s14-injected") & "\"; save; --`). The guard first proves it exists nowhere. Expect: the provider read leaves it absent, and `write` reports a per-card failure (`-1728`) and writes nothing.
6. The case-1 note is written to the solo card again, for an off-device check.
7. CN side: every target card keeps its identifier and every other field (`Snapshot` rows), the linked pair keeps its unified id, no card was added or removed, change-history events (`unify=false`) appear only on target cards, every other card's note hash is unchanged (bulk re-read), and `/tmp/c2m-spike-s14-injected` does not exist.

It writes `Spikes/results/s14-write-<date>.md`. The exit code is 1 if any row FAILs.

**Observe:** any FAIL; a WARN in case 1 (line endings Contacts rewrites: the provider's own verify normalizes them, so it still reports success); the bulk time against S12's 0.5 s; what `finishSession()` did. A WARN on "history events only on target cards" or "every other card's note unchanged" can come from a concurrent sync or edit; it lists counts and opaque ids only.

**Record:** both tables under S14 in `docs/spikes.md`. Then check the solo card's note on iCloud.com and on the iPhone.

## S15: CNSaveRequest on cards that have a note (error 134092)

Question: without the `com.apple.developer.contacts.notes` entitlement, which CNSaveRequest operations fail on a card that has a note? Reports (developer forums thread 723695, FB23452026, mattt/iMCP#148) say updates fail with `NSCocoaErrorDomain 134092` "Unhandled error … occurred during faulting". S13 passed only because its scratch cards had no notes; about 1,572 of the 3,781 real cards have one. For each failing operation, can Contacts.app scripting do it instead?

```sh
c2m-spike s15-noted-writes setup               # dry run: plan + containers
c2m-spike s15-noted-writes setup --yes         # creates the cards + group, sets the notes (Apple Events)
#   wait about 15 min: automatic linking of the C pair + Google id churn
c2m-spike s15-noted-writes run                 # dry run (CNContactStore reads only): ids, "C pair linked: YES"?
c2m-spike s15-noted-writes run --yes           # → results/s15-<date>.md
c2m-spike s15-noted-writes run --yes --scripting-all   # optional: scripting for every op, not only failed ones
c2m-spike cleanup --spike s15 --yes            # cards (noted ones via scripting) + "ZZ Spike S15 Group"
```

`setup --yes` creates these cards through `SafeWriter` (CNSaveRequest creates work: a new card has no note yet). Then the production `ScriptingNotesProvider` writes a synthetic three-line note to B, C-iCloud and D (S14 guard first), and reads it back.

| Card | Container | Note | Used for |
|---|---|---|---|
| `ZZ Spike S15 A <id>` | iCloud | none | control for ops 1–5 |
| `ZZ Spike S15 B Noted <id>` | iCloud | yes | ops 1–5 |
| `ZZ Spike S15 C Linked <id>` | iCloud | yes | ops 1–5 on the noted card of a linked pair |
| `ZZ Spike S15 C Linked <id>` | Google | none | ops 1, 2, 3, 5 on the un-noted partner (no group ops: the group is in iCloud) |
| `ZZ Spike S15 D Noted Delete <id>` | iCloud | yes | op 6 delete |
| `ZZ Spike S15 E Delete <id>` | iCloud | none | op 6 delete (control) |

Every card has an email, a phone, job title `S15 baseline` and the marker URL; the C pair shares its name and email so Contacts links it. `ZZ Spike S15 Group` is created in iCloud. State goes to `results/s15-setup.json` and the setup report to `results/s15-setup-<date>.md`.

`run --yes` launches Contacts.app hidden through the provider, checks that B, C-iCloud and D still have their note (and sets it again if not), and that `group id <CNGroup.identifier>` resolves in Contacts.app. Then:

1. **CNSaveRequest phase**, for A, B, C-iCloud and C-Google. Operations: **1** set `familyName` + `jobTitle`; **2** add an email; **3** edit the existing phone in place (`settingValue`, same labeled-value id); **4a/4b** `addMember`/`removeMember` with the scratch group (iCloud cards; the harness puts the card in or out of the group first, using scripting if CNSaveRequest can't); **5** set `urlAddresses` to the existing URLs (marker kept) plus an `x-c2mdsync:<uuid>` stamp. Each operation runs once per variant:
   - **V0** production keys (`AppleContactMapper.cardKeys(includeNote: false)`), shared store
   - **V1** minimal keys: the identity keys plus the operation's field
   - **V2** production keys, `shouldRefetchContacts = false`
   - **V3** production keys, a fresh `CNContactStore` for the fetch and the save
   - **V4** V1 + V2 + V3 together
   - **V5** production keys + `CNContactNoteKey` (does the fetch even work?)
   - **K** the production adapter: `CNContactStoreAdapter.apply` → `CardWriter`, through the S13 harness guard (`HarnessGuardedStore`, spike `s15`)

   Each attempt is recorded as `ok`, `134092` (that code anywhere in the error chain or text), `other` or `fetch failed`. After a failure, the card is fetched again and compared field by field (plus group membership): any difference is reported as `PARTIAL` and as a FAIL row. After a success, the written value is checked (labeled-value id kept for the phone edit and for existing emails, marker URL kept, exactly one stamp, no other field changed). The history events since the attempt are listed per card (`unify=false`), so a write that reaches the linked partner shows up. For noted cards the note hash is compared before and after every attempt (`note CHANGED` is a FAIL).
2. **Labeled-value ids.** For each card, the Contacts.app `id` of every email, phone and url is compared with `CNLabeledValue.identifier` (INFO when they differ; one sample of each is printed).
3. **Scripting phase.** For every card and operation where V0 did not succeed (every one with `--scripting-all`): `set last name`/`set job title of person id X`; `make new email at end of emails of person id X with properties {label:"work", value:…}`; `set value of phone id Y of person id X` (by index if scripting phone ids aren't the CN ids); `add person id X to group id G` / `remove person id X from group id G`; delete old stamp urls and `make new url …`; each followed by `save`. Verified the same way on CNContactStore (polling up to 8 s for Contacts.app's save to land), plus a re-read through scripting.
4. **Delete phase.** E, then D: V0, V1, … K until one deletes the card, else `delete person id X` + `save`.
5. **Final checks.** Notes on B and C-iCloud still exact, C pair still linked, no card added or removed except D and E, change history of the whole run only on S15 cards.

The results file holds a matrix (card × operation × path), the checks, every attempt (error domain/code chain, partial changes, verify detail, history) and the log. Only harness data appears in it. The exit code is 1 if any row FAILs.

**Observe:** which cells say `134092` for B and C-iCloud while A says `ok`; whether a failed save left a `PARTIAL` change; whether any of V1–V5 avoids the error (and whether K, the production path, fails); whether C-Google (no note, linked to a noted card) fails; whether a successful CN save on a noted card left its note intact; for scripting: does each op work, keep the phone's labeled-value id, keep the card id, and touch only the target card in history; do scripting ids equal `CNLabeledValue.identifier`.

**Record:** the matrix and the decision under S15 in `docs/spikes.md`: which write operations the app must route through Contacts.app scripting (or refuse) for noted cards when the entitlement is missing.

## S16: the production write routing (`CardWriteRouter` → `ScriptingCardWriter`) on scratch cards

Question: does the write routing the app now ships (architecture §6 "Write routing", built from the S15 findings) work against the real Contacts store and Contacts.app? In particular the raw-event forms S15 did not try (`make new … at end of …`, `delete … id …`, `add`/`remove … group`), what a raw `_$!<Work>!$_` / `_$!<Mobile>!$_` label is stored as, and whether element ids of addresses, related names, social profiles and IMs equal `CNLabeledValue.identifier` (in-place edits keep them). iCloud only; no Google account needed.

```sh
c2m-spike s16-scripted-writes setup            # dry run: plan + container
c2m-spike s16-scripted-writes setup --yes      # creates A, B + group; sets B's note (Apple Events)
c2m-spike s16-scripted-writes run              # dry run (CNContactStore reads only): ids, group, plan
c2m-spike s16-scripted-writes run --yes        # → results/s16-<date>.md
c2m-spike cleanup --spike s16 --yes            # cards (B via scripting) + "ZZ Spike S16 Group"
```

`setup --yes` creates two iCloud cards through `SafeWriter`, then the production `ScriptingNotesProvider` writes a synthetic three-line note to B (S14 guard first) and reads it back.

| Card | Note | Fields | Used for |
|---|---|---|---|
| `ZZ Spike S16 B Noted <id>` | yes | job title, 2 emails (work, home), 2 phones (home, work), marker + 2 URLs (homepage `…/keep`, other `…/delete`), home address, friend related name, Twitter profile, Skype IM | steps 1–5, 7, 9 (scripting route) |
| `ZZ Spike S16 A <id>` | none | the same | step 6 (framework route, control) |

`ZZ Spike S16 Group` is created in iCloud. State goes to `results/s16-setup.json`, the setup report to `results/s16-setup-<date>.md`.

`run --yes` builds the production stack: one `ContactsAppSession(quitWhenDone: false)` shared by `ScriptingNotesProvider` and `ScriptingCardWriter`, and `CardWriteRouter(inner: CNContactStoreAdapter(), scripting: writer)`. For every batch the harness reads each target's note through the provider to fill `AppleWriteBatch.cardNotes` (as the engine does), runs both guards, then calls `router.apply` off the main thread (as the app does). After each batch it re-reads the cards through a fresh `CNContactStore`, checks B's note hash, and records the change-history events of the batch window.

1. **B update + stamp** (one batch, one card, via scripting): `familyName` + `jobTitle`, the first phone edited in place, a new email with label `work` (the writer sends the raw `_$!<Work>!$_`), the `…/delete` URL dropped (marker and `…/keep` kept), plus a `stamp` operation. Checks: values, labeled-value ids kept for the edited phone, the untouched phone, existing emails and kept URLs; exactly one stamp; no other field changed; `AppleWriteResult.scripted` holds both operations.
2. **Labels.** The CN label of the step-1 email (expected `CNLabelWork`). Then relabel phone 1 to `mobile` (raw `_$!<Mobile>!$_` sent; expected `CNLabelPhoneNumberMobile`) and phone 2 to custom `summer` (sent as `Summer`); ids and values kept.
3. **Group, B.** `addMember` then `removeMember` through the router (both scripted); membership polled on CNContactStore (up to 8 s): true, then false.
4. **Structured in-place edits, B.** Address street + city, related name, Twitter username, Skype username in one batch. Checks: the address, related name and social values changed under the same labeled-value id (social URL printed), and those three edits are reported applied (operation in `applied`, none of them in `skipped`, nothing failed). The IM: Contacts.app resolves `instant message id E` but refuses every change to it (`-1719`, 2026-10-24T1802 run), so the writer skips the IM edit up front with "instant messages can't be changed through Contacts.app (needs the notes entitlement)" and sends no IM Apple Event (INFO row "IM commands sent: n"). PASS when the IM is skipped with that reason, the IM is unchanged, no IM command was sent and the card is applied. FAIL if the router reports a failure, if anything other than the IM is skipped, or if any IM of B changes. **4b** sends the IM edit alone: same IM checks, and nothing at all is sent for the card.
5. **Clear and unlabeled, B.** `jobTitle` set to `""` (CN must show it empty) and a new email with no label (INFO: which CN label it got).
6. **A (no note).** The step-1 update + stamp: routed through the Contacts framework (not in `scripted`, no 134092 retry), same value/id checks. Then `addMember` (framework) and `removeMember` (always scripting) with membership verified.
7. **Not scriptable, B.** An image, then a month-day birthday: each reported in `AppleWriteResult.skipped` with "needs entitlement or not scriptable", routed to scripting, and nothing changes on the card.
8. **History and side effects.** Per batch and target: exactly one `UpdateContactEvent` for field batches (WARN if more), at most one for group batches, none for step 7; events on non-harness cards are counted (WARN, ids never printed); no card added or removed; neither card left in the group. Because the session has `quitWhenDone: false`, `finishSession()` never quits Contacts.app: the harness quits it itself if the run launched it and it is still hidden, so Contacts.app is left as found.
9. **Notes.** B's note still byte-exact (SHA-256 printed), A still has none.

The results file holds the checks, a per-batch history table and the log (cardNotes, applied/scripted/failed/held/skipped counts and the router's route log per batch). Only harness data appears in it. The exit code is 1 if any row FAILs. `run` is meant for one pass per setup: step 1 deletes the `…/delete` URL, so on a second run that check is SKIP. For a full re-run, `cleanup --spike s16 --yes` and `setup --yes` again.

**Record:** under S16 in `docs/spikes.md`: whether every row passes, the stored labels (steps 2 and 5), whether structured element ids survive (step 4), and any WARN in step 8.

## Cleanup

```sh
c2m-spike cleanup                 # dry run: lists harness cards, plus any half-marked cards it will NOT touch
c2m-spike cleanup --yes           # delete all harness cards
c2m-spike cleanup --spike s5 --yes
c2m-spike cleanup --spike s12 --yes   # S12 scratch cards (single card and linked pair)
c2m-spike cleanup --spike s13 --yes   # S13 cards, plus "ZZ Spike S13 Group" if all its members are harness cards
c2m-spike cleanup --spike s14 --yes   # S14 cards (solo card and linked pair)
c2m-spike cleanup --spike s15 --yes   # S15 cards (noted ones via Contacts.app scripting) + "ZZ Spike S15 Group"
c2m-spike cleanup --spike s16 --yes   # S16 cards (B via Contacts.app scripting) + "ZZ Spike S16 Group"
```

Cards that match only one marker are listed for manual deletion and never deleted by the tool. After cleanup, delete any leftovers on contacts.google.com and iCloud.com by hand, and unload the S11 LaunchAgent and cron line.
