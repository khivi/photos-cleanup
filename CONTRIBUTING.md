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
CI runs them on every push and pull request.

Put each rule the app follows in `PhotosCleanupCore`, where these tests reach it. This includes launch: `launch(library:judge:settings:cacheDir:)` returns no access, failed or loaded. The views hold no decisions, so there are no view tests.

### Launch check

```bash
scripts/app.sh smoke
```

It builds and opens "Photos Cleanup Dev", then waits for the `Loaded:` line in `/tmp/photos-cleanup-app.log`. It quits the app and exits 0 when the library loads. It exits 1 if the app quits first, or if no `Loaded:` line appears in `SMOKE_TIMEOUT` seconds (default 120). A timeout usually means no Photos access.
It only reads the library. CI cannot run it, because it needs a Photos library and Photos access.

### Driving the app

The main controls have accessibility identifiers, so automation finds them by a stable id, not by their label. Examples are `tab-<pass key>` for each sidebar pass, `commit`, `delete-in-photos`, `export-start`, `import-start` and `photo-<uuid>` for each grid cell. Search for `accessibilityIdentifier` in `Sources/PhotosCleanupApp/` for the full list.
A `tab-<key>` id lands on a text inside the sidebar's `AXRow`, because SwiftUI's `List` owns the row. To select a tab, set `AXSelected` on the `AXRow` that contains the id. Find the row from the window down: SwiftUI sometimes gives the text no `AXParent`.
The [sandbox check](#sandbox-check) uses them when Claude drives the app with cmux-cua.
There is no XCUITest suite. Outside demo mode the app works on the real Photos library, so a UI test would move real photos. Drive the [demo](#demo-mode) instead.

### Demo mode

```bash
scripts/app.sh demo
```

It builds and opens "Photos Cleanup Demo" (`com.khivi.photos-cleanup.demo`) with the `--demo` argument.
The app then runs the full UI on a fake library. It never reads or changes your Photos library.
The demo has its own sandbox container, so it shares no settings with the Dev build or the release.
`scripts/demo/manifest.json` lists the photos: dates, sizes, flags, Vision results, albums and AI verdicts. Every pass has candidates, and Bursts and Similar have groups.
`scripts/demo/generate.swift` draws the images into the bundle at build time. Only the manifest and the generator are committed.
Commit, Delete Me and Delete in Photos… change memory only, so each launch starts from the manifest.
Export writes real files into the folder you choose.
The build also writes a sample folder to `.build/demo-import` for the Import screen. Import moves its files, so each `scripts/app.sh demo` makes a new one.
The app chooses the demo only when `--demo` is set and the bundle holds fixtures. Release builds hold none, and `scripts/app.sh demo` refuses `SIGN_IDENTITY`.
A launch argument fits `open --args`; a sandboxed app cannot read a fixtures folder outside its bundle, so the build copies the fixtures in.
Show in Photos and Open Import in Photos are hidden.
To check the launch, run `scripts/app.sh demo smoke`. CI runs it on every push.

## Pre-commit

```bash
pre-commit install
```

This installs a commit hook and a pre-push hook.
The commit hook runs the linters and builds the Swift package.

## Layout

- `Sources/PhotosCleanupCore/` — PhotoKit, Vision, Foundation Models, the passes, the `Cleanup` actor and the `ReviewModel` the app's screen runs on. No web framework, no SwiftUI.
- `Sources/PhotosCleanupApp/` — the native SwiftUI app, its `Info.plist` (the release version) and its entitlements
- `scripts/app.sh` — builds and signs the app bundle; `run` opens it, `smoke` checks that it launches, `demo` runs it on fixtures
- `scripts/demo/` — the demo fixtures: `manifest.json` lists the photos and `generate.swift` draws their images
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

Do this before each release. It has two parts. Both run `scripts/check-sandbox.sh watch` in a second terminal, and pass when it prints no `deny` line. Each `deny(1) <operation> <path>` names something the sandbox blocked. `vfs.disk-space`, `AppleNVMeEANUC` and `syspolicy.exec` come from system frameworks and are expected. The `run-app` skill's sandbox check does both parts with Claude driving the app.

**Demo part.** It covers every file and settings path, including the steps that change photos, because the demo never touches your library.

1. Run `scripts/app.sh demo`.
2. Open each tab. Mark photos Keep and Delete Me, then Commit. Click Delete in Photos….
3. Export: choose a new, empty folder and export.
4. Import: add `.build/demo-import`, click Check, then Sort. Its sidebar path starts with `~`.
5. Change the zoom. Quit and open the demo again with `open ".build/Photos Cleanup Demo.app" --args --demo`. The zoom, the Export folder and the Import folder are kept, and no folder shows "Not found".

**Library part.** It covers only what the demo fakes: PhotoKit, Vision, the AI judge and Show in Photos.

1. Run `scripts/app.sh smoke`. It exits 0 when the Dev build loads your library.
2. Run `scripts/app.sh run`. Allow Photos access if macOS asks.
3. Let the Vision and AI passes give verdicts. Don't click Delete in Photos….
4. Click Show in Photos. Photos selects the photo. macOS asks once for Automation access.
