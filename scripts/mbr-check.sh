#!/usr/bin/env bash
# Validates exported contact notes with the real mbr (spike S10).
#
# mbr has no batch "lint" mode, but its server reports per-page problems at
# `<page>/errors.json` (the data behind the page-problems panel). This script
# serves a temporary copy of the notes with `mbr -s` on a random local port,
# fetches errors.json for every note, and:
#   - FAILS on `contact_data_problem` and `frontmatter_parse_error`
#     (a note mbr cannot read as we intended), or a page mbr cannot serve;
#   - PRINTS `ambiguous_relationship_endpoint` / `relationship_cycle` as
#     warnings (the fixtures deliberately contain two different John Smiths).
#
# Usage: scripts/mbr-check.sh [notes-dir]      (default: the export goldens)
#        MBR=/path/to/mbr scripts/mbr-check.sh
set -euo pipefail

notes=${1:-Packages/Contacts2MdSyncKit/Tests/SyncEngineTests/Fixtures/export}
mbr=${MBR:-mbr}
command -v "$mbr" >/dev/null || {
  echo "mbr-check: '$mbr' not found; set MBR=/path/to/mbr or install mbr (github:zmre/mbr-markdown-browser)" >&2
  exit 2
}

work=$(mktemp -d)
log="$work.log"
pid=""
cleanup() {
  [[ -n $pid ]] && kill "$pid" 2>/dev/null || true
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work" "$log"
}
trap cleanup EXIT
cp -R "$notes/." "$work/"
chmod -R u+w "$work" # copies out of the Nix store are read-only

port=$((20000 + RANDOM % 20000))
"$mbr" -s --host 127.0.0.1 -p "$port" "$work" >"$log" 2>&1 &
pid=$!
base="http://127.0.0.1:$port"
for _ in $(seq 1 50); do
  curl -fsS -o /dev/null "$base/" 2>/dev/null && break
  sleep 0.2
done
curl -fsS -o /dev/null "$base/" || { echo "mbr-check: mbr server did not start:" >&2; cat "$log" >&2; exit 2; }

# Percent-encode each path segment, keeping the slashes.
urlpath() { jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")'; }

failures=0
warnings=0
checked=0
while IFS= read -r -d '' file; do
  rel=${file#"$work/"}
  page=${rel%.md}
  json=$(curl -fsS "$base/$(urlpath "$page")/errors.json") || {
    echo "FAIL  $rel: mbr could not serve the page"
    failures=$((failures + 1))
    continue
  }
  checked=$((checked + 1))
  while IFS= read -r problem; do
    [[ -z $problem ]] && continue
    echo "FAIL  $rel: $problem"
    failures=$((failures + 1))
  done < <(jq -r '.errors[]? | select(.type == "contact_data_problem" or .type == "frontmatter_parse_error")
                  | "\(.type): \(.field // "") \(.message // "")"' <<<"$json")
  while IFS= read -r problem; do
    [[ -z $problem ]] && continue
    echo "warn  $rel: $problem"
    warnings=$((warnings + 1))
  done < <(jq -r '.errors[]? | select(.type == "ambiguous_relationship_endpoint" or .type == "relationship_cycle")
                  | "\(.type): \(. | del(.type) | tostring)"' <<<"$json")
done < <(find "$work" -name '*.md' -not -path '*/.*' -print0)

echo "mbr-check: $checked notes checked with $("$mbr" --version 2>/dev/null || echo mbr), $failures problems, $warnings warnings"
[[ $checked -gt 0 && $failures -eq 0 ]]
