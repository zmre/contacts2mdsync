#!/usr/bin/env bash
# Verify the code signature of a built Contacts2MdSync.app.
#
#   scripts/verify-app.sh [options] <App.app> <entitlements-file>
#
# Shared by nix/package.nix (ad-hoc build) and scripts/release.sh (Developer
# ID build), so both check the same things:
#
#   - codesign --verify --deep --strict passes
#   - the hardened runtime flag is set
#   - every entitlement key AND every string value in <entitlements-file> is
#     in the signature. codesign exits 0 even when it cannot parse the file
#     (it then signs with none), so this is the only reliable check. Optional
#     entitlements (e.g. com.apple.security.automation.apple-events and the
#     com.apple.security.temporary-exception.apple-events array) are expected
#     exactly when the file has them
#   - the baseline keys the app cannot work without are present
#   - --forbid keys are absent (e.g. contacts.notes in an ad-hoc build)
#   - Info.plist has the usage strings the entitlements need
#     (NSContactsUsageDescription; NSAppleEventsUsageDescription when
#     automation.apple-events is entitled)
#   - --adhoc: signature is ad-hoc; --team T: Developer ID Application
#     authority, TeamIdentifier T and a secure timestamp
#
# Options:
#   --adhoc              expect an ad-hoc signature
#   --team <TEAMID>      expect a Developer ID signature from this team
#   --identifier <id>    expect this code signing identifier (bundle id)
#   --forbid <key>       entitlement that must NOT be in the signature (repeatable)
#
# Uses only /usr/bin tools; no network access.
set -euo pipefail

die() {
  echo "verify-app: error: $*" >&2
  exit 1
}

adhoc=0
team=""
identifier=""
forbid=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc) adhoc=1 ;;
    --team)
      team="${2:?--team needs a value}"
      shift
      ;;
    --identifier)
      identifier="${2:?--identifier needs a value}"
      shift
      ;;
    --forbid)
      forbid+=("${2:?--forbid needs a value}")
      shift
      ;;
    -h | --help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
      exit 0
      ;;
    --) shift; break ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
  shift
done
[[ $# -eq 2 ]] || die "usage: verify-app.sh [options] <App.app> <entitlements-file>"
app="$1"
entitlements="$2"
[[ -d "$app" ]] || die "app bundle not found: $app"
[[ -f "$entitlements" ]] || die "entitlements file not found: $entitlements"
[[ $adhoc -eq 1 && -n "$team" ]] && die "--adhoc and --team are mutually exclusive"

# Entitlements the app cannot work without, whatever the config.
baseline=(
  com.apple.security.app-sandbox
  com.apple.security.personal-information.addressbook
  com.apple.security.files.user-selected.read-write
  com.apple.security.files.bookmarks.app-scope
)

tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-app.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "verify-app: codesign --verify --deep --strict"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

# Captured to files first: piping codesign into `grep -q` lets grep exit
# early, codesign takes SIGPIPE and pipefail turns that into a failure.
/usr/bin/codesign -d --verbose=4 "$app" >"$tmp/info.txt" 2>&1
/usr/bin/codesign -d --entitlements - --xml "$app" >"$tmp/signed.plist" 2>/dev/null

grep -q 'flags=.*runtime' "$tmp/info.txt" || die "hardened runtime not enabled"

if [[ -n "$identifier" ]]; then
  grep -qx "Identifier=$identifier" "$tmp/info.txt" ||
    die "signing identifier is not $identifier ($(grep '^Identifier=' "$tmp/info.txt" || true))"
fi

if [[ $adhoc -eq 1 ]]; then
  grep -qx 'Signature=adhoc' "$tmp/info.txt" || die "expected an ad-hoc signature"
fi
if [[ -n "$team" ]]; then
  grep -q '^Authority=Developer ID Application: ' "$tmp/info.txt" ||
    die "not signed with a Developer ID Application certificate"
  grep -qx "TeamIdentifier=$team" "$tmp/info.txt" ||
    die "TeamIdentifier is not $team ($(grep '^TeamIdentifier=' "$tmp/info.txt" || true))"
  # A secure timestamp shows as "Timestamp=<date>"; an untimestamped
  # signature has only "Signed Time=" (notarization rejects those).
  grep -q '^Timestamp=' "$tmp/info.txt" || die "signature has no secure timestamp"
fi

has_key() { grep -qF "<key>$1</key>" "$tmp/signed.plist"; }

for key in "${baseline[@]}"; do
  has_key "$key" || die "entitlement $key missing from the signature"
done

# Every key and string in the source file. The file is an XML plist written by
# hand (one element per line), so a text scan is enough.
expected_keys="$(grep -o '<key>[^<]*</key>' "$entitlements" | sed 's:</\{0,1\}key>::g' || true)"
expected_strings="$(grep -o '<string>[^<]*</string>' "$entitlements" | sed 's:</\{0,1\}string>::g' || true)"
[[ -n "$expected_keys" ]] || die "no entitlement keys found in $entitlements"
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  has_key "$key" || die "entitlement $key (from $(basename "$entitlements")) missing from the signature"
done <<<"$expected_keys"
while IFS= read -r value; do
  [[ -z "$value" ]] && continue
  grep -qF "<string>$value</string>" "$tmp/signed.plist" ||
    die "entitlement value \"$value\" (from $(basename "$entitlements")) missing from the signature"
done <<<"$expected_strings"

for key in ${forbid[@]+"${forbid[@]}"}; do
  if has_key "$key"; then
    die "entitlement $key must not be in this build"
  fi
done

info_plist="$app/Contents/Info.plist"
usage() { /usr/bin/plutil -extract "$1" raw -o - "$info_plist" 2>/dev/null || true; }
[[ -n "$(usage NSContactsUsageDescription)" ]] ||
  die "Info.plist has no NSContactsUsageDescription"
if has_key com.apple.security.automation.apple-events; then
  [[ -n "$(usage NSAppleEventsUsageDescription)" ]] ||
    die "automation.apple-events is entitled but Info.plist has no NSAppleEventsUsageDescription"
fi

echo "verify-app: OK ($(grep -o '<key>[^<]*</key>' "$tmp/signed.plist" | wc -l | tr -d ' ') entitlements," \
  "$(if [[ $adhoc -eq 1 ]]; then echo ad-hoc; elif [[ -n "$team" ]]; then echo "Developer ID, team $team"; else echo signed; fi))"
