# Releasing Contacts2MdSync

Releases are Developer ID signed, notarized and stapled zips of `Contacts2MdSync.app`, published as GitHub release assets at
`https://github.com/zmre/contacts2mdsync/releases/download/v<version>/Contacts2MdSync-<version>.zip` (plus `.sha256`). The Nix package `packages.release` installs exactly that zip.

| Piece                              | What it does                                                         |
|------------------------------------|----------------------------------------------------------------------|
| `scripts/release.sh`               | Build, sign, verify, notarize, staple, zip. Local and CI.            |
| `scripts/release.sh --dry-run`     | Same pipeline, ad-hoc signed, never contacts Apple.                  |
| `scripts/verify-app.sh`            | Signature/entitlement checks shared with `nix/package.nix`.          |
| `.github/workflows/release.yml`    | On a `v*` tag: runs `release.sh`, creates the GitHub release.        |
| `.github/workflows/ci.yml`         | On push/PR: `nix flake check`, `just test`, `just lint`, shellcheck. |
| `scripts/update-release-nix.sh`    | Points `nix/release.json` at a published release.                   |
| `nix/release.nix`, `nix/release.json` | `packages.release` / `pkgs.contacts2mdsync-release`.              |

## Why signed builds

macOS ties Contacts access, Automation access (Apple Events to Contacts.app, used for notes sync), the sandboxed folder bookmark and the background sync agent to the app's code signature:

- **Ad-hoc builds** (`nix build .#default`, `just build`) get a new identity on every build. macOS forgets the Contacts and Automation grants, the saved folder may need choosing again, and a launchd agent started after a rebuild runs as an app that was never granted anything. Headless runs then exit 3.
- **Developer ID builds** carry a designated requirement of bundle id + team id. That stays the same across versions, so grants and the bookmark survive upgrades, and launchd/`SMAppService` background runs are attributed to the same app the user approved.
- **Notarized + stapled** apps open without Gatekeeper warnings, including offline, and the Nix release package is pure (no Xcode, no relaxed sandbox).

## One-time setup (your Mac)

1. **Team id.** Shown at <https://developer.apple.com/account> under Membership details, and in parentheses after the name of your signing identities:

   ```sh
   security find-identity -v -p codesigning | grep 'Developer ID Application'
   #   1) <sha1> "Developer ID Application: Your Name (ABCDE12345)"
   ```

   If several Developer ID identities are listed (e.g. a company and a personal team), `C2M_TEAM_ID` is what picks one.

2. **Developer ID Application certificate.** If the command above lists none: Xcode › Settings › Accounts › (team) › Manage Certificates › **+** › *Developer ID Application* (needs the Account Holder role), or create one at <https://developer.apple.com/account/resources/certificates> from a CSR made in Keychain Access. The private key must be in your login keychain.

3. **Notarization credentials** stored in the keychain under a profile name (the secret never touches the repo or the environment). Either an app-specific password:

   ```sh
   # make the password at https://account.apple.com > Sign-In and Security > App-Specific Passwords
   xcrun notarytool store-credentials c2m-notary --apple-id you@example.com --team-id ABCDE12345
   ```

   or an App Store Connect API key (App Store Connect › Users and Access › Integrations › Team Keys, role *Developer*; the `.p8` downloads once):

   ```sh
   xcrun notarytool store-credentials c2m-notary \
     --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

   Both prompt or read files interactively and store everything in the login keychain.

4. **Environment.** Neither value is secret; put them in your shell profile or an untracked `.envrc.local`:

   ```sh
   export C2M_TEAM_ID=ABCDE12345
   export C2M_NOTARY_PROFILE=c2m-notary
   ```

5. **Only for the notes entitlement** (`com.apple.developer.contacts.notes`, granted by Apple on request): add the *Contacts Notes* capability to the `com.zmre.contacts2mdsync` App ID, create a **Developer ID** provisioning profile for it, install it (double-click), then build with `NOTES_ENTITLEMENT=1 C2M_PROVISIONING_PROFILE="<profile name or UUID>"`. `App/project.yml` must map the profile for the ReleaseNotes config (see [project.yml requirements](#projectyml-requirements)).

## Releasing

1. Set the version: `MARKETING_VERSION` in `App/project.yml` (`X.Y.Z`). Commit.
2. Rehearse: `nix develop -c scripts/release.sh --dry-run`. This runs the whole pipeline with ad-hoc signing and writes `build/release/Contacts2MdSync-<version>-adhoc.zip`.
3. Release, either:
   - **CI** (preferred): `git tag v0.2.0 && git push origin v0.2.0`. `release.yml` builds, signs, notarizes, staples and creates the GitHub release with the zip and `.sha256`.
   - **Locally**: tag first (the version comes from the `vX.Y.Z` tag at `HEAD`), then

     ```sh
     nix develop -c scripts/release.sh
     gh release create v0.2.0 build/release/Contacts2MdSync-0.2.0.zip build/release/Contacts2MdSync-0.2.0.zip.sha256 \
       --title "Contacts2MdSync 0.2.0" --generate-notes
     ```

4. Update Nix: `scripts/update-release-nix.sh 0.2.0`, then check the package and commit `nix/release.json`:

   ```sh
   nix build path:.#release
   codesign --verify --deep --strict result/Applications/Contacts2MdSync.app
   spctl -a -t exec -vvv result/Applications/Contacts2MdSync.app   # source=Notarized Developer ID
   ```

   Never replace the assets of a published release: the hash in `nix/release.json` pins the exact zip.

Versions: `CFBundleShortVersionString` is the tag (or `MARKETING_VERSION`, or `C2M_VERSION`), and must be `X.Y` or `X.Y.Z`. `CFBundleVersion` is the commit count (`C2M_BUILD_NUMBER` overrides it), so it always increases. The script warns when the tag and `MARKETING_VERSION` differ.

### What `release.sh` does

1. Preflight: Xcode, `xcodegen`, `C2M_TEAM_ID`, a matching *Developer ID Application* identity, the notarytool profile (looked up in the keychain without reading the secret), a clean work tree (`C2M_ALLOW_DIRTY=1` overrides).
2. `xcodegen generate`, then seeds `Package.resolved` and archives the `Release` config (`ReleaseNotes` with `NOTES_ENTITLEMENT=1`) with `CODE_SIGN_IDENTITY="Developer ID Application"`, `DEVELOPMENT_TEAM=$C2M_TEAM_ID`, hardened runtime and `--timestamp`.
3. `xcodebuild -exportArchive` with a generated `ExportOptions.plist` (`method` `developer-id`, manual signing).
4. `scripts/verify-app.sh`: `codesign --verify --deep --strict`, hardened runtime, Developer ID authority, team id, secure timestamp, every key and value of the entitlements file present in the signature (so the Apple Events entitlements are expected exactly when the file has them), `contacts.notes` absent from `Release` builds, and the Info.plist usage strings (`NSAppleEventsUsageDescription` when `automation.apple-events` is entitled). It prints the signed entitlements.
5. `spctl -a -t exec -vvv` (informational before notarization), `ditto` zip, `notarytool submit --wait`, saves `notary-submit.json` and `notary-log.json`, fails on anything but `Accepted`.
6. `stapler staple` + `stapler validate`, verifies again, requires `spctl` to report `source=Notarized Developer ID`.
7. Re-zips the stapled app, writes `<zip>.sha256`, prints version, sha256 and the Nix SRI hash.

`--dry-run` signs ad-hoc, copies the app from the archive instead of exporting, and skips spctl, notarization and stapling. No Apple service is contacted.

All environment variables are listed in `scripts/release.sh --help`.

## CI secrets

Repository (or, better, a `release` environment with required reviewers) secrets used by `release.yml`:

| Secret                         | Value                                                               |
|--------------------------------|---------------------------------------------------------------------|
| `DEVELOPER_ID_P12_BASE64`      | base64 of the Developer ID Application certificate + private key (.p12) |
| `DEVELOPER_ID_P12_PASSWORD`    | the .p12 export password                                            |
| `APPLE_TEAM_ID`                | team id (not secret, but kept with the others)                      |
| `NOTARY_API_KEY_P8_BASE64`     | base64 of the App Store Connect API key `.p8`                       |
| `NOTARY_API_KEY_ID`            | its key id                                                          |
| `NOTARY_API_ISSUER_ID`         | its issuer id                                                       |
| `DEVELOPER_ID_PROFILE_BASE64`  | only with variable `NOTES_ENTITLEMENT=1`: base64 of the Developer ID `.provisionprofile` |

Repository variable (optional): `NOTES_ENTITLEMENT` = `1` to build the ReleaseNotes config.

Creating them without the values passing through your clipboard or shell history:

```sh
# Keychain Access > My Certificates > "Developer ID Application: ..." > Export > .p12 (set a password)
gh secret set DEVELOPER_ID_P12_BASE64 --env release < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD --env release           # prompts
gh secret set APPLE_TEAM_ID --env release --body ABCDE12345
gh secret set NOTARY_API_KEY_P8_BASE64 --env release < <(base64 -i AuthKey_XXXXXXXXXX.p8)
gh secret set NOTARY_API_KEY_ID --env release --body XXXXXXXXXX
gh secret set NOTARY_API_ISSUER_ID --env release                # prompts
rm DeveloperID.p12                                               # don't leave the exported key around
```

The workflow imports the .p12 into a temporary keychain with a random password, grants `codesign` access via `set-key-partition-list`, writes the `.p8` with mode 600 under `$RUNNER_TEMP`, and deletes both in an `always()` step. It only runs on tag pushes; protect `v*` tags with a ruleset so only you can create them.

### CI and Nix

`ci.yml` runs `nix flake check` with `sandbox = true`. The checks (swift-format, mbr fixture validation, nix-darwin module evaluation, `release.json` shape) are written for the full sandbox, and `nix flake check` only evaluates the packages, it doesn't build them. `just test` and `just lint` run from the dev shell against the runner's Xcode (`swiftlint` needs Xcode's `sourcekitd`, so it can't be a sandboxed check). A separate, non-blocking job runs `nix build .#default` with `sandbox = relaxed`, which the impure from-source package needs (`__noChroot`). It is informational because it builds as the `_nixbld` user against whatever Xcode the runner image has. The release workflow uses Nix only for the dev shell's `xcodegen`.

## project.yml requirements

- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `settings.base` (present). The script overrides both on the command line.
- For `NOTES_ENTITLEMENT=1` only, the app target's ReleaseNotes config needs the profile. It is passed as the custom setting `C2M_PROVISIONING_PROFILE` because a command-line `PROVISIONING_PROFILE_SPECIFIER` would also apply to the SwiftPM package targets and fail the build:

  ```yaml
  targets:
    Contacts2MdSync:
      settings:
        configs:
          ReleaseNotes:
            CODE_SIGN_ENTITLEMENTS: Contacts2MdSync/Contacts2MdSync.Release.entitlements
            PROVISIONING_PROFILE_SPECIFIER: "$(C2M_PROVISIONING_PROFILE)"
  ```

## Troubleshooting

**Notarization rejected (`status=Invalid`).** The script saves the log to `build/release/notary-log.json` and prints it. To fetch it again:

```sh
xcrun notarytool history --keychain-profile c2m-notary
xcrun notarytool log <submission-id> --keychain-profile c2m-notary
```

Typical causes: missing secure timestamp (no network to `timestamp.apple.com` during signing), hardened runtime off, `com.apple.security.get-task-allow` (a Debug build), or an unsigned nested binary.

**`notarytool submit` hangs or times out.** The submission keeps going server-side. Check `notarytool history`, then `notarytool wait <id>`, and staple manually: `xcrun stapler staple build/release/export/Contacts2MdSync.app`.

**Stapling fails (`Error 65` / `68`, "could not find ticket").** The ticket can take a minute to propagate after `Accepted`. Retry `xcrun stapler staple`. Check with `xcrun stapler validate <app>` and `spctl -a -t exec -vvv <app>`, which should say `source=Notarized Developer ID`.

**`errSecInternalComponent` or a keychain prompt during signing in CI.** The keychain is locked or the key's partition list is missing `codesign:`. The import step sets both. Make sure the .p12 contains the private key, not just the certificate.

**"ambiguous" identity / wrong team.** Several Developer ID identities match. Set `C2M_TEAM_ID` to the intended team's id.

**ReleaseNotes build: "requires a provisioning profile" / app killed at launch.** `com.apple.developer.contacts.notes` is a managed entitlement. It needs the Developer ID profile (see setup step 5) and the project.yml mapping above. Ad-hoc builds carrying it are killed by AMFI.

**Contacts or Automation access keeps being asked for, or is "on" but doesn't work.** This happens after switching between ad-hoc and Developer ID builds (or between the from-source and release Nix packages): the grant belongs to the old signature. Reset and open the app again:

```sh
tccutil reset AddressBook com.zmre.contacts2mdsync
tccutil reset AppleEvents com.zmre.contacts2mdsync
# or everything for the app:
tccutil reset All com.zmre.contacts2mdsync
codesign -dr - "/Applications/Nix Apps/Contacts2MdSync.app"   # the identity macOS now sees
```

**Background sync not running after an upgrade.** Check `launchctl print gui/$(id -u)/org.nixos.contacts2mdsync-sync` (nix-darwin agent) or `sfltool dumpbtm | grep -A5 contacts2mdsync` (agents registered from the app). With a Developer ID build the registration survives upgrades. After moving from an ad-hoc build, toggle background sync off and on in Settings once.

**`nix build .#release` hash mismatch.** The release asset changed after `nix/release.json` was written. Re-run `scripts/update-release-nix.sh <version>` only if the change was intended. Otherwise investigate before trusting the zip.

**Signature broken in the Nix store.** `nix/release.nix` unpacks with `unzip` and disables fixup, so nothing rewrites the bundle. `codesign --verify --deep --strict result/Applications/Contacts2MdSync.app` must pass. If it doesn't, check that the zip was made by `release.sh` (`ditto --norsrc`).
