# Contacts2MdSync

A macOS app (iPadOS/iOS later) that mirrors Apple Contacts into [mbr](https://zmre.github.io/mbr-markdown-browser/markdown/contacts/)-format markdown files and keeps the two in sync.

- One markdown file per contact under a folder you choose (e.g. `~/Notes/Contacts`).
- Move files into any subfolders you like; sync and `[[relationship]]` links keep working.
- Apple groups appear as tags.
- Two-way, field-level sync with automatic conflict resolution. You're asked only when both sides changed the same thing differently.
- Built to avoid duplicates, including unlinked iCloud and Google copies of the same person.

**Status:** M2 — one-way export (Apple Contacts → markdown) from a minimal setup window or the command line: adoption of your existing person notes, duplicate detection with recorded decisions, moves, per-device SQLite state, output validated against the real mbr. Two-way sync comes in M3. See [docs/plan.md](docs/plan.md).

## Docs

| Doc                                              | Contents                                         |
|--------------------------------------------------|--------------------------------------------------|
| [docs/plan.md](docs/plan.md)                     | Decisions, milestones, verification              |
| [docs/architecture.md](docs/architecture.md)     | Sync engine design: identity, merge, safety rails |
| [docs/markdown-schema.md](docs/markdown-schema.md) | Exact file format and field mapping            |
| [docs/ui.md](docs/ui.md)                         | Screen sketches                                  |
| [docs/spikes.md](docs/spikes.md)                 | Open technical questions to settle before M1     |
| [docs/research.md](docs/research.md)             | Platform facts the design relies on              |

## Development

Requires Xcode (at `/usr/bin/xcodebuild`) and Nix with flakes. Every other tool comes from the dev shell.

```sh
nix develop          # xcodegen, swiftlint, swift-format, xcbeautify, periphery, create-dmg, just
just gen             # generate App/Contacts2MdSync.xcodeproj from App/project.yml (not committed)
just build           # Debug build
just run             # build + launch
just test            # Swift package tests
just lint            # swiftlint --strict + swift-format lint
just fmt             # format in place
just update-goldens  # rewrite golden files from current output (review the diff)
just mbr-check       # validate the exported fixture notes with the real mbr
just cli plan --root ~/Notes/Contacts      # dev CLI (reads your real Contacts!)
just app-cli status                        # CLI through the Debug app binary (app's grant + saved folder)
nix flake check      # swift-format + mbr validation of the fixtures
```

Tests never touch your address book: they use `FakeContactStore`, `InMemoryVault` and temp folders.

Layout:

```
App/project.yml                  XcodeGen spec
App/Contacts2MdSync/             SwiftUI app: setup/overview window, entitlements
Packages/Contacts2MdSyncKit/     all sync logic (headless, testable)
nix/                             package + nix-darwin module
scripts/mbr-check.sh             validate notes with the real mbr
docs/                            design
```

Build configs:

| Config        | Entitlements                         | Use                                                  |
|---------------|--------------------------------------|------------------------------------------------------|
| Debug         | Dev                                  | daily development                                    |
| Release       | Dev                                  | `nix build`, ad-hoc signed                           |
| ReleaseNotes  | Release (adds `contacts.notes`)      | Developer ID builds, once Apple grants the entitlement |

Ad-hoc builds get a new code signature every time, so macOS asks for Contacts permission again after each rebuild. Use Xcode Debug builds signed with your team for day-to-day work.

## Command line

The same commands run from the app binary (`Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync <command>`, or `contacts2md` from the nix package, which execs it) or, for development, `swift run contacts2md …`. Run through the app binary, they use the app's Contacts permission and the notes folder chosen in the app, so `--root` can be left out.

```sh
contacts2md status                          # vault, notes, Contacts access, last export, pending reviews
contacts2md plan                            # dry run: what export would write
contacts2md export --yes                    # write notes (existing notes are backed up first)
contacts2md export --yes --backup           # … and save a vCard backup of all contacts
contacts2md export --yes --stamp            # … and stamp contacts with their sync id (the only Contacts write)
contacts2md review list                     # items that need a decision, with ids and choices
contacts2md review decide dup-1a2b3c4d5e distinct
contacts2md review adopt-all                # adopt every pending one-to-one note match
contacts2md plan --root ~/Notes/Contacts    # any command: use another folder
```

- Existing hand-written `type: person|organization` notes are matched to contacts. On the first export, unambiguous email/phone + name matches are adopted (the note gains a `c2mdsync.id` and Apple's data; your text, title, filename and extra values stay). Anything less certain is listed for review and blocks creating a duplicate.
- Notes can be moved into any subfolder; they are updated in place.
- Possible duplicates (e.g. the same person in iCloud and Google, not linked) get one note and a `WARNING duplicate` line until you decide.
- Decisions are stored in the notes folder (`.c2mdsync/devices/<device>/decisions.jsonl`) so every Mac sees them.

Exit codes: 0 clean, 1 done but items await review, 2 Apple writes held back by the change limit (M3), 3 not configured, folder or Contacts permission missing, 4 safety breaker tripped (M3), 5 error, 64 bad command line. Details are in [docs/architecture.md §15](docs/architecture.md#15-headless-cli-cron--launchd).

## Trying a real export safely

Nothing below writes to Apple Contacts: stamping is off unless you pass `--stamp`.

1. **Back up your notes folder** (Time Machine, or `cp -R ~/Notes ~/Notes-backup`). For a first look, choose an empty folder such as `~/Notes/Contacts`; to see how your existing person notes are matched, use a copy of your notes.
2. **Build and open the app**: `nix build path:.#default && open result/Applications/Contacts2MdSync.app` (or `nix develop -c just run`).
3. In the window: **1 Access** → *Allow Access…*; **2 Folders** → *Choose…* the notes root and set *New contacts go in* (default `Inbox`); **3 Preview** → check the counts (new files, notes to adopt, possible duplicates and matches). Preview writes nothing to your notes.
4. **4 Confirm** → *Run First Export*. A vCard backup of all contacts and copies of every note it rewrites are saved first; the paths are shown afterwards.
5. Decide pending items from Terminal with the app binary, then export again:

   ```sh
   C2M=result/bin/contacts2md          # or …/Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync
   $C2M status
   $C2M review list
   $C2M review decide <item-id> <choice>
   $C2M plan                           # check the effect
   $C2M export --yes
   ```

Where things are (the app is sandboxed): state, backups and the folder bookmark live in `~/Library/Containers/com.zmre.contacts2mdsync/Data/Library/Application Support/Contacts2MdSync/` (`<vault id>/backups/` holds `contacts-*.vcf` and `notes-*/`). To undo an export: delete the created notes (listed in the output), restore adopted notes from `notes-*/`, and remove `.c2mdsync/` from the notes folder.

Caveats: ad-hoc builds (`nix build`, `just build`) get a new code signature on every rebuild, so macOS asks for Contacts access again and the saved folder may need choosing again in the app. When run from Terminal, macOS may attribute Contacts access to your terminal app; if the CLI exits 3 with "Contacts access has not been granted", grant it in System Settings › Privacy & Security › Contacts. launchd/cron runs are untested (spike S11).

## Installing with nix-darwin

```nix
{
  inputs.contacts2mdsync.url = "github:zmre/mbr-apple-contact-sync";

  outputs = { nix-darwin, contacts2mdsync, ... }: {
    darwinConfigurations.myMac = nix-darwin.lib.darwinSystem {
      modules = [
        contacts2mdsync.darwinModules.default
        {
          programs.contacts2mdsync.enable = true;
          # planned (M5): hourly headless sync via a launchd user agent
          # programs.contacts2mdsync.schedule = { enable = true; interval = 3600; };
        }
      ];
    };
  };
}
```

The app is installed to `/Applications/Nix Apps/Contacts2MdSync.app`, and `contacts2md` (a wrapper that execs the app binary) is put on your `PATH`. For now `packages.default` builds from source with the system Xcode (`__noChroot`), so it needs `sandbox = false` or `relaxed` in your Nix config. Once signed and notarized releases exist, a pure `packages.release` that fetches the release zip will become the default.

Also available: `overlays.default` (adds `pkgs.contacts2mdsync`) and `nix flake check` (swift-format lint, plus validation of the fixture notes with the real mbr from `github:zmre/mbr-markdown-browser`, fetched from zmre.cachix.org).
