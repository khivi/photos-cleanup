#!/usr/bin/env bash
# App Sandbox checks for `.build/Photos Cleanup.app`.
#   scripts/check-sandbox.sh entitlements [--store]   fail on any entitlement outside the allowlist
#   scripts/check-sandbox.sh watch                     print sandbox denials until Ctrl-C
#   scripts/check-sandbox.sh smoke                     demo smoke; fail on any denial not in `expected`
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
# From the provisioning profile; `scripts/app.sh store` adds them.
store_only=(com.apple.application-identifier com.apple.developer.team-identifier)
# Denials from system frameworks the app loads, seen with every feature still working.
expected='vfs.disk-space|AppleNVMeEANUC|syspolicy.exec'
predicate='sender == "Sandbox" AND eventMessage CONTAINS "PhotosCleanupApp"'

case ${1:-} in
  entitlements)
    if [ "${2:-}" = --store ]; then allowed+=("${store_only[@]}"); else allowed+=("${homebrew_only[@]}"); fi
    keys=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - | sed -n 's/^\t<key>\(.*\)<\/key>$/\1/p')
    grep -qx com.apple.security.app-sandbox <<<"$keys" || { echo "not sandboxed: $app" >&2; exit 1; }
    bad=$(grep -vxF -f <(printf '%s\n' "${allowed[@]}") <<<"$keys" || true)
    [ -z "$bad" ] || { echo "entitlements not allowed${2:+ in $2}:" >&2; echo "$bad" >&2; exit 1; }
    echo "entitlements ok"
    ;;
  watch)
    log stream --style compact --predicate "$predicate"
    ;;
  smoke)
    out=$(mktemp)
    log stream --style compact --predicate "$predicate" >"$out" 2>&1 &
    stream=$!
    trap 'kill "$stream" 2>/dev/null || true' EXIT
    sleep 2
    scripts/app.sh demo smoke
    sleep 2
    bad=$(grep 'deny(' "$out" | grep -vE "$expected" || true)
    [ -z "$bad" ] || { echo "sandbox denials:" >&2; echo "$bad" >&2; exit 1; }
    echo "no unexpected sandbox denials"
    ;;
  *) echo "usage: scripts/check-sandbox.sh entitlements [--store] | watch | smoke" >&2; exit 2 ;;
esac
