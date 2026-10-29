#!/usr/bin/env bash
# Build and sign `.build/Photos Cleanup.app`. `run` also opens it, with output in a log.
#   scripts/app.sh [run] [--universal]
# SIGN_IDENTITY (e.g. "Developer ID Application: …") signs with the hardened runtime; default ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

run=0 arch=()
for a in "$@"; do
  case $a in
    run) run=1 ;;
    --universal) arch=(--arch arm64 --arch x86_64) ;;
    *) echo "usage: scripts/app.sh [run] [--universal]" >&2; exit 2 ;;
  esac
done

swift build -c release --product PhotosCleanupApp ${arch[@]+"${arch[@]}"}
bin=$(swift build -c release --product PhotosCleanupApp ${arch[@]+"${arch[@]}"} --show-bin-path)

app=".build/Photos Cleanup.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/PhotosCleanupApp" "$app/Contents/MacOS/"
cp Sources/PhotosCleanupApp/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir "$iconset"
for n in 16 32 128 256 512; do
  sips -z $n $n -s format png Sources/PhotosCleanupApp/AppIcon.svg --out "$iconset/icon_${n}x${n}.png" >/dev/null
  sips -z $((n * 2)) $((n * 2)) -s format png Sources/PhotosCleanupApp/AppIcon.svg --out "$iconset/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
# This target's own SwiftPM resource bundles (none yet); $bin also holds every other target's.
for b in "$bin"/photos-cleanup_PhotosCleanup{App,Core}.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done
# The hardened runtime denies Photos access without this entitlement, even when TCC allows it.
ent=Sources/PhotosCleanupApp/PhotosCleanup.entitlements
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements "$ent" --sign "$SIGN_IDENTITY" ${KEYCHAIN:+--keychain "$KEYCHAIN"} "$app"
else
  codesign --force --entitlements "$ent" --sign - "$app"
fi
echo "$app"

if [ "$run" = 1 ]; then
  open -n "$app" --stdout /tmp/photos-cleanup-app.log --stderr /tmp/photos-cleanup-app.log
  echo "log: /tmp/photos-cleanup-app.log"
fi
