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
- **Anything sorted by size, or "you can recover N GB".** No file sizes are read: `PHAssetResource`'s `fileSize` is an undocumented key.
- **Streaks, widgets, reminders, swiping, video compression, Live Photo → still.** Phone retention features; compression and conversion re-import through PhotoKit and lose metadata.

## Packaging and CI

Homebrew is the install path: the cask in `khivi/homebrew-photos-cleanup` installs the signed, notarized app zip from each GitHub Release. Release steps are in [CONTRIBUTING.md](CONTRIBUTING.md#release).

`ci.yml` lints every push on ubuntu. The macOS jobs run only on master, since the pre-push hook builds, tests and smoke-tests on a Mac: `swift build` and `swift test` on `macos-latest` (no macOS 27 SDK: the no-verdicts fallback) and `xcode-27` (verdicts compiled in), where it also builds and signs the `.app`. A green master then calls `release.yml`.

## Visibility

Say on every page: macOS 15 or later; Screenshots and Paperwork verdicts need macOS 27 with Apple Intelligence.

- [ ] **Landing page:** one GitHub Pages page (headline, screenshots or a GIF, Download button to the latest release, requirements), set as the repo homepage.
- [ ] **Listings:** posts on r/macapps and r/apple; Show HN (lead with the on-device Vision and Foundation Models work); pull requests to `serhii-londar/open-source-mac-os-apps` and `jaywcjlove/awesome-mac`; AlternativeTo and MacUpdate; Product Hunt once the landing page is up. Claude drafts; the user posts.
- [ ] **Official Homebrew cask** (`brew install --cask photos-cleanup` without the tap). Homebrew turns down repos that aren't yet well known, about 75 stars.

## Mac App Store

0.11.0 (build 274) is submitted for review, manual release (2026-11-10). App ID 6833111040; `AppStore.provisionprofile` expires 2027-11-10.

- [ ] TestFlight check of 274: Photos access, Import and Export folders kept across relaunch, no Show in Photos.
- [ ] Release 0.11.0 by hand after approval. From 0.12, use automatic release in App Store Connect, and have a `release.yml` job build the store `.pkg` (`scripts/app.sh store`) and upload it with `xcrun altool`; khivi submits for review. Needs an App Store Connect API key that may upload (check whether the notary key's role allows it), and the Apple Distribution and 3rd Party Mac Developer Installer certificates as a `.p12` secret.

## UX

Decided 2026-11-16: "Low Quality" keeps its name. It names what the pass scores (blurry, dark or accidental), and fits the one-word tabs. "Candidate" stays in code and developer docs: a photo a pass may suggest, never shown in the UI. Apply to Photos… keeps "Apply" (it deletes and files Keeps); Delete in Photos… keeps "delete" (it only deletes).

- [ ] **After #16–#23 merge: retake every screenshot from the demo** (`scripts/app.sh demo`): the App Store screenshots (`docs/app-store/screenshots/`), `docs/screenshot.jpg`, the Import screenshot (from a sample folder with a neutral path; the demo's is under `.build/`), and the social preview `docs/social-preview.png` (1280×640), which shows the real library and the old UI. Upload the social preview in GitHub Settings > General > Social preview; GitHub has no API for it.

## photos-import

Decided: import stays through Photos (drag or File → Import, for its duplicate detection); the tool stays read-only on the library, and moves files only within the folder.
