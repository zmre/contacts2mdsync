# Research Notes (2026-10-20)

Condensed findings that shaped the design. Items marked **[unverified]** come from documentation knowledge rather than headers/source and should be confirmed by the spikes in [spikes.md](spikes.md).

## mbr contact format

Source: zmre/mbr-markdown-browser @ `4636f9e`; docs at <https://zmre.github.io/mbr-markdown-browser/markdown/contacts/> and `/markdown/relationships/`.

- A note is a contact iff frontmatter `type` is `person` or `organization` (`contact.rs` 79–85). Folder and tags are irrelevant.
- All fields optional. Multi-value fields (`emails phones urls social im addresses`) accept map, list of single-key maps / bare strings, scalar, and an undocumented `{label, value}` form (`contact.rs` 545–620).
- `relationships: [{type, to|from, label?, …attrs}]`. Built-in types: parent/child, spouse, sibling, reports_to/manages, assistant/assists, employer/employee, colleague. Reverse edges derived automatically. Unknown types tolerated (directed, no reverse).
- **Link resolution** (`relationships.rs` `NameIndex::resolve` 1030–1056): `[[X]]` or bare names → global case-insensitive lookup by title, then alias, then filename stem. Not folder-scoped → **survives moves**. Values that look like paths (`/`, leading `.`, `.md`) resolve relative to the source note → break on moves. Ties → first URL by sort. Unresolved → warning, not failure.
- Title for matching: frontmatter `title` → first H1 → filename stem. Name built from `first_name/last_name` is display-only, **not** used for matching. → always write `title`.
- `company: "[[Org]]"` creates an implied employer edge; plain text does not.
- `tags`: list, flow array, or comma string; lowercased, spaces → `_`; slashes become URL segments with no hierarchy semantics.
- Unknown keys tolerated and shown in the info panel; a YAML parse error drops the whole frontmatter.
- `image`: path or URL; relative to the note's folder. No embedded images.
- Dot-directories hidden by mbr. Private keys (`emails phones urls social im addresses`) are stripped from `site.json`.

## Apple Contacts framework

Verified against Contacts headers in the macOS 26.5 and 27.0 SDKs (identical public API) unless marked.

- `CNContact.identifier`: "unique among contacts on the device"; persists across launches. Not cross-device. Changes on account re-add, iCloud toggle, restores, re-syncs **[unverified]**. **Spikes (2026-10-21):** iCloud card ids stayed stable through linking and through enabling a Google account. A card created locally in a Google container got a new id shortly afterwards (Google sync replaces it); updating an existing Google card did not change its id. A linked contact's unified id is **not** one of its card ids: it is a synthesized id without the `:ABPerson` suffix (a single card's unified id is the card id). Whether it changes on unlink and relink is untested.
- Contacts links same-name iCloud and Google cards automatically (spike: 1255 of 1353 Google cards linked within about 15 minutes of enabling the account). There is still no public link/unlink API.
- `unifyResults` defaults to YES. Underlying cards via `unifyResults = false`; map with `unifiedContactWithIdentifier:` / `isUnifiedWithContactWithIdentifier:`. There is **no** public linked-contacts predicate and **no** public API to link/unlink.
- Private TBD symbols exist (`CNContactExternalUUIDKey`, `CNContactModificationDateKey`, …) — not used (private API).
- No public modification date or etag. `CNContactDatesKey` is user dates, not metadata.
- `CNChangeHistoryFetchRequest` (10.15/13): `startingToken`, `additionalContactKeyDescriptors`, `shouldUnifyResults`, `includeGroupChanges`, `excludedTransactionAuthors`. Enumerator methods are `NS_SWIFT_UNAVAILABLE` in 27.0 → ObjC shim with `@try` (enumeration can raise). nil token → `DropEverything` + full snapshot. Errors 603 (expired), 604 (invalid anchor). No link/unlink events; deletes carry only ids; changes coalesced. **Spike S3:** a garbage token raised no error and no exception; it returned `DropEverything` plus the full snapshot, like a nil token. 604 was never observed and 603 is untested. Group add events arrived even with `includeGroupChanges = false`. `excludedTransactionAuthors` hides authored saves.
- `CNSaveRequest.transactionAuthor` (12/15), `shouldRefetchContacts` (12.3/15.4). "Last saved change wins."
- Reading an unfetched key raises `CNContactPropertyNotFetchedException` (ObjC exception → crash in Swift). Guard with `areKeysAvailable:`.
- Groups: `CNGroup {identifier, name}`; each in one container; Google CardDAV labels not exposed as groups (confirmed: the Gmail container reports 0 groups); Exchange rejects groups **[unverified]**. Members must be in the group's container. Subgroups macOS-only.
- `defaultContainerIdentifier` follows the user's Default Account; non-optional in Swift but may be empty without access.
- `CNContactNoteKey` needs `com.apple.developer.contacts.notes` (request form: developer.apple.com/contact/request/contact-note-field); without it, fetch fails with error 102 **[unverified on macOS Developer ID]**. **Spike S2 (un-entitled CLI, macOS 27):** no error 102; the fetch succeeds and `isKeyAvailable(CNContactNoteKey)` is false. Feature-detect with `isKeyAvailable`.
- **Cards with a note, without the notes entitlement (spike S15, 2026-10-24):** every `CNSaveRequest` that updates such a card fails with `NSCocoaErrorDomain` 134092 ("Unhandled error … occurred during faulting"): names, job title, adding an email, editing a phone in place, URLs and the stamp, group add and remove. Nothing is kept (no partial change) and the note is intact. Minimal keys, `shouldRefetchContacts = false`, a fresh store and fetching `CNContactNoteKey` all fail the same way, and the framework logs `CoreData: error … 134092` to stderr each time. Deletes work. Contacts.app scripting makes every one of these changes (one `UpdateContactEvent` on the target, note intact). Reports: forums 723695, FB23452026, mattt/iMCP#148.
- **`CNSaveRequest.removeMember(_:from:)` is a silent no-op on iCloud (S15):** the save succeeds and the card stays in the group, with or without a note, in every variant, still after 8 s. Contacts.app's `remove person id X from group id G` works.
- Contacts.app scripting ids (S12, S15): `person id` = `CNContact.identifier` of the underlying card; the `id` of a person's emails, phones and URLs = `CNLabeledValue.identifier` (`set value of phone id <id>` edits in place and keeps it; `make new email|url` returns the new id); `group id` accepts `CNGroup.identifier`. Contacts.sdef (macOS 27): person `title` (prefix), `first/middle/last name`, `suffix`, `nickname`, `maiden name`, `organization`, `department`, `job title`, `phonetic first/middle/last name` (no phonetic organization), `birth date` (a `date`), `image` (TIFF picture), `note`; elements `email`, `phone`, `url`, `address`, `related name`, `custom date`, `instant message` (`service type` enumerators for AIM, Facebook, Gadu Gadu, Google Talk, ICQ, Jabber, MSN, QQ, Skype, Yahoo; `service name` read-only), `social profile` (no `label`); commands `add … to`, `remove … from`, `make`, `delete`, `save`.
- **Instant messages by `id` do not resolve (S16, 2026-10-24, macOS 27):** `set user name of instant message id <CNLabeledValue.identifier> of person id P` fails with `-1728`. The same `id` form edits addresses, related names and social profiles in place (ids kept). The other edits of that batch were saved. Contacts.sdef: `instant message` (`az80`) inherits `contact info` (`label` `az18`, `value` `az17`, read-only `id` `ID  `). Its own properties are `service name` (`az81`, read-only text), `service type` (`az82`, enumeration `az84`: AIM `az85`, Gadu Gadu `az86`, Google Talk `az87`, ICQ `az88`, Jabber `az89`, MSN `az90`, QQ `az91`, Skype `az92`, Yahoo `az93`, Facebook `az94`) and `user name` (`az83`). The hidden legacy classes (`AIM Handle`, `Jabber handle`, …) are not used. The writer falls back to `first instant message of person id P whose user name = … and service type = …`. Whether Contacts.app resolves that is not yet verified (S16 step 4/4b re-run). If it does not, the IM edit is skipped and becomes unapplyable (architecture §6).
- `CNContactRelation` = name + label only (no contact reference).
- Images: `imageData` (original), `thumbnailImageData` (derived, read-only), `imageDataAvailable` (cheap check).
- Permissions: `NSContactsUsageDescription`; sandbox entitlement `com.apple.security.personal-information.addressbook`. iOS 18 adds `.limited` access + `ContactAccessButton` / `contactAccessPicker` (iOS only).
- Saving a mutable copy of a *unified* contact writes the change to every linked card (spike S4). Save underlying cards only.
- `CNContactStoreDidChangeNotification`: fires on changes from other stores, often multiple times; userInfo private → treat as a debounced signal.

## File access

- macOS sandbox: `NSOpenPanel` → `bookmarkData(options: .withSecurityScope)`; entitlements `files.user-selected.read-write`, `files.bookmarks.app-scope`; handle `isStale`.
- Watching: FSEvents with file-level events (recursive). `DispatchSource` vnode isn't recursive; `NSFilePresenter` only sees coordinated writers (vim, git, Obsidian aren't).
- iOS: folder via `UIDocumentPicker`, `NSFileCoordinator` for all I/O, `.icloud` placeholders, `startDownloadingUbiquitousItem`; no background folder watching.

## Prior art

- vdirsyncer / khard (pimutils): vCard dir ↔ CardDAV keyed on vCard UID with etag/hash status files — the model our base-hash design follows.
- obsidian-contacts: markdown contacts, no Apple sync.
- Recurring failure modes: duplicates from identifier remapping and add-instead-of-update; ping-pong loops from server normalization; multiple devices fighting over one folder.

## Nix / build

- nixpkgs (aarch64-darwin): `xcodegen` 2.44.1, `swiftlint` 0.65.1, `swift-format` 6.2.4, `xcbeautify` 3.2.1, `periphery` 3.8.0, `create-dmg` 1.2.2, `xcodes`, `rcodesign`. nixpkgs `xcodebuild` is xcbuild's reimplementation — use `/usr/bin/xcodebuild`.
- nix-darwin rsync-copies `Applications/` into `/Applications/Nix Apps` (signature preserved).
- Options for installable package: impure `xcodebuild` (`__noChroot`, needs sandbox off/relaxed — user's machine has sandbox=false); fetch notarized release zip (pure, stable TCC identity — long-term default); pure nixpkgs `swiftc` + `apple-sdk_26` (reproducible but lags Xcode, no `#Preview`, iOS impossible).
- Ad-hoc signatures change every build → Contacts permission re-prompts. Developer ID gives stable identity and is required for the notes entitlement.
