# TODO

Done items live in `git log`. This file keeps open work and decisions that still constrain it.

## Stack — DECIDED 2026-10-29: native SwiftUI app

The app is a Swift package with no dependencies: `PhotosCleanupCore` plus the SwiftUI app, bundled and signed by `scripts/app.sh`.
All library access goes through PhotoKit, in-process. Vision and Foundation Models also run in-process.
See [ARCHITECTURE.md](ARCHITECTURE.md).

- **Build:** SwiftPM, plus a script that assembles and signs the `.app` bundle. No Xcode project.
- **Thumbnails:** the app owns a `PHCachingImageManager` (`.highQualityFormat`, caching ~30 rows ahead).
- **Distribution:** Homebrew ships a cask, not a formula; the Mac App Store ships a sandboxed build of the same app. The app asks for its own Photos permission.

Not pursuing:

- **Edited copies.** Photos keeps edits inside the same photo; Photos' own Duplicates album finds exported copies saved back.
- **HEIC savings estimate.** Photos and iCloud already store new photos as HEIC.
- **Threshold settings.** The constants in `Passes` are set by eye on the real library; add a setting only when a pass's picks are wrong in practice. Similar shares Bursts' `similarMaxDistance` (0.45): split it only when Similar shows groups that aren't repeats.
- **Dry run.** Nothing changes until Apply is confirmed.
- **Date range.** The Keep album hides reviewed photos, so a rerun shows only new ones.
- **Side-by-side compare in a group.** ←/→ in the preview flips between frames.
- **Anything sorted by size.** No file sizes are read (see the recoverable GB item).
- **Streaks, widgets, reminders, swiping, video compression, Live Photo → still.** Phone retention features; compression and conversion re-import through PhotoKit and lose metadata.

## Packaging and CI

Homebrew is the install path: the cask in `khivi/homebrew-photos-cleanup` installs the signed, notarized app zip from each GitHub Release. Release steps are in [CONTRIBUTING.md](CONTRIBUTING.md#release).

`ci.yml` runs `swift build` and `swift test` on `macos-latest` (no macOS 27 SDK: the no-verdicts fallback) and `xcode-27` (verdicts compiled in), where it also builds and signs the `.app`.

## Visibility

Say on every page: macOS 15 or later; Screenshots and Paperwork verdicts need macOS 27 with Apple Intelligence.

- [ ] **Social preview:** `docs/social-preview.png` (1280×640). Upload it in Settings > General > Social preview; GitHub has no API for it.
- [ ] **Landing page:** one GitHub Pages page (headline, screenshots or a GIF, Download button to the latest release, requirements), set as the repo homepage.
- [ ] **Listings:** posts on r/macapps and r/apple; Show HN (lead with the on-device Vision and Foundation Models work); pull requests to `serhii-londar/open-source-mac-os-apps` and `jaywcjlove/awesome-mac`; AlternativeTo and MacUpdate; Product Hunt once the landing page is up. Claude drafts; the user posts.
- [ ] **Official Homebrew cask** (`brew install --cask photos-cleanup` without the tap). Homebrew turns down repos that aren't yet well known, about 75 stars.

## Mac App Store

0.11.0 (build 274) is submitted for review, manual release (2026-11-10). App ID 6833111040; `AppStore.provisionprofile` expires 2027-11-10.

- [ ] TestFlight check of 274: Photos access, Import and Export folders kept across relaunch, no Show in Photos.
- [ ] After approval: Release This Version in App Store Connect.
- [ ] An Import screenshot from a sample folder with a neutral path (the demo's is under `.build/`).
- [ ] Later: a CI job in `release.yml` that builds the store `.pkg` and uploads it to App Store Connect (TestFlight); review stays manual. Needs an App Store Connect API key that may upload, and the Apple Distribution and installer certificates as a `.p12` secret.

## UX

- [ ] **After #16–#24 merge: retake the App Store screenshots** (`docs/app-store/screenshots/`) and `docs/screenshot.jpg` from the demo (`scripts/app.sh demo`). They show the old grid, Delete Me albums and the All view.
- [ ] Paperwork is skipped by Start Cleanup and Continue until opened: its count waits for verdicts, which start only when the pass opens.
- [ ] "You can recover 18.2 GB": needs each asset's file size. `PHAssetResource`'s `fileSize` is an undocumented key: guard with `responds(to:)`, since a missing key raises an Objective-C exception Swift can't catch.
- [ ] A single section with hundreds of photos (a trip in Videos) could split by week.

Open naming questions:

- "Low Quality" → "Likely Missed Shots". Albums no longer use the title; only an old `Low Quality - Delete Me` album would be stranded.
- "candidate" in docs and code (the UI says "photos" now).
- Delete in Photos… and the macOS dialog keep "delete": that step really deletes.

## photos-import

Decided: import stays through Photos (drag or File → Import, for its duplicate detection); the tool stays read-only on the library, and moves files only within the folder.
