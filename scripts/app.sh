#!/usr/bin/env bash
# Build and sign `.build/Photos Cleanup.app`. `run` also opens it, with output in a log.
# `smoke` opens it and waits for the app's `Loaded:` line (exit 0), or fails if it quits or times out.
#   scripts/app.sh [run|smoke|demo] [--hidden] [--universal]
# `--hidden` opens the app behind other windows without taking focus, for automation; `smoke` always does.
# `demo` builds "Photos Cleanup Demo" (com.khivi.photos-cleanup.demo) with generated fixtures bundled, and opens it
# with `--demo`: the full UI on a fake library, never your Photos. It combines with `smoke`. Dev builds only.
# SMOKE_TIMEOUT: seconds `smoke` waits for `Loaded:` (default 120).
# SIGN_IDENTITY (e.g. "Developer ID Application: …") signs with the hardened runtime; default ad hoc.
# Without SIGN_IDENTITY the bundle is "Photos Cleanup Dev" (com.khivi.photos-cleanup.dev), so it shares no sandbox container or Photos access with the release.
# BUILD_NUMBER, if set, replaces CFBundleVersion in the bundle (the release uses the commit count).
set -euo pipefail
cd "$(dirname "$0")/.."

run=0 smoke=0 demo=0 hide=() arch=()
for a in "$@"; do
  case $a in
    run) run=1 ;;
    smoke) smoke=1 ;;
    demo) demo=1 ;;
    --hidden) hide=(-g -j) ;;
    --universal) arch=(--arch arm64 --arch x86_64) ;;
    *) echo "usage: scripts/app.sh [run|smoke|demo] [--hidden] [--universal]" >&2; exit 2 ;;
  esac
done

# SwiftPM records SDK 15.0 in the binary whatever SDK it builds with, and macOS then draws the
# window in its pre-macOS 26 style. Set the real SDK, and keep the minimum OS from Info.plist.
[ "$demo" = 0 ] || [ -z "${SIGN_IDENTITY:-}" ] || { echo "demo is for Dev builds: unset SIGN_IDENTITY" >&2; exit 2; }
[ "$demo" = 0 ] || [ "$smoke" = 1 ] || run=1
min=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Sources/PhotosCleanupApp/Info.plist)
sdk=$(xcrun --sdk macosx --show-sdk-version)
build=(swift build -c release --product PhotosCleanupApp -Xlinker -platform_version -Xlinker macos -Xlinker "$min" -Xlinker "$sdk" ${arch[@]+"${arch[@]}"})
"${build[@]}"
bin=$("${build[@]}" --show-bin-path)

app=".build/Photos Cleanup.app"
[ "$demo" = 0 ] || app=".build/Photos Cleanup Demo.app"
open_args=()
[ "$demo" = 0 ] || open_args=(--args --demo)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/PhotosCleanupApp" "$app/Contents/MacOS/"
cp Sources/PhotosCleanupApp/Info.plist "$app/Contents/Info.plist"
[ -z "${BUILD_NUMBER:-}" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app/Contents/Info.plist"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  name="Photos Cleanup Dev" id=com.khivi.photos-cleanup.dev
  [ "$demo" = 0 ] || { name="Photos Cleanup Demo"; id=com.khivi.photos-cleanup.demo; }
  for k in CFBundleName CFBundleDisplayName; do /usr/libexec/PlistBuddy -c "Set :$k '$name'" "$app/Contents/Info.plist"; done
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$app/Contents/Info.plist"
fi
mkdir -p "$app/Contents/Resources"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir "$iconset"
for n in 16 32 128 256 512; do
  sips -z $n $n -s format png Sources/PhotosCleanupApp/AppIcon.svg --out "$iconset/icon_${n}x${n}.png" >/dev/null
  sips -z $((n * 2)) $((n * 2)) -s format png Sources/PhotosCleanupApp/AppIcon.svg --out "$iconset/icon_${n}x${n}@2x.png" >/dev/null
done
if [ "$demo" = 1 ]; then
  swift scripts/demo/generate.swift scripts/demo/manifest.json "$app/Contents/Resources/demo" .build/demo-import
  echo "Import sample folder: $PWD/.build/demo-import"
fi
cp Sources/PhotosCleanupApp/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
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
  open -n ${hide[@]+"${hide[@]}"} "$app" --stdout /tmp/photos-cleanup-app.log --stderr /tmp/photos-cleanup-app.log ${open_args[@]+"${open_args[@]}"}
  echo "log: /tmp/photos-cleanup-app.log"
fi

if [ "$smoke" = 1 ]; then
  log=/tmp/photos-cleanup-app.log
  bin_path="$PWD/$app/Contents/MacOS/PhotosCleanupApp"
  quit() { pkill -f "$bin_path" || true; }
  quit
  : >"$log"
  open -n -g -j "$app" --stdout "$log" --stderr "$log" ${open_args[@]+"${open_args[@]}"}
  for ((i = 0; i < ${SMOKE_TIMEOUT:-120}; i++)); do
    if grep -q '^Loaded:' "$log"; then
      grep '^Loaded:' "$log"; quit; exit 0
    fi
    if ! pgrep -f "$bin_path" >/dev/null && [ "$i" -ge 3 ]; then
      cat "$log"; echo "smoke: the app crashed or quit before printing Loaded:" >&2; exit 1
    fi
    sleep 1
  done
  quit
  echo "smoke: no Loaded: within ${SMOKE_TIMEOUT:-120}s; most likely no Photos access (the No access screen) or a slow library" >&2
  exit 1
fi
