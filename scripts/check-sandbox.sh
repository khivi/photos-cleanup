#!/usr/bin/env bash
# App Sandbox checks for `.build/Photos Cleanup.app`.
#   scripts/check-sandbox.sh entitlements [--store]   fail on any entitlement outside the allowlist
#   scripts/check-sandbox.sh watch                     print sandbox denials until Ctrl-C
set -euo pipefail
cd "$(dirname "$0")/.."
app=".build/Photos Cleanup.app"

allowed=(
  com.apple.security.app-sandbox
  com.apple.security.files.user-selected.read-write
  com.apple.security.personal-information.photos-library
  com.apple.security.automation.apple-events
)
# The App Store rejects temporary exceptions; Show in Photos hides itself without this one.
homebrew_only=(com.apple.security.temporary-exception.apple-events)

case ${1:-} in
  entitlements)
    [ "${2:-}" = --store ] || allowed+=("${homebrew_only[@]}")
    keys=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - | sed -n 's/^\t<key>\(.*\)<\/key>$/\1/p')
    grep -qx com.apple.security.app-sandbox <<<"$keys" || { echo "not sandboxed: $app" >&2; exit 1; }
    bad=$(grep -vxF -f <(printf '%s\n' "${allowed[@]}") <<<"$keys" || true)
    [ -z "$bad" ] || { echo "entitlements not allowed${2:+ in $2}:" >&2; echo "$bad" >&2; exit 1; }
    echo "entitlements ok"
    ;;
  watch)
    log stream --style compact --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "PhotosCleanupApp"'
    ;;
  *) echo "usage: scripts/check-sandbox.sh entitlements [--store] | watch" >&2; exit 2 ;;
esac
