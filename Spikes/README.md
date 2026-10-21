# c2m-spike: the spike harness

`c2m-spike` is a command-line tool for the spikes in [`docs/spikes.md`](../docs/spikes.md) that need a real address book: S1, S3, S4, S5, S9, S11, S12 and S13. It also gives partial evidence for S2 (the notes-key probe in `inventory`). S1–S12 use Contacts.framework directly. S13 links `ContactModel` and `ContactsAdapter` from `Packages/Contacts2MdSyncKit` (a path dependency) so it can run the app's real write path; the harness never modifies the kit.

## Safety model

- **Writes only touch scratch cards.** A card counts as a harness card only if both of these hold: its name (`givenName familyName`) starts with `ZZ Spike `, and one of its URL values starts with `x-c2mdsync-spike:`. That URL carries the label `c2mdsync-spike` and has the form `x-c2mdsync-spike:<spike>:<account>:<uuid>`. Scratch cards created before the rename carry the legacy marker `x-mdsync-spike:` (label `mdsync-spike`); the harness still recognizes those for checks and cleanup (the name prefix is still required), but never creates new ones. The harness never reads or writes the notes field through Contacts.framework. The one exception is S12: it uses Apple Events to Contacts.app to write a synthetic note, and only to a scratch card.
- **S12 writes go through Contacts.app, so they are checked on both sides.** Right before `set note`, `s12-notes write` verifies every underlying card behind the target with `SafeWriter.verifiedCard`. It also asks Contacts.app for the target person's `id`, first and last name, and `url` values, and refuses unless they show the `ZZ Spike ` prefix and one of the expected marker URLs. The handler arguments are passed as Apple Event descriptors, never pasted into script source.
- **Checks happen right before every write.** All writes go through `SafeWriter` (`Sources/c2m-spike/Support/Harness.swift`). It fetches the target card again by identifier with unified results off, refuses to continue unless the card passes both checks, and checks again after the mutation. A save to a unified contact (S4 `--unified-write`) requires every underlying card to pass.
- **S13 runs the app's real write path behind a harness guard.** `s13-writes` calls `CNContactStoreAdapter.apply` (which uses `CardWriter`) only through `HarnessGuardedStore` (`Sources/c2m-spike/Support/KitGuard.swift`). Before each batch, the guard fetches every target card again by id with unified results off. Every card must pass both checks and carry the `s13` spike tag, or the guard refuses the whole batch and nothing is saved. The guard also refuses a URL-list edit that would drop the marker, a name edit that would drop the `ZZ Spike ` prefix, note and image edits, a create without the prefix and an `s13` marker, and group operations on any group other than `ZZ Spike S13 Group`. After the save it checks the cards again. The wrapper exposes only `apply`, so the harness can't reach any other write entry point.
- **Writes are dry runs until you add `--yes`.** Every write subcommand prints its plan. Without `--yes`, nothing is written.
- **`cleanup` needs both markers.** It deletes only cards that pass both checks. It deletes the S13 scratch group only if the group's name is exactly `ZZ Spike S13 Group` and it is empty or holds only harness cards; this is checked again right before the delete. If a card matches only one, `cleanup` lists it and you delete it by hand. This can happen when Google strips the marker URL during S1 or S5.
- **Read-only output contains no PII.** `inventory`, `s9-ids` and `s12-notes probe` print counts, timings and opaque identifiers only. `s12-notes probe` reads every note but never prints note text or names. Container names that contain `@` are redacted. S9 files store SHA-256 hashes of identifiers.

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

## Cleanup

```sh
c2m-spike cleanup                 # dry run: lists harness cards, plus any half-marked cards it will NOT touch
c2m-spike cleanup --yes           # delete all harness cards
c2m-spike cleanup --spike s5 --yes
c2m-spike cleanup --spike s12 --yes   # S12 scratch cards (single card and linked pair)
c2m-spike cleanup --spike s13 --yes   # S13 cards, plus "ZZ Spike S13 Group" if all its members are harness cards
```

Cards that match only one marker are listed for manual deletion and never deleted by the tool. After cleanup, delete any leftovers on contacts.google.com and iCloud.com by hand, and unload the S11 LaunchAgent and cron line.
