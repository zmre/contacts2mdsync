# c2m-spike: the spike harness

`c2m-spike` is a standalone command-line tool for the spikes in [`docs/spikes.md`](../docs/spikes.md) that need a real address book: S1, S3, S4, S5, S9 and S11. It also gives partial evidence for S2 (the notes-key probe in `inventory`). It doesn't depend on `Contacts2MdSyncKit`.

## Safety model

- **Writes only touch scratch cards.** A card counts as a harness card only if both of these hold: its name (`givenName familyName`) starts with `ZZ Spike `, and one of its URL values starts with `x-mdsync-spike:`. That URL carries the label `mdsync-spike` and has the form `x-mdsync-spike:<spike>:<account>:<uuid>`. The harness never uses the notes field.
- **Checks happen right before every write.** All writes go through `SafeWriter` (`Sources/c2m-spike/Support/Harness.swift`). It fetches the target card again by identifier with unified results off, refuses to continue unless the card passes both checks, and checks again after the mutation. A save to a unified contact (S4 `--unified-write`) requires every underlying card to pass.
- **Writes are dry runs until you add `--yes`.** Every write subcommand prints its plan. Without `--yes`, nothing is written.
- **`cleanup` needs both markers.** It deletes only cards that pass both checks. If a card matches only one, `cleanup` lists it and you delete it by hand. This can happen when Google strips the marker URL during S1 or S5.
- **Read-only output contains no PII.** `inventory` and `s9-ids` print counts and opaque identifiers only. Container names that contain `@` are redacted. S9 files store SHA-256 hashes of identifiers.

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

Each card gets two URLs: the marker, and the stamp under test (label `mdsync`, value `x-mdsync:<uuid>`).

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
- URLs without a scheme, in uppercase, with query and fragment, and the `x-mdsync:` stamp
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

## Cleanup

```sh
c2m-spike cleanup                 # dry run: lists harness cards, plus any half-marked cards it will NOT touch
c2m-spike cleanup --yes           # delete all harness cards
c2m-spike cleanup --spike s5 --yes
```

Cards that match only one marker are listed for manual deletion and never deleted by the tool. After cleanup, delete any leftovers on contacts.google.com and iCloud.com by hand, and unload the S11 LaunchAgent and cron line.
