# Contributing

## Requirements

- macOS with the Xcode Command Line Tools (Swift 6)
- Node and pnpm, for the UI

## Setup

```bash
pnpm install
pnpm build
```

`pnpm build` writes the UI into `Sources/PhotosCleanup/ui/dist`. Git ignores that directory.
SwiftPM ships it as a resource of the `photos-cleanup` executable.

## Run

The native app:

```bash
scripts/app.sh run
```

It builds `.build/Photos Cleanup.app`, signs it ad hoc and opens it. Its output goes to `/tmp/photos-cleanup-app.log`.
macOS asks for Photos access once for "Photos Cleanup".
A bare binary started from a shell never gets its window in front, so always run the app as a bundle.

The browser UI, until the native app replaces it:

```bash
swift run photos-cleanup
```

For hot reload, run the API and Vite in two terminals.

```bash
swift run photos-cleanup --dev
pnpm dev
```

Vite proxies API requests to the server.

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
- `Sources/PhotosCleanupServer/` — Hummingbird routes, JSON and the Host allowlist
- `Sources/PhotosCleanup/` — the `photos-cleanup` executable for the browser UI, its `Info.plist` and the built UI
- `scripts/app.sh` — builds and signs the app bundle
- `Tests/` — Core and server tests
- `src/` — React UI
- `spike/` — research probes

## Release

1. Change `CFBundleShortVersionString` in `Sources/PhotosCleanupApp/Info.plist` on `master`. A manual run of `release.yml` also works.
2. `release.yml` builds the universal app with `scripts/app.sh` on the `xcode-27` runner. It fails if AI verdicts are not compiled in or the Photos entitlement is missing.
3. It signs the app with Developer ID and the hardened runtime, notarizes it and staples the ticket. It fails if Apple does not accept it. The certificate and API key secrets are listed in `release.yml`.
4. It creates the GitHub Release `v<version>` with `Photos-Cleanup-<version>.zip` attached.
5. It writes `Casks/photos-cleanup.rb` in `khivi/homebrew-photos-cleanup` and removes the old formula. The cask exists only in `release.yml`; don't edit it in the tap.

The hardened runtime denies Photos access without the `com.apple.security.personal-information.photos-library` entitlement, even when System Settings allows the app. `scripts/app.sh` always signs with it.
