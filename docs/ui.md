# Contacts2MdSync — UI Design

Status: M4 review UI wired to the M3 two-way sync engine (see §14 for what is live, what is still pending, and deviations). ASCII mockups; final visuals follow macOS HIG with native SwiftUI components.

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
┌──────────────────────┬───────────────────────────────────────────────────────────────┐
│ 7 possible duplicates│  Chris Martin — 2 contacts, 1 file                            │
│                      │  Why: same email chris@acme.com · same phone · similar name   │
│▸ Chris Martin   2+1  │                                                               │
│  iCloud+Google+md    │  ┌ iCloud ─────────┐ ┌ Google ─────────┐ ┌ Markdown ───────┐  │
│  Ana Ruiz       2 md │  │ Chris Martin    │ │ Christopher     │ │ Chris Martin.md │  │
│  same sync id        │  │ Acme            │ │ Martin          │ │ Work/           │  │
│  J. Park        2    │  │ chris@acme.com  │ │ chris@acme.com  │ │ id 7f3a…        │  │
│  iCloud+Google       │  │ +1 555 0111     │ │ +1 555 0111     │ │ tags: friends   │  │
│                      │  └─────────────────┘ └─────────────────┘ └─────────────────┘  │
│                      │                                                               │
│                      │  [Open in Contacts to Link]  [Sync Only iCloud ▾]             │
│                      │  [Not Duplicates]            [Ignore for Now]                 │
└──────────────────────┴───────────────────────────────────────────────────────────────┘
```

- Apple has no public API to link cards, so the primary action opens both in Contacts.app (user links them with Card ▸ Link Selected Cards); we rescan on return.
- **Sync Only …** keeps one card synced and excludes the others.
- **Not Duplicates** is remembered forever; **Ignore for Now** snoozes until the next detection run.
- Two files with the same sync id: Keep This One · Give the Other a New ID · Delete Other File…
- Two stamped files now pointing at one linked contact: Pick Surviving File · (other file → Trash on confirm).

## 8. Activity

```
│ Time            │ Device       │ Trigger │ Contacts C/U/D │ Markdown C/U/D │ Review │ Result │
│ Today 10:42 AM  │ MacBook Pro  │ Live    │     0/2/0      │     1/5/1      │   3    │  ✓     │
│ Today  8:01 AM  │ iPad         │ Manual  │     0/0/0      │     0/1/0      │   —    │  ✓     │
│ Yesterday 6:12P │ MacBook Pro  │ Live    │       —        │       —        │   —    │  ⚠ 1   │
│ Yesterday 3:00A │ MacBook Pro  │ CLI     │     0/0/0      │     2/0/0      │   2    │  ⚠ 2   │
```

- Inspector lists each change ("Updated Jane Doe.md — job, phone") with Reveal / Open.
- Trigger is Manual, Live, Launch, Wake, Sweep or CLI. Items a CLI run skipped show up in Review badges like any others.
- Warnings expand inline ("34 files not downloaded from iCloud Drive; skipped").
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

Advanced  Contact notes      ◦ Not available — notes stay markdown-only
          Sync lease         Held by: none · [Take Over…]
          Backups            10 kept · [Show in Finder]
          [Rescan Everything…]  [Reset Sync State…]
```

## 10. Menu bar extra

```
 person.2.circle  (orange dot when review pending)
┌──────────────────────────────────┐
│ ✓ In sync · 10:42 AM             │
│ Live sync on                     │
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

## 14. As built (M4 UI on the M3 engine)

**Structure.** `ContentView` shows onboarding (`SetupView`, steps 1–3 and 5) until the folder is configured, a "Can't open the notes folder [Locate…]" pane when the saved bookmark no longer resolves, and otherwise `MainView`: the §1 sidebar with badges, toolbar (status dot + text, disabled `Live` toggle, **Sync Now**, inspector toggle), banners above every screen, and `.inspector`. Menu commands: Contacts ▸ Sync Now (⌘R), Check for Changes (⇧⌘R); View ▸ Show/Hide Inspector (⌥⌘I).

**Layers.**

- `Contacts2MdCLI/UI*.swift`: view-model adapters over the public engine APIs, tested in `UIReviewTests`, `UISyncTests` and `UISyncOutcomeTests`. `UIVaultReader` (`UIVaultReader.swift`) reads stored state and scans the folder (no Contacts access), runs dry runs and Sync Now through the same `VaultSession` calls as `contacts2md plan` / `sync`, appends decisions, and edits `default_folder`, `apple_writes` and `stamp_contacts`. `UIReviewQueues` turns stored state into screen data: `UIConflictRecord` (`UIConflicts.swift`), `UIDeletionRow` (`UIDeletions.swift`), `UIDuplicateGroup`, `UIMarkdownOnlyRow`. `UISync.swift` has the Sync Now request/outcome/summary, the two-way part of a dry run (`UISyncPlanSummary`) and `UIBanner`. `UIOverview`, `UIActivityRow` and `UILibraryRow` build the remaining screens.
- `App/…/ReviewDataSource.swift`: the protocol the UI is built against (load, plan, sync, record, folder, options) and `ReviewCapabilities`. `LiveReviewDataSource` runs each call off the main actor (`@concurrent`).
- `AppModel` (`@MainActor @Observable`): loads stored data, then a dry run; queues, badges, banners, snoozes, decisions, Finder and Contacts links.

**Dry runs and Sync Now.** Once this Mac has exported or synced the vault, Check for Changes is the two-way plan (`prepareSync` + `recordSyncPlan`, recorded as a `plan` session) and Sync Now is `beginSync` → `prepareSync` → `executeSync` with `DecisionPolicy.gui`, trigger `GUI`. Before that, both fall back to the one-way export plan and the first export, as the CLI does. Onboarding's step 5 stays **Run First Export**: `prepareSync` needs a merge base that only the first export creates (`VaultNotReady` otherwise), and the first import's auto-adoption only exists on the export path. The vCard backup is taken only when the sync writes to Contacts.

**Live.**

| Screen        | Data                                                                                                     | Actions                                                                                                  |
|---------------|----------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| Overview      | stored status, sessions, latest dry run: Changed in Contacts (notes to write), Changed in Markdown (Apple changes from note edits, with "held" when writes are off or over the limit), notes to Trash, This Session / Last Sync with Apple and markdown C/U/D and held | Check Again, Reveal root, review rows link to their screens |
| Conflicts     | open `conflict` items grouped per record (one row per field: Previous / Contacts / Markdown, options from the engine; label conflicts offer only Keep Contacts / Keep Markdown) | Keep choice per field, ⌘1–3 for all fields, Apply (⌘↩), Resolve Selected with confirmation (Keep Both Where Possible leaves fields without it undecided) |
| Duplicates    | `duplicate cluster`, `copied note`, `merge records` items; contact details from the dry run              | Open in Contacts to Link, Sync Only *card*, Not Duplicates (confirmed), Ignore for Now (until the next sync), Keep This One |
| Markdown Only | contact notes without a sync id, plus notes named by `possible match` items                             | per row: Add to Contacts (default when nothing matches), Link to "X" (default at ≥ 0.5), Not "X", Ignore; toolbar Add to Contacts for the selection; tick rows, Apply N Changes (⌘↩); Show Ignored |
| Deletions     | Deleted in Contacts (`appleDeleted`), Deleted in Markdown (`markdownDeleted`); notes a one-way export found missing are listed read-only until the next sync | Keep File, Unlink (default) · Delete File · Restore Contact; Restore File (default) · Unlink, Keep Contact · Delete Apple Contact…; Apply N Changes; destructive alert naming each file and contact (with its accounts) |
| All Contacts  | record map + note titles; search by name, file, account                                                  | Open in Contacts, Reveal in Finder                                                                       |
| Activity      | sessions with trigger (Manual, CLI, …), Contacts C/U/D, Markdown C/U/D, Held; previews behind Show Previews; unreadable contact notes with Reveal | —                                                                                                        |
| Settings      | device name, folders, accounts from the dry run, notes availability, lease holder                       | Choose root, folder for new notes, "Write changes back to Apple Contacts" (`apple_writes`) and "Add sync IDs to contacts" (`stamp_contacts`), Show backups |

Every review answer is a decision appended to `.c2mdsync/devices/<device>/decisions.jsonl`, with the same choices as `contacts2md review decide` (conflicts `apple | markdown | both`, Deleted in Contacts `keep | trash | restore`, Deleted in Markdown `restore | unlink | delete-contact`, Add to Contacts `create-contact`). The next sync applies them; answered items leave the queue at once, and the affected Markdown Only rows say "Will be … on the next sync". A conflict answer applies only while both sides still hold the values it was made against; otherwise the conflict comes back.

**Settings switches.** Turning either switch on opens a confirmation sheet; turning it off saves at once. Writing to Contacts explains the vCard backup before every sync that changes Contacts (10 kept), the approval limit (`limits.max_apple_changes_without_approval`), that deletions still wait in Review, and how many changes are waiting now. Sync IDs explain the `x-c2mdsync:` URL, how many contacts and cards get one, that it is only needed with several devices (and how many use the folder), and that stamps need Apple writes on. Both go through `VaultSession.updateSettings`, so every other key in `config.yaml` stays byte-for-byte; a check runs afterwards so held counts update.

**Banners** (`UIBanner.banners`, from the latest dry run, the stored status and the last Sync Now):

| Banner | When | Action |
|---|---|---|
| Sync paused (red) | mass-vanish breaker in the dry run or the last Sync Now | Check Again · Resume Anyway… (confirmed; `allowMassVanish`, deletions are still only queued) |
| N changes wait for your approval (orange) | blast radius | Apply Anyway… (confirmed; approves exactly N for this sync, more are held again) |
| N changes held for Apple Contacts (gray) | `apple_writes` off and note edits waiting (stamps alone don't count) | Open Settings… |
| Waiting for *device* (gray) | another device's unexpired lease (stored, or returned by Sync Now) | Take Over… (confirmed; waits ~60 s, then syncs) |
| Another sync is running on this Mac (gray) | the local lock was busy | — |
| Several devices … no sync IDs (orange) | identity warning | Open Settings… |

**Activity details.** `SessionRecord` stores Apple and markdown changes combined and has no held count. For syncs started from the app, `UIVaultReader.sync` keeps the split (and held count and reason) in the device state's metadata (`ui_sync_sessions`, last 200, matched by start time and trigger). Syncs from the CLI or a schedule show "—" in both C/U/D columns with the combined total in the tooltip.

**Still pending.**

- Keep This File (merge records): the M3 decision log has no kind for it and `mergeRecords` items have no choices, so the button stays disabled ("Not supported by the sync engine yet").
- Rescan Everything / Reset Sync State, the per-change Activity inspector, Export Log.
- M5/M6: Live toggle, background sync, safety check, menu bar, launch at login.

**Deviations.**

- Onboarding is shown in the main window rather than a separate 640×520 window. Step 4 (review duplicates during onboarding) is not embedded: duplicates found by the first preview wait in Review after the first export.
- Duplicates: "Sync Only" is a menu next to the group actions, and each card has Open / Reveal buttons. Give the Other a New ID and Delete Other File… are not offered (no decision kind). Keep This One is the only copied-note action.
- Markdown Only: no rows are ticked by default, even where Add or Link is the default action, so nothing is applied without a tick. Link to Other… (a contact picker) is not built.
- Conflicts: Keep Both is offered only where the engine offers it (list elements edited on both sides, the body), never for label conflicts.
- Deletions: Delete Apple Contact deletes every card of the contact that this Mac can write to (the engine's `delete-contact`), not only the iCloud card; the alert says so and lists the contact's accounts.
- Activity shows this Mac's sessions only (sessions live in the per-device database). Dry runs are recorded as previews and hidden by default.
- Device name is read-only: it follows the computer name.
- A two-way dry run takes a second Contacts snapshot only when review items name contacts (duplicates, possible matches), for their card details; `PreparedSync` does not expose its snapshot. Account counts in Settings come from the synced records otherwise.
