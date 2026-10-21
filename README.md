# Contacts2MdSync

A macOS app (iPadOS/iOS later) that mirrors Apple Contacts into [mbr](https://zmre.github.io/mbr-markdown-browser/markdown/contacts/)-format markdown files and keeps the two in sync.

- One markdown file per contact under a folder you choose (e.g. `~/Notes/Contacts`).
- Move files into any subfolders you like; sync and `[[relationship]]` links keep working.
- Apple groups appear as tags.
- Two-way, field-level sync with automatic conflict resolution. You're asked only when both sides changed the same thing differently.
- Built to avoid duplicates, including unlinked iCloud and Google copies of the same person.

**Status:** M0 (scaffolding). Nothing syncs yet. See [docs/plan.md](docs/plan.md).

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
```

Layout:

```
App/project.yml                  XcodeGen spec
App/Contacts2MdSync/             SwiftUI app shell, entitlements
Packages/Contacts2MdSyncKit/     all sync logic (headless, testable)
nix/                             package + nix-darwin module
docs/                            design
```

Build configs:

| Config        | Entitlements                         | Use                                                  |
|---------------|--------------------------------------|------------------------------------------------------|
| Debug         | Dev                                  | daily development                                    |
| Release       | Dev                                  | `nix build`, ad-hoc signed                           |
| ReleaseNotes  | Release (adds `contacts.notes`)      | Developer ID builds, once Apple grants the entitlement |

Ad-hoc builds get a new code signature every time, so macOS asks for Contacts permission again after each rebuild. Use Xcode Debug builds signed with your team for day-to-day work.

## Command line (planned, M3)

Once the app is set up and the first sync is done, you can sync without the GUI, for example from launchd or cron:

```sh
contacts2md status     # configured? last sync? pending review?
contacts2md plan       # dry run
contacts2md sync       # unattended sync; items needing a decision are skipped and printed as warnings
```

Exit codes: 0 clean, 1 synced but items await review, 2 Apple writes held back by the change limit, 3 not configured or no permission, 4 safety breaker tripped, 5 error. Details are in [docs/architecture.md §15](docs/architecture.md#15-headless-cli-cron--launchd).

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

Also available: `overlays.default` (adds `pkgs.contacts2mdsync`) and `nix flake check` (swift-format lint).
