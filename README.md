# Contacts2MdSync

A macOS app (iPadOS/iOS later) that mirrors Apple Contacts into [mbr](https://zmre.github.io/mbr-markdown-browser/markdown/contacts/)-format markdown files and keeps the two in sync.

- One markdown file per contact under a folder you choose (e.g. `~/Notes/Contacts`).
- Move files into any subfolders you like; sync and `[[relationship]]` links keep working.
- Apple groups appear as tags.
- Two-way, field-level sync with automatic conflict resolution. You're asked only when both sides changed the same thing differently.
- Built to avoid duplicates, including unlinked iCloud and Google copies of the same person.

**Status:** M1 — one-way export (Apple Contacts → markdown) from the command line, with idempotent re-export, duplicate detection, and output validated against the real mbr. Two-way sync comes in M3. See [docs/plan.md](docs/plan.md).

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
nix flake check      # swift-format + mbr validation of the fixtures
```

Tests never touch your address book: they use `FakeContactStore`, `InMemoryVault` and temp folders.

Layout:

```
App/project.yml                  XcodeGen spec
App/Contacts2MdSync/             SwiftUI app shell, entitlements
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

M1 has a one-way export. The same commands run from the app binary (`Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync export …`, which keeps the app's Contacts permission) or, for development, `swift run contacts2md …`:

```sh
contacts2md status --root ~/Notes/Contacts                 # vault, notes, Contacts access, last export
contacts2md plan   --root ~/Notes/Contacts                 # dry run: what export would write
contacts2md export --root ~/Notes/Contacts                 # same as plan: nothing is written without --yes
contacts2md export --root ~/Notes/Contacts --yes           # write notes (Inbox/ by default, --default-folder X)
contacts2md export --root ~/Notes/Contacts --yes --stamp   # also stamp contacts with their sync id (backs up first)
```

Re-running `export --yes` only rewrites notes whose Apple data changed; you can move notes into any subfolder. Possible duplicates (e.g. the same person in iCloud and Google) get one note and a `WARNING duplicate` line. `--stamp` is the only option that writes to Contacts; it saves a vCard backup of all contacts first (last 10 kept in `~/Library/Application Support/Contacts2MdSync/backups/`).

Planned (M3): `contacts2md sync` for unattended two-way sync from launchd or cron; items needing a decision are skipped and printed as warnings.

Exit codes: 0 clean, 1 done but items await review, 2 Apple writes held back by the change limit (M3), 3 not configured, root missing or no Contacts permission, 4 safety breaker tripped (M3), 5 error, 64 bad command line. Details are in [docs/architecture.md §15](docs/architecture.md#15-headless-cli-cron--launchd).

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

The app is installed to `/Applications/Nix Apps/Contacts2MdSync.app`. For now `packages.default` builds from source with the system Xcode (`__noChroot`), so it needs `sandbox = false` or `relaxed` in your Nix config. Once signed and notarized releases exist, a pure `packages.release` that fetches the release zip will become the default.

Also available: `overlays.default` (adds `pkgs.contacts2mdsync`) and `nix flake check` (swift-format lint, plus validation of the fixture notes with the real mbr from `github:zmre/mbr-markdown-browser`, fetched from zmre.cachix.org).
