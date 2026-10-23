# Contacts2MdSync — UI Design

Status: review UI on the two-way engine, with M5 live sync hosted in the app (toolbar, Settings ▸ General, menu bar; see §14 for what is live, what is still pending, and deviations). ASCII mockups; final visuals follow macOS HIG with native SwiftUI components.

## Principles

- **Nothing destructive happens on its own.** Creates and edits sync automatically; deletes, conflicts, ambiguous matches, and duplicates wait in Review. The first sync shows a preview before writing anything.
- **Calm.** System fonts, semantic colors, one accent. Color dots carry meaning only: orange = needs you, red = error, gray = idle. No charts. Counts right-aligned with `.monospacedDigit()`.
- **Every count is a link** to the filtered list behind it.
- **Native parts:** `NavigationSplitView`, `Table`, `Form(.grouped)`, `.inspector`, `ContentUnavailableView`, `Settings`, `MenuBarExtra(.window)`, `.searchable`.

## 1. Information architecture

```
SIDEBAR                         (badges = pending items)
  Overview
  ─ Review ─────────────────
  Conflicts                 3
  Markdown Only            12
  Deletions                 2
  Duplicates                7
  ─ Library ────────────────
  All Contacts          1,248   (Apple card ↔ .md path for every record)
  ─ History ────────────────
  Activity
```

- **Toolbar (all screens):** `[⟳ Sync Now]` (⌘R), status/lease indicator, `Live` toggle, inspector toggle.
- **Inspector (⌘⌥I):** Apple card summary, file path, sync id, accounts backing the card; buttons **Open in Contacts** and **Reveal in Finder**.

## 2. Onboarding (separate window, ~640×520, 5 steps)

```
Step 1 — Access
┌──────────────────────────────────────────────────────────────┐
│                ● ○ ○ ○ ○                                     │
│            [person.crop.circle ↔ doc.text]                   │
│          Keep Contacts and your notes in sync                │
│   Contacts2MdSync mirrors Apple Contacts to markdown files   │
│   in your notes folder and brings edits back. Nothing is     │
│   written until you review a preview.                        │
│                                                              │
│   Contacts access          ✓ Granted   /  [Allow Access…]    │
│   Notes field access       ◦ Unavailable  ⓘ                  │
│                                        [Quit]  [Continue]    │
└──────────────────────────────────────────────────────────────┘
```
Denied → "Contacts access is off. **Open System Settings**". Continue disabled until granted.

```
Step 2 — Folders
┌──────────────────────────────────────────────────────────────┐
│  Where should contact files live?                            │
│                                                              │
│  Notes root          ~/Notes/Contacts            [Choose…]   │
│                      Existing files are scanned and matched; │
│                      they are never moved.                   │
│  New contacts go in  [ Inbox ▾ ]   → ~/Notes/Contacts/Inbox  │
│                                                              │
│  Found 214 markdown files · 188 look like people/orgs        │
│                                        [Back]  [Continue]    │
└──────────────────────────────────────────────────────────────┘
```

```
Step 3 — Preview (read-only scan)
┌──────────────────────────────────────────────────────────────┐
│  Here's what the first sync will do                          │
│                                                              │
│  Apple Contacts                                              │
│    Contacts read                     1,248                   │
│    Accounts                 iCloud 1,031 · Google 217        │
│    Groups → tags                        18   [Show…]         │
│                                                              │
│  Matching                                                    │
│    Matched to existing files           173                   │
│    New files to create               1,061                   │
│    Files with no Apple contact          15   (review later)  │
│    Possible duplicates                   7   ● needs review  │
│                                                              │
│  Writes to Apple Contacts: sync stamp only (1,234 cards)     │
│                                        [Back]  [Continue]    │
└──────────────────────────────────────────────────────────────┘
```

```
Step 4 — Review duplicates (embeds §7; skippable)
  "7 people appear more than once. Decide now, or skip — each group
   will produce one file until you decide."
                                   [Skip for Now]  [Continue]

Step 5 — Confirm
  ✓ 1,061 files will be created in Inbox/
  ✓ 173 existing files will gain a sync id
  ✓ 18 tags
  ✓ A backup of all contacts is saved first
  ○ Live sync         [ on ]
  ○ Show in menu bar  [ on ]
                                   [Back]  [Run First Sync]
```

## 3. Overview

```
┌───────────────┬──────────────────────────────────────────────────────────────┐
│ ● ● ●         │  Overview          [◉ Live]  [⟳ Sync Now]  ◦ Idle      [⧉]   │
│               ├──────────────────────────────────────────────────────────────┤
│ ▸ Overview    │   ✓ In sync                                                  │
│ REVIEW        │   Last synced 10:42 AM on Patrick's MacBook Pro · 4 s        │
│   Conflicts 3 │                                                              │
│   Md Only  12 │  ┌ Needs Review ───────────────────────────────────────────┐ │
│   Deletions 2 │  │ ● Conflicts                                 3        ›  │ │
│   Duplicates 7│  │ ● In markdown only                         12        ›  │ │
│ LIBRARY       │  │ ● Pending deletions                         2        ›  │ │
│   All   1,248 │  │ ● Possible duplicates                       7        ›  │ │
│ HISTORY       │  └─────────────────────────────────────────────────────────┘ │
│   Activity    │  ┌ Since Last Sync ────────────────────────────────────────┐ │
│               │  │ Changed in Contacts                         5           │ │
│               │  │ Changed in Markdown                         2           │ │
│               │  └─────────────────────────────────────────────────────────┘ │
│               │  ┌ This Session ───────────────────────────────────────────┐ │
│               │  │                    Created  Updated  Deleted            │ │
│               │  │ Apple Contacts           0        2        0            │ │
│               │  │ Markdown files           1        5        1            │ │
│               │  └─────────────────────────────────────────────────────────┘ │
│               │  ┌ Totals ─────────────────────────────────────────────────┐ │
│               │  │ Synced contacts                         1,234           │ │
│               │  │ Notes root          ~/Notes/Contacts    [Reveal]        │ │
│               │  └─────────────────────────────────────────────────────────┘ │
└───────────────┴──────────────────────────────────────────────────────────────┘
```

- "Needs Review" appears only when something is pending; otherwise the header reads "✓ In sync. Nothing needs your attention."
- "Since Last Sync" is computed continuously from a dry-run, so it shows what the next sync will do.
- Contact notes (§9 Advanced): when notes are synced, the live run summary line mentions how many bodies went each way (`notes →contacts 2 →md 1`, or `notes skipped`). When the latest check skipped notes, a warning banner says "Contact notes were skipped: this Mac does not allow Contacts2MdSync to control Contacts. Allow it in Settings ▸ Advanced ▸ Contact notes." (or "Contact notes were skipped this time: <reason>." for a failed read) with [Open Settings…].
- **Unavailable accounts** (architecture §9): when a Contacts account this Mac saw is not visible in Contacts (its Contacts turned off in System Settings, removed, or in a partial state), a banner below the status line says so and that nothing in the notes changes meanwhile:

```
│  ⍰ Google account isn't visible in Contacts — 1,353 cards kept as last seen │
│    Last seen Today 9:12 AM. Nothing in your notes changes while it is away. │
│    Turn its Contacts back on in System Settings ▸ Internet Accounts.        │
│                              [Keep Waiting]  [Forget This Account…]         │
```

  **Keep Waiting** records `wait` (the default; the banner stays while the account is away). **Forget This Account…** opens a confirmation sheet first: the account's label, how many contacts exist only in it (they move to Pending Deletions, each note kept until confirmed; five names as examples), and how many notes lose values only its cards held, listed with the values (first 50). **Forget Account** (destructive) records `forget`; the banner then says "Forget chosen: the next sync removes it." Both buttons wait for a check to have run (the preview comes from it). An iCloud account says "check System Settings ▸ Apple Account ▸ iCloud ▸ Contacts". When the account is back, the banner reads "Google account is back — N cards still being matched" (no buttons) until every card is matched; nothing is created twice meanwhile. The banner never counts as "needs review".
- During sync: toolbar shows `ProgressView` + "Syncing… 312 of 1,248" and a Stop button.
- Another device holds the lease:

```
│  ⏸ Waiting for Patrick's iPad                                          │
│    It started syncing at 10:44 AM. This Mac will sync when it finishes │
│    (expires 11:04 AM).                    [Details…]  [Take Over…]     │
```

## 4. Conflicts

```
┌────────────┬──────────────────────┬─────────────────────────────────────────────────┐
│ Conflicts 3│ 🔍 Search            │  Jane Doe              Work/Jane Doe.md     [i] │
│            ├──────────────────────┤  Changed on both sides since Oct 18, 9:02 AM    │
│            │▸ Jane Doe            │                                                 │
│            │  2 fields · Work/    │  FIELD    PREVIOUS      CONTACTS     MARKDOWN   │
│            │  Acme Corp           │ ─────────────────────────────────────────────── │
│            │  1 field · Orgs/     │  Job      Engineer      Sr Engineer  Staff Eng  │
│            │  Sam Lee             │           [ Keep Contacts | Keep Markdown ]     │
│            │  1 field · Family/   │ ─────────────────────────────────────────────── │
│            │                      │  Phone    +1 555 0100   +1 555 0199  +1 555 0142│
│            │                      │  (mobile)                                       │
│            │                      │     [ Keep Contacts | Keep Markdown | Keep Both ]│
│            │                      │ ─────────────────────────────────────────────── │
│            │                      │  Unchanged fields hidden.  [Show All Fields]    │
│            │                      │                 [Skip]   [Apply to Jane Doe]    │
└────────────┴──────────────────────┴─────────────────────────────────────────────────┘
 Toolbar: [Resolve Selected ▾  Prefer Contacts · Prefer Markdown · Keep Both Where Possible]
```

- PREVIOUS column in secondary text; character-level diff highlights for scalars, set diff for multi-value.
- "Keep Both" only for multi-value fields and the notes body.
- Notes body conflicts ("Notes") show the first line of each side plus a [Compare…] button. It opens a scrollable line diff of the markdown body against the Contacts note: lines only in markdown marked −, lines only in Contacts marked +, shared lines plain. Keep Contacts / Keep Markdown / Keep Both work as for other fields; Keep Both writes the markdown text, a `---` line, then the Contacts text, to both sides.
- Batch: multi-select in the middle list → Resolve Selected → confirmation ("Apply 'Prefer Markdown' to 3 contacts (4 fields)?").
- Keys: ↑↓ contacts, ⌘1/⌘2/⌘3 choose, ⌘↩ apply.

## 5. Markdown Only

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ Markdown Only — 12 files have no Apple contact               [Apply 3 Changes]       │
├───┬────────────────────┬────────┬──────────────┬────────────────────┬────────────────┤
│ ☑ │ Name               │ Kind   │ Folder       │ Possible match     │ Action         │
├───┼────────────────────┼────────┼──────────────┼────────────────────┼────────────────┤
│ ☑ │ Maria Gonzalez     │ Person │ Inbox/       │ —                  │ [Add      ▾]   │
│ ☐ │ Bob Smith          │ Person │ Work/        │ Robert Smith  0.9  │ [Link     ▾]   │
│ ☑ │ Initech            │ Org    │ Orgs/        │ —                  │ [Add      ▾]   │
│ ☐ │ Dr. K. Patel       │ Person │ Family/      │ Kiran Patel   0.7  │ [Link     ▾]   │
│ ☐ │ Old Landlord       │ Person │ Archive/     │ —                  │ [Ignore   ▾]   │
└───┴────────────────────┴────────┴──────────────┴────────────────────┴────────────────┘
  Action menu: Add to Contacts · Link to "Robert Smith" · Link to Other… · Ignore
  Inspector: frontmatter preview + match reasons ("same email bob@acme.com")
```

- Rows with a match default to **Link**, unchecked. "Add" is never the default when a match ≥ 0.5 exists.
- Ignored files are remembered (decision log). Toolbar filter: Show Ignored.

## 6. Deletions

```
[ Deleted in Contacts (1) | Deleted in Markdown (1) ]

Deleted in Contacts
│ Name         │ File                     │ Noticed       │ Action                 │
│ Tom Becker   │ Work/Tom Becker.md       │ Oct 19, 4:10P │ [Keep File, Unlink ▾]  │
   options: Keep File, Unlink · Delete File (moves to Trash) · Restore Contact

Deleted in Markdown
│ Name         │ Was at                   │ Noticed       │ Action                 │
│ Lisa Wu      │ Family/Lisa Wu.md        │ Oct 20, 8:55A │ [Restore File ▾]       │
   options: Restore File · Unlink, Keep Contact · Delete Apple Contact…

                                                       [Apply 2 Changes]
```

- Defaults are always non-destructive.
- "Delete File" moves to Trash. "Delete Apple Contact…" shows a destructive alert listing exactly which cards (default: iCloud card only): "Delete Lisa Wu from iCloud Contacts? A backup was saved at 8:55 AM."

## 7. Duplicates

```
2 possible duplicates │ John Doe — 2 contacts, 1 file
                      │ Why: same email · same name
▸ John Doe       2+1  │
  iCloud+Google+md    │ 2 selected [Same Person] [Different People] [Don't Sync]
  Jane Doe       2    │
  iCloud+Google       │ ┌ ◉ 1 John Doe   Person A ┐ ┌ ◉ 2 John Doe   Person A ┐
                      │ │ iCloud                  │ │ Google                  │
                      │ │ john@doe.example        │ │ john@doe.example        │
                      │ │ +1 303 555 0111         │ │ +1 303 555 0100 (home)  │
                      │ │ +1 303 555 0100 (home)  │ │                         │
                      │ │ Note: Inbox/John Doe.md │ │                         │
                      │ │ With 2 · Google: same   │ │ With 1 · iCloud: same   │
                      │ │ name · same email …     │ │ name · same email …     │
                      │ └─────────────────────────┘ └─────────────────────────┘
                      │ (Person A: 2 cards)  [Link Person A in Contacts…]
                      │ [Apply] [Undo] [Reset]   [Not Duplicates] [Ignore for Now]
```

- A cluster joins cards with equal names, or a shared email and compatible names (architecture §6). Shared phones never join cards; home, main and work numbers are shown de-emphasized on the cards because a household shares them.
- Each card is one Apple contact: a checkbox and selection ring, its number, the person badge it is assigned to, account badges (iCloud, Google, both with a *Linked* mark when Contacts already links them), emails and personal numbers, household numbers in tertiary text, the note it syncs to (if any), and why it is in the cluster: one line per direct link (`With 2 · Google: same email … · names match (Jane / Jane)`).
- Click or Space toggles a card; ⌘A selects all. Actions on the selection: **Same Person** (the selected cards become one person: one note), **Different People** (each selected card becomes its own person), **Don't Sync** (left out of sync; nothing is deleted).
- The resulting partition shows live as colored chips: `Person A: 2 cards · Person B: 1 card · Not synced: 1 · Undecided: 1`. A person with several cards offers **Link Person A in Contacts…** (Apple has no public API to link cards; the user selects them and chooses Card ▸ Link Selected Cards; we rescan on return). **Undo** (⌘Z) and **Reset** revert edits.
- **Apply** (⌘↩) is enabled once every card is assigned; it confirms who syncs to which note and who is left out, then records one `cluster-resolve` decision.
- **Not Duplicates** (every card a different person) is remembered forever; **Ignore for Now** snoozes until the next sync.
- When a resolved cluster gains a member, it comes back with the earlier answer prefilled and the new card undecided ("You answered for some of these before"). Earlier Not Duplicates and Sync Only answers show the same way.
- Two files with the same sync id: Keep This One · Give the Other a New ID · Delete Other File…
- Two stamped files now pointing at one linked contact: Pick Surviving File · (other file → Trash on confirm).

## 8. Activity

```
│ Time            │ Device       │ Trigger │ Contacts C/U/D │ Markdown C/U/D │ Notes                  │ Review │ Result │
│ Today 10:42 AM  │ MacBook Pro  │ Live    │     0/2/0      │     1/5/1      │ 2 → Contacts · 1 → notes│   3    │  ✓     │
│ Today  8:01 AM  │ iPad         │ Manual  │     0/0/0      │     0/1/0      │ —                      │   —    │  ✓     │
│ Yesterday 6:12P │ MacBook Pro  │ Live    │       —        │       —        │ skipped                │   —    │  ⚠ 1   │
│ Yesterday 3:00A │ MacBook Pro  │ CLI     │     0/0/0      │     2/0/0      │ 0 → Contacts · 2 → notes│   2    │  ⚠ 2   │
```

- Inspector lists each change ("Updated Jane Doe.md — job, phone") with Reveal / Open.
- Trigger is Manual, Live, Launch, Wake, Sweep or CLI. Items a CLI run skipped show up in Review badges like any others.
- Notes: bodies written into Contacts notes and into markdown notes that run; `skipped` (tooltip: why, e.g. "Automation permission for Contacts not granted") when notes are on but were not read; `—` when notes are off or for runs from before notes.
- Warnings expand inline ("34 files not downloaded from iCloud Drive; skipped").
- A run during which a Contacts account was not visible shows an orange account icon next to its result, with the banner text as tooltip ("Google account isn't visible in Contacts — 1,353 cards kept as last seen (nothing removed from your notes)"). Changes held because they would touch that account's cards count in Held.
- File ▸ Export Log…

## 9. Settings

```
[General] [Folders] [Accounts] [Scope] [Advanced]

General   Device name        [Patrick's MacBook Pro      ]
          Background sync    [ ] Sync every [1 hour ▾] even when the app is closed
                             (or run `contacts2md sync` from launchd/cron)
          Live sync          [◉] Watch Contacts and folder for changes
          Safety check       [Every 2 hours ▾]  full compare in case a change was missed
          Menu bar           [◉] Show in menu bar
          Launch at login    [ ]

Folders   Notes root         ~/Notes/Contacts                 [Choose…]
          New contacts in    [Inbox ▾]
          Photos in          [_images ▾]
          File names         [Full Name ▾]   e.g. "Jane Doe.md"

Accounts  Write to           iCloud   (fixed in v1)
          Read from          ☑ iCloud (1,031)  ☑ Google (217)
          Groups ↔ tags      18 managed tags  [Edit…]

Scope     (Planned — shown disabled)
          Include   ○ All contacts  ○ Only these groups…
          Exclude   Groups: [ + ]   Contacts: [ + ]

Advanced  Contact notes
            Source           ● Contacts.app scripting      (Entitlement / Contacts.app scripting / Off)
            [◉] Sync notes through Contacts.app            (hidden when the entitlement is present)
            Automation permission  Granted  [Check Again]  (Not asked yet [Ask Again] / Denied [Open Privacy
                                                            Settings…] / Not known until Contacts.app runs [Ask Again])
            [◉] Quit Contacts.app after syncing when it was opened for the sync
            (footer) Without Apple's notes entitlement, Contacts2MdSync can sync note bodies by
            controlling Contacts.app: during a sync it opens Contacts.app hidden, reads every card's
            note in one go, writes changed notes card by card, and quits it again. Scheduled and
            command-line syncs never ask; without permission they skip notes.
          Sync lease         Held by: none · [Take Over…]
          Backups            10 kept · [Show in Finder]
          [Rescan Everything…]  [Reset Sync State…]
```

**Turning on contact notes.** The toggle opens a sheet first: Contacts2MdSync will control Contacts.app to read and write the Notes field of each card; macOS asks once ("Contacts2MdSync wants to control Contacts"); during a sync Contacts.app is opened hidden and quit afterwards if the sync opened it and you are not using it; the first sync with notes merges every body without a base, and you see what it will do before it runs. [Cancel] [Continue]. Continue saves `notes_sync: on` and triggers the macOS prompt (the only place the app asks; syncs never prompt). Then:

- **Granted**: an enablement summary from the next check: "12 notes go into markdown, 3 markdown bodies go into Contacts (largest 4,812 characters), 140 already match, 2 conflicts to resolve", with a scrollable list of the markdown bodies going into Contacts (title, path, size). If Apple writes are off, it says the bodies wait until they are on. [Later] [Sync Now].
- **Denied**: "Allow it in System Settings ▸ Privacy & Security ▸ Automation ▸ Contacts2MdSync ▸ Contacts, then sync again." [Open Privacy Settings…]. The setting stays on; syncs skip notes with a warning until it is allowed.

Turning it off saves at once. The next sync with notes starts without a base again.

## 10. Menu bar extra

```
 person.2.circle  (orange dot when review pending)
┌──────────────────────────────────┐
│ ✓ In sync · 10:42 AM             │
│ Live sync on                     │
├──────────────────────────────────┤
│ ⍰ Google account isn't visible   │
│   in Contacts — 1,353 cards kept │
├──────────────────────────────────┤
│ Needs review                  24 │
│   Conflicts 3 · Md only 12       │
│   Deletions 2 · Duplicates 7     │
├──────────────────────────────────┤
│ [Sync Now]         [Open App…]   │
│ Pause Live Sync ▸ 1 hr · Day     │
└──────────────────────────────────┘
```

## 11. iPad and iPhone (M7)

- **iPad:** same split view; inspector becomes trailing column or sheet; Settings becomes a sidebar item.
- **iPhone:** stack navigation; Overview as first row/card; tables → two-line Lists with swipe actions; conflicts as per-field cards; duplicates as paged cards.
- **No folder watching on iOS:** sync on launch, foreground, `CNContactStoreDidChange`, and `BGAppRefreshTask`. "Live" becomes "Sync in background when possible".
- **Menu bar → widget + Control Center "Sync Now".**

## 12. Empty, loading, error states

| Situation                       | Treatment                                                                                   |
|---------------------------------|---------------------------------------------------------------------------------------------|
| Review list empty               | `ContentUnavailableView("No Conflicts", systemImage: "checkmark.circle")`, same for others  |
| First scan                      | centered progress + phase: "Reading Contacts… / Scanning 214 files… / Matching…"            |
| Sync running                    | inline toolbar progress; lists stay usable                                                  |
| No Contacts access              | full-pane unavailable view with "Open System Settings"                                     |
| Folder missing / bookmark stale | inline banner "Can't open ~/Notes/Contacts. It may have moved." [Locate…]                  |
| iCloud files not downloaded     | banner "34 files are still in iCloud." [Download]                                           |
| Malformed frontmatter           | listed in Activity with ⚠, never written; [Reveal in Finder]                                |
| Lease stale                     | "Patrick's iPad last synced 2 h ago." [Take Over Sync]                                      |
| Circuit breaker tripped         | red banner "Sync paused: 214 contacts disappeared from Contacts. Is iCloud signed in?" [Review] [Resume Anyway] |

## 13. Wording

- **Use:** Sync Now, Live Sync, In sync, Needs Review, Changed in Contacts / Changed in Markdown, Keep Contacts / Keep Markdown / Keep Both, Markdown Only, Link to Existing Contact, Add to Contacts, Delete File, Restore File, Delete Apple Contact…, Open in Contacts to Link, Not Duplicates, Waiting for *device*.
- **Avoid in main UI:** local/remote, source/target, orphan, tombstone, lease (Advanced only).
- Counts: number + plain noun ("12 files"). Relative dates ("Today 10:42 AM").

## 14. As built (M4 UI, M5 live sync, M6 lease)

**Structure.** One main `Window` (id `main`). `ContentView` shows onboarding (`SetupView`, steps 1–5) until the folder is configured, a "Can't open the notes folder [Locate…]" pane when the saved bookmark no longer resolves, and otherwise `MainView`: the §1 sidebar with badges, toolbar (status dot + text, `Live` toggle, **Sync Now**, inspector toggle), banners above every screen, and `.inspector`. Menu commands: Contacts ▸ Sync Now (⌘R), Check for Changes (⇧⌘R); View ▸ Show/Hide Inspector (⌥⌘I). The `MenuBarExtra` (§10) is a second scene. `AppDelegate` owns the `AppModel` (so it outlives the window), starts it at launch, and stops live sync before quitting.

**Layers.**

- `Contacts2MdCLI/UI*.swift`: view-model adapters over the public engine APIs, tested in `UIReviewTests`, `UISyncTests` and `UISyncOutcomeTests`. `UIVaultReader` (`UIVaultReader.swift`) reads stored state and scans the folder (no Contacts access), runs dry runs and Sync Now through the same `VaultSession` calls as `contacts2md plan` / `sync`, appends decisions, and edits `default_folder`, `apple_writes` and `stamp_contacts`. `UIReviewQueues` turns stored state into screen data: `UIConflictRecord` (`UIConflicts.swift`), `UIDeletionRow` (`UIDeletions.swift`), `UIDuplicateGroup`, `UIMarkdownOnlyRow`. `UISync.swift` has the Sync Now request/outcome/summary, the two-way part of a dry run (`UISyncPlanSummary`) and `UIBanner`. `UIOverview`, `UIActivityRow` and `UILibraryRow` build the remaining screens.
- `App/…/ReviewDataSource.swift`: the protocol the UI is built against (load, plan, sync, record, folder, options) and `ReviewCapabilities`. `LiveReviewDataSource` runs each call off the main actor (`@concurrent`).
- `AppModel` (`@MainActor @Observable`): loads stored data, then a dry run; queues, badges, banners, snoozes, decisions, Finder and Contacts links.
- `LiveSyncController` (App): hosts the `SyncCoordinator` (below). `UILiveSync.swift` (Contacts2MdCLI, tested in `UILiveSyncTests` / `UILiveActivityTests`) holds the logic it shows: `UILiveState` folds the status stream into the toolbar / menu bar line, `UILiveSettings` the pause, `UISweepChoice` the Safety check picker, `UIBackgroundSync` the launchd agents.
- `BackgroundServices` (App): `SMAppService` for Launch at login and the background agent.

**Dry runs and Sync Now.** Once this Mac has exported or synced the vault, Check for Changes is the two-way plan (`prepareSync` + `recordSyncPlan`, recorded as a `plan` session) and Sync Now is `beginSync` → `prepareSync` → `executeSync` with `DecisionPolicy.gui`, trigger `GUI`. Before that, both fall back to the one-way export plan and the first export, as the CLI does. Onboarding's step 5 stays **Run First Export**: `prepareSync` needs a merge base that only the first export creates (`VaultNotReady` otherwise), and the first import's auto-adoption only exists on the export path. The vCard backup is taken only when the sync writes to Contacts.

**Live sync (M5).** `LiveSyncController` follows architecture §10 "Hosting in the app" once the folder is configured, Contacts access is granted and this Mac has synced (`records.lastExport`; right after the first export too): it opens the folder's scope through `RootBookmark.open()`, creates an `OwnWriteRegistry`, a `VaultSyncRunner` (`CLIEnvironment.live()`, policy `.gui`), loads `TriggerSettingsStore` and starts a `SyncCoordinator` with `LaunchCatchUp`, `ContactsChangeSource`, `VaultChangeSource`, `WakeSource` and `SweepScheduler`. The status stream is observed on the main actor and folded by `UILiveState`: a blocked or failed run stays visible after the coordinator goes idle, until a run finishes. On `.finished`, `.following` and blocked runs (other than the lock retry) the app re-reads stored data and runs a dry run, so Review, badges, banners and Since Last Sync stay current; dry runs never start while a coordinator run is in progress. When the coordinator was just started with live sync on, the launch catch-up replaces the start-up dry run. Folder change → `shutdown()` and a new coordinator; quit → `applicationShouldTerminate` waits for `shutdown()` (at most 20 s) before the scope closes.

- **Sync Now (⌘R)** goes through `coordinator.syncNow()` once hosted (full, never debounced, serialized with live runs). The banner overrides (Apply Anyway, Resume Anyway, Take Over) and the first export still run directly through `UIVaultReader.sync`, which takes the same local lock.
- **Toolbar status:** `Scheduled`, `Syncing… reading/planning/writing` (with a spinner), `Waiting for <device>`, `Waiting for another sync`, `Paused: safety breaker`, `Can't sync`, `Failed` (tooltip: the message), else `Reading…` / `Checking…`, else Idle or "N to review". The `Live` toggle is `live_sync` (on while not paused; turning it on ends a pause).
- **Turning live sync on** and **the end of a pause** submit a catch-up run (recorded as `Launch`): changes while it was off were not watched.
- Failures of a coordinator run show on the Overview ("N changes could not be written"); a Sync Now run with failures also raises the error banner.

**Live.**

| Screen        | Data                                                                                                     | Actions                                                                                                  |
|---------------|----------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| Overview      | stored status, sessions, latest dry run: Changed in Contacts (notes to write), Changed in Markdown (Apple changes from note edits, with "held" when writes are off or over the limit), notes to Trash, This Session / Last Sync with Apple and markdown C/U/D and held | Check Again, Reveal root, review rows link to their screens; Renamed Contacts: Update Links… (confirmed), Dismiss |
| Conflicts     | open `conflict` items grouped per record (one row per field: Previous / Contacts / Markdown, options from the engine; label conflicts offer only Keep Contacts / Keep Markdown) | Keep choice per field, ⌘1–3 for all fields, Apply (⌘↩), Resolve Selected with confirmation (Keep Both Where Possible leaves fields without it undecided) |
| Duplicates    | `duplicate cluster`, `copied note`, `merge records` and iCloud `version` items; contact details from the dry run; for versions a Current card plus one card per version (device, modified date, changed keys) | card multi-select (click / Space / ⌘A) with Same Person, Different People, Don't Sync, partition chips, Link Person N in Contacts…, Undo / Reset, Apply (confirmed: `resolve:…` → `cluster-resolve`), Not Duplicates (confirmed), Ignore for Now (until the next sync), Keep This One, Keep This File (merge records, confirmed: `keep:N` → `merge-keep`), Keep Current / Keep This Version (iCloud versions, confirmed: `keep-current` / `keep-other:N`), Reveal in Finder |
| Markdown Only | contact notes without a sync id, plus notes named by `possible match` items                             | per row: Add to Contacts (default when nothing matches), Link to "X" (default at ≥ 0.5), Not "X", Ignore; toolbar Add to Contacts for the selection; tick rows, Apply N Changes (⌘↩); Show Ignored |
| Deletions     | Deleted in Contacts (`appleDeleted`), Deleted in Markdown (`markdownDeleted`); notes a one-way export found missing are listed read-only until the next sync | Keep File, Unlink (default) · Delete File · Restore Contact; Restore File (default) · Unlink, Keep Contact · Delete Apple Contact…; Apply N Changes; destructive alert naming each file and contact (with its accounts) |
| All Contacts  | record map + note titles; search by name, file, account                                                  | Open in Contacts, Reveal in Finder                                                                       |
| Activity      | sessions with trigger (Live, Launch, Wake, Sweep, Manual, CLI, Rescan), Contacts C/U/D, Markdown C/U/D, Held, how Contacts was read (Trigger tooltip); previews behind Show Previews; unreadable contact notes with Reveal; the selected run's changes in the inspector | select a run → its change list (Reveal / Open per change); Export Log… (toolbar and File menu) |
| Settings      | device name, live sync, safety check, background sync, menu bar, Dock icon, launch at login, folders, accounts from the dry run, notes availability; Advanced ▸ Sync lease: role, holder, last heartbeat, turn end, stale, other devices with last sync and summary | General (below); choose root, folder for new notes, "Write changes back to Apple Contacts" (`apple_writes`) and "Add sync IDs to contacts" (`stamp_contacts`), Show backups, Take Over… (follower), Release Lease… (leader), both confirmed; Rescan Everything… (confirmed), Reset Sync State… (typed confirmation) |
| Menu bar      | status line, live sync line, Needs review total and per queue                                             | each count opens the main window at that screen; Sync Now, Open App…, Pause Live Sync ▸ For 1 Hour · Until Tomorrow (or Resume Live Sync), Settings…, Quit |

Every review answer is a decision appended to `.c2mdsync/devices/<device>/decisions.jsonl`, with the same choices as `contacts2md review decide` (conflicts `apple | markdown | both`, Deleted in Contacts `keep | trash | restore`, Deleted in Markdown `restore | unlink | delete-contact`, Add to Contacts `create-contact`). The next sync applies them; answered items leave the queue at once, and the affected Markdown Only rows say "Will be … on the next sync". A conflict answer applies only while both sides still hold the values it was made against; otherwise the conflict comes back.

**Settings switches.** Turning either switch on opens a confirmation sheet; turning it off saves at once. Writing to Contacts explains the vCard backup before every sync that changes Contacts (10 kept), the approval limit (`limits.max_apple_changes_without_approval`), that deletions still wait in Review, and how many changes are waiting now. Sync IDs explain the `x-c2mdsync:` URL, how many contacts and cards get one, that it is only needed with several devices (and how many use the folder), and that stamps need Apple writes on. Both go through `VaultSession.updateSettings`, so every other key in `config.yaml` stays byte-for-byte; a check runs afterwards so held counts update.

**Banners** (`UIBanner.banners`, from the latest dry run, the stored status and the last Sync Now):

| Banner | When | Action |
|---|---|---|
| Sync paused (red) | mass-vanish breaker in the dry run or the last Sync Now | Check Again · Resume Anyway… (confirmed; `allowMassVanish`, deletions are still only queued) |
| N changes wait for your approval (orange) | blast radius | Apply Anyway… (confirmed; approves exactly N for this sync, more are held again) |
| N changes held for Apple Contacts (gray) | `apple_writes` off and note edits waiting (stamps alone don't count) | Open Settings… |
| Waiting for *device* (gray) | another device's unexpired lease (stored, or returned by Sync Now) | Take Over… (confirmed; waits ~60 s, then syncs) |
| *Device* is syncing this folder; this Mac will follow (gray) | the same, while this Mac has not synced the folder yet: its first export writes nothing while another device leads | Take Over… (confirmed; the first export then runs) |
| Another sync is running on this Mac (gray) | the local lock was busy | — |
| Several devices … no sync IDs (orange) | identity warning | Open Settings… |

**Settings ▸ General** (`GeneralSettingsView`).

- *Live sync* and *Safety check* (Every hour / 2 / 4 / 6 hours / Off) are this Mac's `triggers.json`: `TriggerSettingsStore.save`, then `coordinator.update` with the effective settings. They can be changed before live sync is hosted (the footer says it starts after the first sync on this Mac). A hand-edited interval outside the list is shown as an extra choice.
- *Background sync when the app is closed*: launchd runs the app binary headless (`sync --quiet`, architecture §15) on a schedule. nix installs (bundle in `/nix/store/` or a nix-darwin app folder) get the toggle disabled and a `programs.contacts2mdsync.schedule` snippet instead. Other installs register a bundled agent with `SMAppService.agent(plistName:)`: `App/LaunchAgents/com.zmre.contacts2mdsync.sync-{1,2,4,6}h.plist`, copied to `Contents/Library/LaunchAgents` by `project.yml` (`BundleProgram` `Contents/MacOS/Contacts2MdSync`, `StartInterval`, background priority, `AssociatedBundleIdentifiers`). One plist per interval because `StartInterval` is fixed; choosing another interval unregisters the old agent. The status row shows On / Off / waiting for approval (with Open Login Items…) / registration errors. Runs appear in Activity as `CLI`.
- *Show in menu bar* (`showInMenuBar` in UserDefaults, default on): inserts the `MenuBarExtra`; while it is shown, closing the window keeps the app and live sync running (`applicationShouldTerminateAfterLastWindowClosed`).
- *Hide Dock icon when the window is closed* (`hideDockIconWhenClosed`, default on; disabled while the menu bar icon is off): `DockIconController` (App) follows window key/main/close notifications and these two settings, and `UIDockIcon.showsDockIcon` (tested) decides: with the menu bar icon shown, the setting on and no titled window open (the main window or Settings; the menu bar panel does not count), the app runs as an accessory (`NSApp.setActivationPolicy(.accessory)`: no Dock icon, not in ⌘-Tab); when a window opens (Open App… from the menu bar, a Dock-less relaunch) it switches back to `.regular` and activates. Without the menu bar icon the Dock icon always stays.
- *Launch at login*: `SMAppService.mainApp.register()` / `unregister()`, with approval state and errors.

**Pause Live Sync** (menu bar): live triggers off until the end (an hour, or the start of the next day), stored in UserDefaults (`livePausedUntil`) so it survives a relaunch; the sweep and Sync Now keep working. The coordinator gets `liveSync = false` through `update`, and a timer restores the saved settings and submits a catch-up run.

**Activity details.** M5 sessions carry `SessionRecord.sides` (Apple and markdown created / updated / deleted, held count and reason, `full` / `incremental` read) for every sync: from the app, live triggers, the CLI and schedules. Adoptions are left out of Markdown "updated" (This Session lists them separately). The app no longer writes its own split; for syncs started from the app before M5 it still reads the one kept in the device state's metadata (`ui_sync_sessions`, matched by start time and trigger), and older CLI syncs show "—" with the combined total in the tooltip.

**Multi-device (M6).** `LiveSyncController` creates the coordinator with `leaseKeeper: try? runner.makeLeaseKeeper()`, so the lease is heartbeated every 5 minutes while the app runs and released on quit or folder change; it copies the keeper's `leaseStatus` after every run and heartbeat. While another device leads, every run is a read-only dry run (`following(device:check:)`):

- The toolbar says "Waiting for *device*"; when the dry run failed (no Contacts access, …) it says "Following *device*: check failed" in red, with the message in the tooltip.
- The Overview's status section adds the follower line (`UIFollowerLine`): "Mac B leads; it still has N changes to apply" (or "nothing left to apply"), with when it was checked, the Needs Review count ("1 item needs review; answers made here are carried out by Mac B") or that review answers made here are carried out by the leader; a failed check is shown in red with its message. The count is `SyncRunSummary.changeCount`: both sides, images, resolved iCloud versions and the config file, without held Apple changes (`apple_writes` off, over the limit), which the leader does not apply either. Check for Changes, and a review answer while following, re-plan and replace the check. The line follows the lease between runs: the coordinator reports a heartbeat that sees another leader (a third Mac took over) or a lapsed lease (`followingEnded`; the line goes away even when the catch-up run is skipped with live sync off). Without live sync, or before the coordinator has seen the leader, it says who leads from the stored lease (none once that lease has expired); on a Mac that has not synced the folder yet it says to run the first sync again once the leader stops, or Take Over.
- **Take Over** (banner, Settings) calls `coordinator.takeOver()` while live sync is hosted (write, ~60 s settle, re-read, then Sync Now); a lost race shows an error. Before live sync is hosted it runs Sync Now with `takeOver` (also the first export).
- **Settings ▸ Advanced ▸ Sync lease** (`UILeaseInfo`): "This Mac leads syncing", "Following Mac B" (with "no heartbeat for over 10 minutes" when stale) or "No device leads"; last heartbeat, when the turn ends, Take Over… for a follower, Release Lease… for the leader (`coordinator.releaseLease()`, else `VaultSession.releaseLease()`; the next run here takes it again unless another device does first), and every other device with its last sync and summary.
- **First export while another device leads**: nothing is written (the same lock and lease as Sync Now, after planning). The banner "Mac B is syncing this folder; this Mac will follow" offers Take Over; onboarding's Run First Export shows the same message.
- **iCloud versions** (`version-…` items) appear in Duplicates as a group: the Current card and one card per version, with the device that saved it, when, and the changed keys. Keep Current / Keep This Version record `keep-current` / `keep-other:N`; the leader applies the choice on its next sync.

**Keep This File** (merge records: one linked contact carrying several sync ids). The answer is the item's `keep:N` choice, recorded as a `merge-keep` decision. The confirmation names the note that stays synced and the others, which the next sync detaches (`c2mdsync.status: detached`, left in place, nothing deleted), and says their sync ids are removed from the contact's cards, or that the removal is held while Apple writes are off.

**Contact notes (notes scripting).** Settings ▸ Advanced ▸ Contact notes is built as in §9: the source (entitlement, Contacts.app scripting, off), the `notes_sync` toggle (saved to `<state>/notes.json` through `NotesSettingsStore`, shared with `contacts2md config --notes`), the Automation permission read without launching Contacts.app (`ScriptingNotesProvider.currentPermission()`), the prompt through `requestPermission()` on Continue, the quit toggle (`quit_contacts_after_sync`), and the enablement summary from the plan's `NotesBaseline`. Activity's Notes column reads `SessionRecord.sides` (`notes`, `notes_to_contacts`, `notes_to_markdown`); live runs report `SyncRunSummary.notesToContacts` / `notesToMarkdown` / `notesWarning`. Body conflicts carry both full texts for Compare…. Never verified against a real Contacts.app (architecture §8 "Not covered").

**Onboarding steps 4 and 5.** After the preview, when the plan has duplicate clusters, step 4 *Review Duplicates* embeds the Duplicates cluster partition (`ClusterDetail`, with a group picker when there are several). Its buttons go through `ClusterActions`: answers are recorded before the folder is configured (`UIVaultReader.recordPreview`, appended to this Mac's decision log in the folder, like `review decide`), and the preview runs again so counts and the remaining groups update; Skip (one group) and **Skip for Now** (all) leave each group to yield one note, as the current rules say, and wait in Review; there is no inspector, so cards have Open and Reveal only. Run First Export is enabled once every group is answered or skipped (`SetupModel.duplicatesSettled`). The groups come from the preview's own snapshot (`UIOnboardingDuplicates.groups`, tested in `OnboardingDuplicatesTests`). Step 5 *Confirm* adds **Live sync** (this Mac's `live_sync`, the same switch as Settings ▸ General) and **Show in menu bar** (`showInMenuBar`), both on by default.

**Maintenance (Settings ▸ Advanced).** Both act on this Mac's state for the folder only and are disabled until this Mac has synced it and while a sync runs (architecture §4 *Maintenance*).

- **Rescan Everything…**: a confirmation, then `UIVaultReader.rescanEverything` (file cache, image hashes and the Contacts mirror forgotten); then Sync Now through the coordinator when live sync is hosted, else Check for Changes. The section says how many cached files were dropped.
- **Reset Sync State…**: a sheet explains what is forgotten (links between notes and contacts, merge history, caches, review queue) and what stays (notes, Contacts, decision log), and that a copy of the state database is saved first; the button is enabled only after typing "Reset". Live sync stops (`LiveSyncController.shutdown`, which also releases the lease), `UIVaultReader.resetSyncState` backs up and resets, and the window reloads: the toolbar's Sync Now is this Mac's first sync again, which binds notes like a joining device. The section shows the backup's file name.

**Activity change list and Export Log.** Selecting a run in Activity shows it in the inspector: trigger, duration, counts, and the run's changes from its change log (`UIActivityChange`: "Updated Jane Doe.md — job_title, phones", "Updated Sam Lee in Contacts — emails"), each with Reveal (notes) and Open (the contact's cards as bound now). Runs from before the change log, previews and runs that changed nothing say so. **File ▸ Export Log…** (and the Activity toolbar) asks for a file and writes this Mac's last 500 runs with their changes: text for `.txt` (one line per run like the CLI summary, indented changes), JSON for `.json` (`exported_at`, `device`, `sessions` with `session` and `changes`; `UIActivityLog`, tested in `ActivityLogTests`).

**Renamed contacts (Overview).** When a sync regenerated a title and notes outside the contact notes still link the old one, the Overview shows "Ann One is now Ann Smith · 1 note outside contacts links to [[Ann One]]" with **Update Links…** (confirmation listing the notes; each is backed up, then rewritten compare-and-swap) and **Dismiss**. It is refreshed after runs that finished and when the Overview appears (it reads the non-contact notes); architecture §8.

**Still pending.**

- Verify with a real build: the menu bar window, closing the main window with the menu bar shown (the Dock icon leaving and coming back), quitting during a run, Take Over / Release Lease and the follower line with two Macs on one iCloud folder, and the background agent's Contacts permission when launchd starts the app binary (architecture §15, spike S11; `SMAppService` agents are attributed to the app, which should carry its grant). Also not yet run in a real app: onboarding step 4 on a real address book, Rescan Everything / Reset Sync State followed by Sync Now, Export Log's save panel, and Update Links.

**Deviations.**

- Onboarding is shown in the main window rather than a separate 640×520 window, as one form with the five steps as sections.
- Duplicates: clusters use the card multi-select (`ClusterDetail`; model `UIClusterPartition` in `Contacts2MdCLI/UIClusterPartition.swift`, tested in `UIClusterPartitionTests`). Each member card carries its note path instead of a separate Markdown card, and has Open / Reveal / Details buttons. The old "Sync Only" menu is gone; `only:N` remains a CLI choice and old sync-only answers display as Person A + Not synced. Give the Other a New ID and Delete Other File… are not offered (no decision kind). Keep This One is the only copied-note action.
- Markdown Only: no rows are ticked by default, even where Add or Link is the default action, so nothing is applied without a tick. Link to Other… (a contact picker) is not built.
- Conflicts: Keep Both is offered only where the engine offers it (list elements edited on both sides, the body), never for label conflicts.
- Deletions: Delete Apple Contact deletes every card of the contact that this Mac can write to (the engine's `delete-contact`), not only the iCloud card; the alert says so and lists the contact's accounts.
- Activity shows this Mac's sessions only (sessions live in the per-device database). Dry runs are recorded as previews and hidden by default.
- Device name is read-only: it follows the computer name.
- Dry runs take review details and account counts from the plan's own snapshot (`PreparedSync.snapshot`): no second Contacts read. After a live run the app still runs one dry run (an incremental read with a valid history token) to refresh Since Last Sync and Review; it is recorded as a preview.
- Menu bar: the icon is `person.2.circle`, filled while something needs review and arrows while syncing, instead of an orange dot (menu bar icons are template images). The panel adds Settings… and Quit. Pause offers For 1 Hour and Until Tomorrow (the start of the next day).
- Unavailable accounts (§3): the Overview banner is `AccountBannerSection` over `UIOverview.accounts` (`UIAccountBanner`: banner text, detail, the latest `wait` / `forget` answer, and the forget preview from the pending `account-missing:<id>` item). Keep Waiting and Forget record through `AppModel.decide` like every other review answer; Forget takes effect on the next sync. The menu bar panel lists the same banner text under the status line; Activity marks runs during which an account was missing (`UIActivityRow.accounts`).
