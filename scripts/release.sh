#!/usr/bin/env bash
# Build a Developer ID signed, notarized and stapled Contacts2MdSync.app zip.
#
#   scripts/release.sh             # real release (needs the env below)
#   scripts/release.sh --dry-run   # same pipeline, ad-hoc signed, no Apple services
#
# Run it from the dev shell (`nix develop -c scripts/release.sh ...`) or any
# shell with xcodegen on PATH. Full procedure: docs/release.md.
#
# Pipeline: xcodegen -> xcodebuild archive -> export (method developer-id)
# -> verify (codesign --verify --deep --strict, entitlements, spctl) -> ditto
# zip -> notarytool submit --wait -> stapler staple -> verify again -> final
# zip + .sha256.
#
# Environment (real release):
#   C2M_TEAM_ID              Apple Developer team id (10 chars). Selects the
#                            "Developer ID Application: ... (TEAMID)" identity.
#   C2M_NOTARY_PROFILE       notarytool keychain profile name (from
#                            `xcrun notarytool store-credentials`), OR all of:
#   C2M_NOTARY_KEY           path to an App Store Connect API key (.p8)
#   C2M_NOTARY_KEY_ID        its key id
#   C2M_NOTARY_ISSUER        its issuer id (UUID)
#   C2M_NOTARY_KEYCHAIN      optional: keychain holding the profile
#   C2M_SIGNING_KEYCHAIN     optional: keychain holding the Developer ID
#                            identity (CI uses a temporary keychain)
#
# Optional (both modes):
#   NOTES_ENTITLEMENT=1      build config ReleaseNotes (Release entitlements +
#                            com.apple.developer.contacts.notes) instead of Release
#   C2M_PROVISIONING_PROFILE Developer ID provisioning profile (name or UUID);
#                            required with NOTES_ENTITLEMENT=1 for a real release
#   C2M_VERSION              override the version (default: the vX.Y.Z tag at
#                            HEAD, else MARKETING_VERSION in App/project.yml)
#   C2M_BUILD_NUMBER         override CFBundleVersion (default: commit count)
#   C2M_BUILD_DIR            output directory (default: build/release)
#   C2M_ALLOW_DIRTY=1        allow a real release from a dirty work tree
#
# Outputs (in C2M_BUILD_DIR):
#   Contacts2MdSync-<version>.zip         notarized + stapled (real)
#   Contacts2MdSync-<version>-adhoc.zip   ad-hoc signed (--dry-run)
#   <zip>.sha256                          `shasum -a 256` line
#   notary-*.json                         notarytool submission result and log
#
# Never prints secrets: credentials are only passed to notarytool, and only
# names/paths are echoed.
set -euo pipefail

readonly APP_NAME="Contacts2MdSync"
readonly BUNDLE_ID="com.zmre.contacts2mdsync"
readonly NOTES_KEY="com.apple.developer.contacts.notes"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run | -n) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

out="${C2M_BUILD_DIR:-$root/build/release}"
[[ "$out" == /* ]] || out="$root/$out"

# --- configuration ----------------------------------------------------------

if [[ "${NOTES_ENTITLEMENT:-0}" == 1 ]]; then
  config="ReleaseNotes"
  entitlements="$root/App/$APP_NAME/$APP_NAME.Release.entitlements"
else
  config="Release"
  entitlements="$root/App/$APP_NAME/$APP_NAME.Dev.entitlements"
fi
[[ -f "$entitlements" ]] || die "entitlements file missing: $entitlements"

# --- preflight --------------------------------------------------------------

for tool in /usr/bin/xcodebuild /usr/bin/xcrun /usr/bin/codesign /usr/bin/ditto \
  /usr/bin/shasum /usr/bin/plutil /usr/sbin/spctl /usr/bin/security; do
  [[ -x "$tool" ]] || die "$tool not found (this script needs macOS with Xcode)"
done
command -v xcodegen >/dev/null ||
  die "xcodegen not on PATH; run inside the dev shell: nix develop -c scripts/release.sh"
# nixpkgs' stdenv may export these; xcodebuild must use the selected Xcode.
unset DEVELOPER_DIR SDKROOT
/usr/bin/xcodebuild -version >/dev/null 2>&1 ||
  die "xcodebuild does not run; install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

notary_args=()
if [[ $dry_run -eq 0 ]]; then
  team="${C2M_TEAM_ID:-}"
  [[ -n "$team" ]] || die "C2M_TEAM_ID is not set. Find your team id at
  https://developer.apple.com/account (Membership details), or in the
  parentheses of: security find-identity -v -p codesigning | grep 'Developer ID Application'"
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "C2M_TEAM_ID must be 10 upper-case letters/digits"

  keychain_args=()
  [[ -n "${C2M_SIGNING_KEYCHAIN:-}" ]] && keychain_args=("$C2M_SIGNING_KEYCHAIN")
  if ! /usr/bin/security find-identity -v -p codesigning ${keychain_args[@]+"${keychain_args[@]}"} |
    grep -q "\"Developer ID Application: .* ($team)\""; then
    die "no valid 'Developer ID Application' identity for team $team in the keychain.
  Create one at https://developer.apple.com/account/resources/certificates
  (type: Developer ID Application) or in Xcode > Settings > Accounts >
  Manage Certificates, and make sure its private key is in your login keychain."
  fi

  if [[ -n "${C2M_NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$C2M_NOTARY_PROFILE")
    if [[ -n "${C2M_NOTARY_KEYCHAIN:-}" ]]; then
      notary_args+=(--keychain "$C2M_NOTARY_KEYCHAIN")
    fi
    # notarytool keeps profiles as generic passwords under this service and
    # account; look the item up (attributes only, never the secret) so a typo
    # fails now instead of after a full build.
    if ! /usr/bin/security find-generic-password -s com.apple.gke.notary.tool \
      -a "com.apple.gke.notary.tool.saved-creds.$C2M_NOTARY_PROFILE" \
      ${C2M_NOTARY_KEYCHAIN:+"$C2M_NOTARY_KEYCHAIN"} >/dev/null 2>&1; then
      die "notarytool keychain profile '$C2M_NOTARY_PROFILE' not found. Create it once with:
  xcrun notarytool store-credentials \"$C2M_NOTARY_PROFILE\" --apple-id <you@example.com> --team-id $team
  (it prompts for an app-specific password from https://account.apple.com), or set
  C2M_NOTARY_KEY / C2M_NOTARY_KEY_ID / C2M_NOTARY_ISSUER for an API key."
    fi
  elif [[ -n "${C2M_NOTARY_KEY:-}${C2M_NOTARY_KEY_ID:-}${C2M_NOTARY_ISSUER:-}" ]]; then
    [[ -n "${C2M_NOTARY_KEY:-}" && -n "${C2M_NOTARY_KEY_ID:-}" && -n "${C2M_NOTARY_ISSUER:-}" ]] ||
      die "API key notarization needs all of C2M_NOTARY_KEY, C2M_NOTARY_KEY_ID and C2M_NOTARY_ISSUER"
    [[ -f "$C2M_NOTARY_KEY" ]] || die "C2M_NOTARY_KEY does not point to a file"
    notary_args=(--key "$C2M_NOTARY_KEY" --key-id "$C2M_NOTARY_KEY_ID" --issuer "$C2M_NOTARY_ISSUER")
  else
    die "no notarization credentials. Set C2M_NOTARY_PROFILE (see docs/release.md,
  'One-time setup') or C2M_NOTARY_KEY + C2M_NOTARY_KEY_ID + C2M_NOTARY_ISSUER."
  fi

  if [[ "$config" == ReleaseNotes && -z "${C2M_PROVISIONING_PROFILE:-}" ]]; then
    die "NOTES_ENTITLEMENT=1 needs C2M_PROVISIONING_PROFILE: $NOTES_KEY is a managed
  entitlement and only works with a Developer ID provisioning profile that grants it."
  fi

  if [[ -n "$(git status --porcelain 2>/dev/null)" && "${C2M_ALLOW_DIRTY:-0}" != 1 ]]; then
    die "work tree has uncommitted changes; commit them or set C2M_ALLOW_DIRTY=1"
  fi
else
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && warn "work tree is dirty (fine for --dry-run)"
fi

# --- version ----------------------------------------------------------------

project_version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' App/project.yml | head -n1)"
tag="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
if [[ -n "${C2M_VERSION:-}" ]]; then
  version="$C2M_VERSION"
elif [[ -n "$tag" ]]; then
  version="${tag#v}"
elif [[ -n "$project_version" ]]; then
  version="$project_version"
else
  die "no version: tag HEAD as vX.Y.Z, set MARKETING_VERSION in App/project.yml, or set C2M_VERSION"
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
  die "version '$version' must be X.Y or X.Y.Z (CFBundleShortVersionString)"
if [[ -n "$project_version" && "$project_version" != "$version" ]]; then
  warn "building $version but App/project.yml MARKETING_VERSION is $project_version; bump it to match"
fi
build_number="${C2M_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "C2M_BUILD_NUMBER must be a positive integer"
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" == true && -z "${C2M_BUILD_NUMBER:-}" ]]; then
  warn "shallow clone: commit count ($build_number) is not a reliable build number; fetch full history or set C2M_BUILD_NUMBER"
fi

if [[ $dry_run -eq 1 ]]; then
  zip_name="$APP_NAME-$version-adhoc.zip"
  mode="DRY RUN (ad-hoc signed, not notarized)"
else
  zip_name="$APP_NAME-$version.zip"
  mode="Developer ID, team $team, notarized"
fi

say "$APP_NAME $version (build $build_number), config $config, $mode"
say "output: $out"

# --- build ------------------------------------------------------------------

rm -rf "$out"
mkdir -p "$out"
archive="$out/$APP_NAME.xcarchive"
export_dir="$out/export"
app="$export_dir/$APP_NAME.app"

say "xcodegen"
(cd App && xcodegen generate --quiet)
# Seed the generated workspace with the package's committed pins so SwiftPM
# resolves exactly those versions (-onlyUsePackageVersionsFromResolvedFile).
resolved="App/$APP_NAME.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved"
cp Packages/Contacts2MdSyncKit/Package.resolved "$resolved/Package.resolved"

# Signing overrides. Command-line build settings apply to every target,
# including the SwiftPM package targets; those link statically and ignore
# CODE_SIGN_*, but PROVISIONING_PROFILE_SPECIFIER would make them fail, so the
# profile is passed as the custom setting C2M_PROVISIONING_PROFILE, which only
# the app target's ReleaseNotes config maps (see docs/release.md).
sign_settings=(CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES)
if [[ $dry_run -eq 1 ]]; then
  sign_settings+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= "OTHER_CODE_SIGN_FLAGS=--timestamp=none")
else
  codesign_flags="--timestamp"
  if [[ -n "${C2M_SIGNING_KEYCHAIN:-}" ]]; then
    codesign_flags+=" --keychain $C2M_SIGNING_KEYCHAIN"
  fi
  sign_settings+=(
    "CODE_SIGN_IDENTITY=Developer ID Application"
    "DEVELOPMENT_TEAM=$team"
    "OTHER_CODE_SIGN_FLAGS=$codesign_flags"
  )
  if [[ -n "${C2M_PROVISIONING_PROFILE:-}" ]]; then
    sign_settings+=("C2M_PROVISIONING_PROFILE=$C2M_PROVISIONING_PROFILE")
  fi
fi

pretty=(cat)
command -v xcbeautify >/dev/null && pretty=(xcbeautify --quiet)

say "xcodebuild archive"
/usr/bin/xcodebuild \
  -project "App/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$config" \
  -destination "generic/platform=macOS" \
  -archivePath "$archive" \
  -derivedDataPath "$out/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  "MARKETING_VERSION=$version" \
  "CURRENT_PROJECT_VERSION=$build_number" \
  "${sign_settings[@]}" \
  archive 2>&1 | tee "$out/xcodebuild-archive.log" | "${pretty[@]}"

archived_app="$archive/Products/Applications/$APP_NAME.app"
[[ -d "$archived_app" ]] || die "archive has no $APP_NAME.app (see $out/xcodebuild-archive.log)"

mkdir -p "$export_dir"
if [[ $dry_run -eq 1 ]]; then
  # Developer ID export needs the certificate; the archived app is already
  # ad-hoc signed with the right entitlements, so copy it as is.
  say "export (dry run: copy the ad-hoc signed app from the archive)"
  /usr/bin/ditto "$archived_app" "$app"
else
  say "xcodebuild -exportArchive (method developer-id)"
  export_options="$out/ExportOptions.plist"
  profiles=""
  if [[ -n "${C2M_PROVISIONING_PROFILE:-}" ]]; then
    profiles="	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key>
		<string>$(xml_escape "$C2M_PROVISIONING_PROFILE")</string>
	</dict>"
  fi
  cat >"$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
$profiles
</dict>
</plist>
EOF
  /usr/bin/plutil -lint "$export_options" >/dev/null || die "generated $export_options is invalid"
  /usr/bin/xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options" 2>&1 | tee "$out/xcodebuild-export.log" | "${pretty[@]}"
  [[ -d "$app" ]] || die "export produced no $APP_NAME.app (see $out/xcodebuild-export.log)"
fi

# --- verify -----------------------------------------------------------------

verify_args=(--identifier "$BUNDLE_ID")
if [[ $dry_run -eq 1 ]]; then
  verify_args+=(--adhoc)
else
  verify_args+=(--team "$team")
fi
if [[ "$config" == Release ]]; then
  verify_args+=(--forbid "$NOTES_KEY")
elif [[ $dry_run -eq 1 ]]; then
  warn "ad-hoc build carries $NOTES_KEY: AMFI kills it at launch without a provisioning profile"
fi

say "verify signature and entitlements"
bash "$root/scripts/verify-app.sh" "${verify_args[@]}" "$app" "$entitlements"
say "signed entitlements:"
/usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null | /usr/bin/plutil -p - | sed "s/^/    /"

# --- zip, notarize, staple ----------------------------------------------------

# --norsrc: no AppleDouble/xattr entries, so the zip unpacks identically with
# Info-ZIP unzip (nix/release.nix). The stapled ticket lives in
# Contents/CodeResources, a regular file, so nothing is lost.
make_zip() { /usr/bin/ditto -c -k --norsrc --keepParent "$app" "$1"; }

zip="$out/$zip_name"
if [[ $dry_run -eq 1 ]]; then
  say "spctl (skipped in --dry-run: ad-hoc code is always rejected)"
  say "notarize + staple (skipped in --dry-run)"
  make_zip "$zip"
else
  say "spctl before notarization (expected: rejected, 'Unnotarized Developer ID')"
  /usr/sbin/spctl -a -t exec -vvv "$app" 2>&1 | sed 's/^/    /' || true

  upload="$out/$APP_NAME-$version-notarize-upload.zip"
  make_zip "$upload"

  say "notarytool submit --wait (this usually takes 1-15 minutes)"
  set +e
  /usr/bin/xcrun notarytool submit "$upload" "${notary_args[@]}" --wait \
    --output-format json >"$out/notary-submit.json"
  submit_rc=$?
  set -e
  status="$(/usr/bin/plutil -extract status raw -o - "$out/notary-submit.json" 2>/dev/null || echo unknown)"
  submission="$(/usr/bin/plutil -extract id raw -o - "$out/notary-submit.json" 2>/dev/null || true)"
  say "notarization: status=$status id=${submission:-?}"
  if [[ -n "$submission" ]]; then
    /usr/bin/xcrun notarytool log "$submission" "${notary_args[@]}" "$out/notary-log.json" >/dev/null 2>&1 ||
      warn "could not fetch the notarization log (retry: xcrun notarytool log $submission ...)"
  fi
  if [[ $submit_rc -ne 0 || "$status" != Accepted ]]; then
    [[ -f "$out/notary-log.json" ]] && sed 's/^/    /' "$out/notary-log.json" >&2
    die "notarization failed (status $status). Log: $out/notary-log.json; see docs/release.md#troubleshooting"
  fi
  if [[ -f "$out/notary-log.json" ]] && grep -q '"issues" *: *\[ *{' "$out/notary-log.json"; then
    warn "notarization accepted with issues; review $out/notary-log.json"
  fi
  rm -f "$upload"

  say "stapler staple"
  /usr/bin/xcrun stapler staple "$app"
  /usr/bin/xcrun stapler validate "$app"

  say "verify stapled app"
  bash "$root/scripts/verify-app.sh" "${verify_args[@]}" "$app" "$entitlements"
  /usr/sbin/spctl -a -t exec -vvv "$app" 2>&1 | tee "$out/spctl.txt" | sed 's/^/    /'
  grep -q 'source=Notarized Developer ID' "$out/spctl.txt" ||
    die "Gatekeeper does not accept the stapled app as Notarized Developer ID (see $out/spctl.txt)"

  make_zip "$zip"
fi

(cd "$out" && /usr/bin/shasum -a 256 "$zip_name" >"$zip_name.sha256")
sha256="$(cut -d' ' -f1 "$zip.sha256")"
sri="sha256-$(/usr/bin/openssl dgst -sha256 -binary "$zip" | /usr/bin/base64)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$version"
    echo "build=$build_number"
    echo "zip=$zip"
    echo "sha256_file=$zip.sha256"
    echo "sha256=$sha256"
  } >>"$GITHUB_OUTPUT"
fi

echo
say "done: $mode"
echo "  version   $version (build $build_number, config $config)"
echo "  zip       $zip"
echo "  sha256    $sha256"
echo "  nix hash  $sri"
if [[ $dry_run -eq 0 ]]; then
  echo
  echo "  Publish: tag v$version and push it (CI releases), or upload the zip and"
  echo "  .sha256 to the v$version GitHub release, then: scripts/update-release-nix.sh $version"
fi
