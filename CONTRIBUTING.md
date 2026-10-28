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

- `Sources/PhotosCleanupCore/` — PhotoKit, Vision, Foundation Models, the passes and the `Cleanup` actor. No web framework.
- `Sources/PhotosCleanupServer/` — Hummingbird routes, JSON and the Host allowlist
- `Sources/PhotosCleanup/` — the `photos-cleanup` executable, `Info.plist` and the built UI
- `Tests/` — Core and server tests
- `src/` — React UI
- `spike/` — research probes

## Release

1. Change `version` in `Sources/PhotosCleanup/main.swift` on `master`.
2. `release.yml` builds a universal binary on the `xcode-27` runner. It fails if AI verdicts are not compiled in.
3. It signs the binary with Developer ID and notarizes it. It fails if Apple does not accept it. The certificate and API key secrets are listed in `release.yml`.
4. It creates the GitHub Release `v<version>` with the tarball attached.
5. It sets the new `url` and `sha256` in the formula in `khivi/homebrew-photos-cleanup`.

Don't edit the formula's `url` by hand before a release. The bump step skips a formula already at the new version, which leaves its `sha256` stale.
