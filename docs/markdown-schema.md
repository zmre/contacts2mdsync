# Markdown Contact Schema

Contacts2MdSync writes files that the [mbr markdown browser](https://zmre.github.io/mbr-markdown-browser/markdown/contacts/) renders as contact cards. This document defines exactly what we emit, what we read, and which keys belong to the sync engine.

Format contract source: `zmre/mbr-markdown-browser` @ `4636f9e`, `crates/mbr-core/src/contact.rs` (`Contact::from_map`, ~399–470) and `relationships.rs`.

## 1. Example

```yaml
---
type: person
title: Jane Q. Doe
prefix: Dr.
first_name: Jane
middle_name: Quinn
last_name: Doe
aliases:
  - nickname: JJ
  - maiden_name: Jane Smith
company: "[[Acme Corp]]"
department: R&D
job_title: CTO
image: ../_images/6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13.jpg
emails:
  - work: jane@acme.com
  - home: jane@example.com
phones:
  - mobile: "+1 415 555 0100"
  - work: "+1 415 555 0199"
urls:
  - homepage: https://janedoe.example
social:
  - linkedin: https://www.linkedin.com/in/janedoe
im:
  - signal: "+1 415 555 0100"
addresses:
  - home:
      street: "1 Main St"
      city: Springfield
      region: IL
      postcode: "62701"
      country: USA
      country_code: US
dates:
  birthday: "1980-03-19"
  anniversary: "--06-10"
relationships:
  - type: spouse
    to: "[[John Doe]]"
  - type: parent
    to: "[[Bob Smith]]"
    label: father
tags:
  - family
  - close_friends
apple:
  phonetic_last_name: ドウ
c2mdsync:
  id: 6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13
---
Everything below the frontmatter is the Apple Contacts "Notes" field
(when the notes entitlement is available; otherwise it is markdown-only).
```

## 2. Field mapping

| Markdown key                              | Apple (`CNContact`)                                     | Direction | Notes                                                                                                       |
|-------------------------------------------|---------------------------------------------------------|-----------|-------------------------------------------------------------------------------------------------------------|
| `type`                                    | `contactType` (`.person` / `.organization`)             | both      | Required. mbr detects contacts only by this key.                                                            |
| `title`                                   | — (derived from name on create)                         | md-owned  | Always written. Primary link-match key in mbr. See §5.                                                      |
| `prefix`                                  | `namePrefix`                                            | both      |                                                                                                             |
| `first_name`                              | `givenName`                                             | both      |                                                                                                             |
| `middle_name`                             | `middleName`                                            | both      |                                                                                                             |
| `last_name`                               | `familyName`                                            | both      |                                                                                                             |
| `suffix`                                  | `nameSuffix`                                            | both      |                                                                                                             |
| `aliases`                                 | `nickname`, `previousFamilyName`                        | partial   | `nickname:` ↔ nickname; `maiden_name:` ↔ previous family name. Plain-string aliases are markdown-only.      |
| `company`                                 | `organizationName`                                      | both      | Existing `[[Org]]` style preserved; new values become wikilinks only if an org note with that title exists. |
| `department`                              | `departmentName`                                        | both      |                                                                                                             |
| `job_title`                               | `jobTitle`                                              | both      |                                                                                                             |
| `image`                                   | `imageData`                                             | both      | Sidecar file in `_images/<id>.<ext>`; compared by hash, never path.                                         |
| `gender`                                  | —                                                       | md-only   | Passed through untouched.                                                                                   |
| `emails`                                  | `emailAddresses`                                        | both      | List of single-key maps.                                                                                    |
| `phones`                                  | `phoneNumbers`                                          | both      | Always quoted.                                                                                              |
| `urls`                                    | `urlAddresses` (minus our stamp)                        | both      | `x-c2mdsync:` stamp URL is filtered out and never written to markdown.                                      |
| `social`                                  | `socialProfiles`                                        | both      | Label = service name.                                                                                       |
| `im`                                      | `instantMessageAddresses`                               | both      | Label = service name.                                                                                       |
| `addresses`                               | `postalAddresses`                                       | both      | Map with `street, city, region, postcode, country, country_code`.                                           |
| `dates.birthday`                          | `birthday`                                              | both      | `YYYY-MM-DD` or `--MM-DD` when year unknown.                                                                |
| `dates.<label>`                           | `dates`                                                 | both      | `anniversary`, custom labels.                                                                               |
| `dates.death`, `born_place`, `died_place` | —                                                       | md-only   | Passed through.                                                                                             |
| `relationships`                           | `contactRelations`                                      | both      | See §6.                                                                                                     |
| `tags`                                    | group membership (managed tags only)                    | both      | See §7.                                                                                                     |
| `apple.*`                                 | phonetic names, `phoneticOrganizationName`, etc.        | both      | Apple fields mbr has no slot for.                                                                           |
| body                                      | `note`                                                  | both*     | *Only with `com.apple.developer.contacts.notes`. Entire body.                                               |
| `c2mdsync.*`                              | `urlAddresses` stamp (`c2mdsync` / `x-c2mdsync:<uuid>`) | engine    | See §3.                                                                                                     |
| any other key                             | —                                                       | md-only   | Preserved byte-for-byte, in place.                                                                          |

Apple-side rewrites the mapping has to absorb ([spike S5](spikes.md#s5-normalization-catalog)):

- **`social`**: Contacts fills in a `urlString` for known services on save (`twitter: zzspike` gains `http://twitter.com/zzspike`). A URL that equals the one Contacts synthesizes for that service and username is not exported, so a bare handle in markdown stays a bare handle.
- **`image`**: after an iCloud sync, Apple can report `imageDataAvailable = false` and offer only a re-encoded thumbnail. In that state the existing `_images/` file and the `image:` key are kept unchanged; the thumbnail is never exported in place of the original. If no image file exists yet, nothing is exported until `imageData` is available.
- **`dates`**: Contacts sets a Gregorian calendar on saved dates, including yearless ones. The calendar is not exported; `--MM-DD` stays `--MM-DD`.

### Label mapping (Apple → markdown)

| Apple label constant          | Markdown label |
|-------------------------------|----------------|
| `_$!<Mobile>!$_`              | `mobile`       |
| `iPhone`                      | `iphone`       |
| `Apple Watch`                 | `apple_watch`  |
| `_$!<Main>!$_`                | `main`         |
| `_$!<Home>!$_`                | `home`         |
| `_$!<Work>!$_`                | `work`         |
| `_$!<Other>!$_`               | `other`        |
| `_$!<HomeFAX>!$_`             | `home_fax`     |
| `_$!<WorkFAX>!$_`             | `work_fax`     |
| `_$!<OtherFAX>!$_`            | `other_fax`    |
| `_$!<Pager>!$_`               | `pager`        |
| `_$!<HomePage>!$_`            | `homepage`     |
| `iCloud`                      | `icloud`       |
| `CNLabelSchool`               | `school`       |
| `_$!<Anniversary>!$_`         | `anniversary`  |
| custom `"Summer House"`       | `summer_house` |
| unknown `_$!<Foo Bar>!$_`     | `foo_bar`      |
| no label                      | bare list item |

Exceptions: social profiles and IM addresses use the **service** as label (`LinkedIn` → `linkedin`, `Skype` → `skype`), falling back to the mapped value label. Unlabeled Apple dates become `other` (mbr requires a label on every date). Markdown → Apple: well-known labels map back to the constants; custom labels are humanized (`summer_house` → `Summer House`).

On write-back, if an existing Apple label already maps to the same markdown label, the Apple label is left untouched (no label flapping). Custom labels keep their original Apple casing when a base record exists.

## 3. Sync-owned keys

```yaml
c2mdsync:
  id: <uuid v4, lowercase>     # required once linked
  status: detached              # optional; only when out of scope / unlinked
```

- Contains nothing device-specific and no timestamps, so files stay git-diff-clean and identical across devices (no iCloud conflict copies from metadata churn).
- `id` is also stamped on the Apple contact as a URL: label `c2mdsync`, value `x-c2mdsync:<uuid>`. The stamp goes on the iCloud underlying card. A Google-only contact gets it on its Google card (survival on Google is still being verified, spike S1). The stamp survived iCloud.com and iPhone edits.
- A note with `type: person|organization` and **no** `c2mdsync.id` is a *markdown-only candidate*. It is never pushed to Contacts unless the user opts it in from the UI.
- Two files with the same `c2mdsync.id` (copied file) pause sync for that record until the user picks one.

> **Marker names (final):** frontmatter `c2mdsync:`, vault dir `.c2mdsync/`, contact URL label `c2mdsync` with value `x-c2mdsync:<uuid>`. Only these exact names are recognized; any other top-level key is preserved as an unknown passthrough key.

## 4. Emission rules

- Fixed key order (as in §1). Unknown keys keep their original position and bytes; we patch only managed key spans.
  - A managed key whose value did not change keeps its original bytes too (including user formatting and trailing comments), so re-exporting an unchanged contact is byte-identical.
  - Comments and blank lines between keys stay where they are.
  - A managed key that is new to the file goes right after the nearest earlier managed key; if no later managed key exists it is appended at the end.
  - Patching needs a plain block mapping at column 0. Flow-style frontmatter, YAML anchors/aliases, or anything the line scanner and the real parse disagree on fall back to a full re-emit in canonical order, with unknown keys re-emitted from their parsed values (not their bytes).
- Multi-value fields are always emitted as **lists of single-key maps** (preserves order and duplicate labels; mbr treats order as preference).
- We **read** every form mbr accepts: map, list of `{label: value}`, bare strings, scalar, and `{label:, value:}`.
- Quote anything YAML could reinterpret: phone numbers, postcodes, dates, `yes/no/on/off/true/false/null`, leading `0`, leading `@`, `[`, `*`, `&`, `!`, `#`, `%`, `|`, `>`, `:`.
- `dates` is a map (mbr's documented form), except when labels repeat (two anniversaries), which a map cannot hold: then the list-of-single-key-maps form, which mbr reads the same way.
- Addresses are `- <label>:` + nested fields. A label spelled like an address field or `label`/`value` (`street`, `city`, …) would be misread by mbr, so those use `- label: street` inside the address object (or `{label, value}` for a string address).
- Values are trimmed (mbr trims too). U+FEFF is removed from values: libyaml drops it from scalars, so it could never read back.
- Plain vs quoted: a value is written plain only if it reads back as the same string under both YAML 1.1 and 1.2 resolvers (checked in tests against Yams' 1.1 resolver). Quoted values use double quotes with `\n`, `\t`, `\"`, `\\` and `\xNN` escapes. Phones, postcodes and dates are always quoted; `c2mdsync.id` UUIDs are always plain.
- The `c2mdsync.id` is lowercase.
- Every emitted file is re-parsed before writing; if the decoded model differs from the intended one, the write is aborted and reported.
- Files with invalid YAML are never written to (mbr would ignore the whole frontmatter anyway).
- If emitted bytes equal what's on disk, no write happens.

## 5. Filenames and titles

- New files: `<default_folder>/<Title>.md`. NFC-normalized; `/ : \` replaced with `-`; control and format characters dropped; leading dots stripped; max 120 chars.
- Collision: `Title (Company).md`, then `Title 2.md`, `Title 3.md`, … A stem counts as taken if **any** file anywhere under the root has it (case-insensitive), because mbr resolves links by stem globally.
- Generated title (new notes only): person → `given family suffix` (no prefix or middle name; Chinese/Japanese names → `familygiven`); else nickname; else company; else first email; else first phone; else `Unnamed Contact`. Organization → company name. Two different contacts may get the same title (their files differ); the exporter warns because `[[links]]` to that title are ambiguous.
- **Never renamed automatically.** mbr falls back to the filename stem when resolving links, so the original name keeps old links alive. UI offers an explicit "rename file to match title".
- `title` is markdown-owned. When Apple's name changes and the current title equals the previously generated title, the title is regenerated and the old title is appended to `aliases` as a plain string (keeps `[[Old Name]]` links resolving).
- Users may move files anywhere under the root. Identity is `c2mdsync.id`, never path.

## 4a. One-way export (M1)

`contacts2md export` writes Apple → markdown only. For an existing note:

| Data                                                                                                                                                    | On export                                                                                                                                                                                                                          |
|---------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| name parts, `company`, `department`, `job_title`, `emails`, `phones`, `urls`, `social`, `im`, `addresses`, `dates` (except `death`), `apple.phonetic_*` | from Apple. An element whose comparison key equals a markdown element keeps the markdown display text (e.g. `+1 415-555-0199` vs Apple's `(415) 555-0199`).                                                                        |
| `aliases` `nickname:` / `maiden_name:`                                                                                                                  | from Apple                                                                                                                                                                                                                         |
| other aliases (plain, `formerly:`, …)                                                                                                                   | kept                                                                                                                                                                                                                               |
| `title`                                                                                                                                                 | kept (markdown-owned)                                                                                                                                                                                                              |
| `company` wikilink                                                                                                                                      | kept if it names the same organization; a new value becomes `[[Org]]` only if an organization note with that title exists                                                                                                          |
| `relationships`                                                                                                                                         | from Apple, resolved to `[[Title]]` when exactly one note answers to the name (title, alias, name variants); extra edge attributes kept; markdown-only types (`employer`, `employee`, `manages`, `assists`) and `from:` edges kept |
| `tags`                                                                                                                                                  | managed tags follow Apple groups; unmanaged tags kept, in order                                                                                                                                                                    |
| `image`                                                                                                                                                 | `<images_folder>/<c2mdsync.id>.<ext>`, relative to the note's current folder; a user-set image is kept when Apple has none                                                                                                         |
| body                                                                                                                                                    | Apple note when entitled and non-empty; otherwise untouched                                                                                                                                                                        |
| `dates.death`, unknown keys, `apple.*` extras, `c2mdsync.*` extras                                                                                      | kept                                                                                                                                                                                                                               |

## 6. Relationships

mbr resolves `to: "[[X]]"` by **global name** (title → alias → filename stem, case-insensitive), so links survive moves. Path-style links (`[[people/jane]]`) do not resolve inside `relationships:` and are never emitted.

| Apple relation label                 | mbr `type`     | `label`               |
|--------------------------------------|----------------|-----------------------|
| father / mother / parent             | `parent`       | `father` / `mother`   |
| son / daughter / child               | `child`        | `son` / `daughter`    |
| spouse / husband / wife / partner    | `spouse`       | original if not spouse |
| brother / sister / sibling           | `sibling`      | `brother` / `sister`  |
| manager                              | `reports_to`   |                       |
| assistant                            | `assistant`    |                       |
| friend, custom                       | snake_case     |                       |
| no label                             | `related`      |                       |

- Apple stores relations as **names only**. On export we resolve the name to a record; if unique → `to: "[[<record title>]]"`, else plain string.
- On write-back the Apple relation name is the target's Apple display name.
- We never emit reverse edges (mbr derives them), `from:` edges, or the implicit `company` employer edge back to Apple. Extra edge attributes (e.g. `married: 1948-06-01`) are markdown-only and preserved.

## 7. Tags and groups

- A tag is **managed** iff it appears in the `groups` map in `.c2mdsync/config.yaml` (seeded from iCloud/Local groups at first import, e.g. `"Close Friends": close_friends`).
- Managed tags sync both ways (three-way set merge). Unmanaged tags never touch Apple.
- Tags follow mbr normalization: lowercase, spaces → `_`.
- New Apple groups appear as new managed tags. New groups from markdown are created only via the UI ("Create Apple group from tag").
- Contacts with no iCloud/Local card can't join groups; the tag stays in markdown and the UI shows a warning (no flapping).

## 8. Vault layout

```
~/Notes/Contacts/                 # root (user-chosen)
  .c2mdsync/                        # hidden from mbr
    config.yaml                   # vault_id, schema, folders, group↔tag map, scope, limits
    lease.json                    # multi-device sync lease
    devices/<device-id>.json      # per-device heartbeat + last summary
    devices/<device-id>/decisions.jsonl   # append-only user intents
  _images/<id>.jpg                # contact photos (visible so mbr can serve them)
  Inbox/                          # default folder for new contacts (configurable)
  Work/ Family/ ...               # anything the user wants
```

### `config.yaml` sketch

```yaml
vault_id: 0d7c…
schema: 1
default_folder: Inbox
images_folder: _images
default_region: US
groups:
  "Close Friends": close_friends
  "Family": family
limits:
  max_apple_changes_without_approval: 25
  mass_vanish_count: 10
  mass_vanish_percent: 5
scope:                     # shape defined now; enforced from M3
  containers: [icloud, google]
  include_groups: []
  exclude_groups: []
  include_contacts: []     # c2mdsync ids
  exclude_contacts: []
  markdown:
    include_paths: ["**"]
    exclude_paths: ["Templates/**"]
  require_tag: null
on_leave_scope: detach
```
