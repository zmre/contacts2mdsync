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
mdsync:
  id: 6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13
---
Everything below the frontmatter is the Apple Contacts "Notes" field
(when the notes entitlement is available; otherwise it is markdown-only).
```

## 2. Field mapping

| Markdown key       | Apple (`CNContact`)                                  | Direction | Notes                                                                 |
|--------------------|------------------------------------------------------|-----------|-----------------------------------------------------------------------|
| `type`             | `contactType` (`.person` / `.organization`)          | both      | Required. mbr detects contacts only by this key.                     |
| `title`            | — (derived from name on create)                      | md-owned  | Always written. Primary link-match key in mbr. See §5.               |
| `prefix`           | `namePrefix`                                         | both      |                                                                       |
| `first_name`       | `givenName`                                          | both      |                                                                       |
| `middle_name`      | `middleName`                                         | both      |                                                                       |
| `last_name`        | `familyName`                                         | both      |                                                                       |
| `suffix`           | `nameSuffix`                                         | both      |                                                                       |
| `aliases`          | `nickname`, `previousFamilyName`                     | partial   | `nickname:` ↔ nickname; `maiden_name:` ↔ previous family name. Plain-string aliases are markdown-only. |
| `company`          | `organizationName`                                   | both      | Existing `[[Org]]` style preserved; new values become wikilinks only if an org note with that title exists. |
| `department`       | `departmentName`                                     | both      |                                                                       |
| `job_title`        | `jobTitle`                                           | both      |                                                                       |
| `image`            | `imageData`                                          | both      | Sidecar file in `_images/<id>.<ext>`; compared by hash, never path.  |
| `gender`           | —                                                    | md-only   | Passed through untouched.                                             |
| `emails`           | `emailAddresses`                                     | both      | List of single-key maps.                                             |
| `phones`           | `phoneNumbers`                                       | both      | Always quoted.                                                       |
| `urls`             | `urlAddresses` (minus our stamp)                     | both      | `x-mdsync:` stamp URL is filtered out and never written to markdown. |
| `social`           | `socialProfiles`                                     | both      | Label = service name.                                                 |
| `im`               | `instantMessageAddresses`                            | both      | Label = service name.                                                 |
| `addresses`        | `postalAddresses`                                    | both      | Map with `street, city, region, postcode, country, country_code`.    |
| `dates.birthday`   | `birthday`                                           | both      | `YYYY-MM-DD` or `--MM-DD` when year unknown.                          |
| `dates.<label>`    | `dates`                                              | both      | `anniversary`, custom labels.                                         |
| `dates.death`, `born_place`, `died_place` | —                             | md-only   | Passed through.                                                       |
| `relationships`    | `contactRelations`                                   | both      | See §6.                                                               |
| `tags`             | group membership (managed tags only)                 | both      | See §7.                                                               |
| `apple.*`          | phonetic names, `phoneticOrganizationName`, etc.     | both      | Apple fields mbr has no slot for.                                    |
| body               | `note`                                               | both*     | *Only with `com.apple.developer.contacts.notes`. Entire body.         |
| `mdsync.*`         | `urlAddresses` stamp (`mdsync` / `x-mdsync:<uuid>`)  | engine    | See §3.                                                               |
| any other key      | —                                                    | md-only   | Preserved byte-for-byte, in place.                                    |

### Label mapping (Apple → markdown)

| Apple label constant          | Markdown label |
|-------------------------------|----------------|
| `_$!<Mobile>!$_`              | `mobile`       |
| `iPhone`                      | `iphone`       |
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
| no label                      | bare list item |

On write-back, if an existing Apple label already maps to the same markdown label, the Apple label is left untouched (no label flapping). Custom labels keep their original Apple casing when a base record exists.

## 3. Sync-owned keys

```yaml
mdsync:
  id: <uuid v4, lowercase>     # required once linked
  status: detached              # optional; only when out of scope / unlinked
```

- Contains nothing device-specific and no timestamps, so files stay git-diff-clean and identical across devices (no iCloud conflict copies from metadata churn).
- `id` is also stamped on the Apple contact (iCloud underlying card) as a URL: label `mdsync`, value `x-mdsync:<uuid>`.
- A note with `type: person|organization` and **no** `mdsync.id` is a *markdown-only candidate*. It is never pushed to Contacts unless the user opts it in from the UI.
- Two files with the same `mdsync.id` (copied file) pause sync for that record until the user picks one.

> **Naming decision pending (review before M1):** the on-disk markers are `mdsync:` (frontmatter), `.mdsync/` (vault dir), and `x-mdsync:` (contact URL). Short but generic. Alternatives: `c2md` / `.c2md/` / `x-c2md:`, or `contacts2md`. Renaming after M1 ships requires a migration, so decide now.

## 4. Emission rules

- Fixed key order (as in §1). Unknown keys keep their original position and bytes; we patch only managed key spans.
- Multi-value fields are always emitted as **lists of single-key maps** (preserves order and duplicate labels; mbr treats order as preference).
- We **read** every form mbr accepts: map, list of `{label: value}`, bare strings, scalar, and `{label:, value:}`.
- Quote anything YAML could reinterpret: phone numbers, postcodes, dates, `yes/no/on/off/true/false/null`, leading `0`, leading `@`, `[`, `*`, `&`, `!`, `#`, `%`, `|`, `>`, `:`.
- `dates` is a map (mbr's documented form).
- Every emitted file is re-parsed before writing; if the decoded model differs from the intended one, the write is aborted and reported.
- Files with invalid YAML are never written to (mbr would ignore the whole frontmatter anyway).
- If emitted bytes equal what's on disk, no write happens.

## 5. Filenames and titles

- New files: `<default_folder>/<Title>.md`. NFC-normalized; `/ : \` and control chars replaced; leading dots stripped; max 120 chars.
- Collision: `Title (Company).md`, then `Title 2.md`.
- **Never renamed automatically.** mbr falls back to the filename stem when resolving links, so the original name keeps old links alive. UI offers an explicit "rename file to match title".
- `title` is markdown-owned. When Apple's name changes and the current title equals the previously generated title, the title is regenerated and the old title is appended to `aliases` as a plain string (keeps `[[Old Name]]` links resolving).
- Users may move files anywhere under the root. Identity is `mdsync.id`, never path.

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

- Apple stores relations as **names only**. On export we resolve the name to a record; if unique → `to: "[[<record title>]]"`, else plain string.
- On write-back the Apple relation name is the target's Apple display name.
- We never emit reverse edges (mbr derives them), `from:` edges, or the implicit `company` employer edge back to Apple. Extra edge attributes (e.g. `married: 1948-06-01`) are markdown-only and preserved.

## 7. Tags and groups

- A tag is **managed** iff it appears in the `groups` map in `.mdsync/config.yaml` (seeded from iCloud/Local groups at first import, e.g. `"Close Friends": close_friends`).
- Managed tags sync both ways (three-way set merge). Unmanaged tags never touch Apple.
- Tags follow mbr normalization: lowercase, spaces → `_`.
- New Apple groups appear as new managed tags. New groups from markdown are created only via the UI ("Create Apple group from tag").
- Contacts with no iCloud/Local card can't join groups; the tag stays in markdown and the UI shows a warning (no flapping).

## 8. Vault layout

```
~/Notes/Contacts/                 # root (user-chosen)
  .mdsync/                        # hidden from mbr
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
  include_contacts: []     # mdsync ids
  exclude_contacts: []
  markdown:
    include_paths: ["**"]
    exclude_paths: ["Templates/**"]
  require_tag: null
on_leave_scope: detach
```
