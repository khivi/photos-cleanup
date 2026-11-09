# Contributing

## Requirements

- macOS 15 or later with the Xcode Command Line Tools (Swift 6)
- For AI verdicts: the macOS 27 SDK, and macOS 27 with Apple Intelligence on

## Run

```bash
scripts/app.sh run
```

It builds `.build/Photos Cleanup.app`, signs it ad hoc and opens it. The ad hoc build is "Photos Cleanup Dev" (`com.khivi.photos-cleanup.dev`), so it has its own sandbox container (`~/Library/Containers/com.khivi.photos-cleanup.dev`) and Photos access, apart from the release. Its output goes to `/tmp/photos-cleanup-app.log`.
macOS asks for Photos access once for "Photos Cleanup Dev".
A bare binary started from a shell never gets its window in front, so always run the app as a bundle.

## Tests

```bash
swift test
```

The tests use a fake Photos library and a fake judge.
They need no Photos library, no Photos access and no Apple Intelligence.

## Pre-commit

```bash
pre-commit install
```

This installs a commit hook and a pre-push hook.
The commit hook runs the linters and builds the Swift package.

## Layout

- `Sources/PhotosCleanupCore/` — PhotoKit, Vision, Foundation Models, the passes, the `Cleanup` actor and the `ReviewModel` the app's screen runs on. No web framework, no SwiftUI.
- `Sources/PhotosCleanupApp/` — the native SwiftUI app, its `Info.plist` (the release version) and its entitlements
- `scripts/app.sh` — builds and signs the app bundle
- `Tests/` — Core tests

## Release

1. Change `CFBundleShortVersionString` in `Sources/PhotosCleanupApp/Info.plist` on `master`. A manual run of `release.yml` also works. The build number (`CFBundleVersion`) is the commit count, set by `release.yml`; `Info.plist` keeps `1`.
2. `release.yml` builds the universal app with `scripts/app.sh` on the `xcode-27` runner. It fails if AI verdicts are not compiled in, the Photos or App Sandbox entitlement is missing, or `scripts/check-sandbox.sh entitlements` finds an entitlement outside its allowlist.
3. It signs the app with Developer ID and the hardened runtime, notarizes it and staples the ticket. It fails if Apple does not accept it. The certificate and API key secrets are listed in `release.yml`.
4. It creates the GitHub Release `v<version>` with `Photos-Cleanup-<version>.zip` attached.
5. It writes `Casks/photos-cleanup.rb` in `khivi/homebrew-photos-cleanup` and removes the old formula. The cask exists only in `release.yml`; don't edit it in the tap.
6. Replace the generated notes with notes for users: what changed for them, then how to upgrade. Run `gh release edit v<version> --notes-file <file>`.

The hardened runtime denies Photos access without the `com.apple.security.personal-information.photos-library` entitlement, even when System Settings allows the app. `scripts/app.sh` always signs with it, and with `com.apple.security.app-sandbox`.

### Sandbox check

Do this before each release. CI cannot do it: it needs a Photos library and Photos access. The `run-app` skill's sandbox check does the same steps with Claude driving the app.

1. Run `scripts/app.sh run`. In a second terminal, run `scripts/check-sandbox.sh watch`.
2. Allow Photos access if macOS asks. The library loads.
3. Review: open each pass and mark a photo Keep. Don't click Delete in Photos….
4. Let the Vision and AI passes give verdicts.
5. Export: choose a new, empty folder and export.
6. Import: add a folder and click Check. Its sidebar path starts with `~`.
7. Click Show in Photos. Photos selects the photo. macOS asks once for Automation access.
8. Change the zoom. Quit and open the app again. The zoom, the Export folder and the Import folder are kept, and no folder shows "Not found".

The check passes when `watch` prints no `deny` line. Each `deny(1) <operation> <path>` names something the sandbox blocked.
