# TODO

## Stack — DECIDED 2026-10-27: browser + local Python server

The app stays a local FastAPI server (osxphotos engine) serving the React UI to the browser. Swift exists only as on-device helpers the server shells out to (`photos_cleanup/verdict.swift`).

Not pursuing:

- **Native SwiftUI + PhotoKit rewrite** (decided 2026-07-22, reversed here). The spikes in `spike/` showed Vision can replace osxphotos' signals; the reasoning and the PhotoKit audit are in commit `8320785` and the history of this file.
- **Mac App Store.** The sandbox blocks the PyInstaller bundle, osxphotos' direct `Photos.sqlite` reads, and the Apple Events album writes. Only a native rewrite gets past it.

## Packaging

The installable package is done: Homebrew tap, `uv tool install macos-photos-cleanup`, `pipx`. Release steps are in [CONTRIBUTING.md](CONTRIBUTING.md#release). Both GitHub repos exist, `HOMEBREW_TAP_TOKEN` is set and private vulnerability reporting is on. Remaining one-time setup:

- [ ] Add a PyPI pending trusted publisher: project `macos-photos-cleanup`, owner `khivi`, repo `photos-cleanup`, workflow `publish.yml`, environment `pypi`.

## CI

The CI workflow exists (`.github/workflows/`) and passes on macOS runners for pull requests.

- [ ] Confirm the first `master` push run passes (queued for a macOS runner on 2026-10-27).
- [ ] **Triage the first Dependabot batch** (PRs #1–#9). One run failed. The major bumps need care: TypeScript 5 → 7, `@vitejs/plugin-react` 4 → 5, `actions/setup-node` 6 → 7, `pnpm/action-setup` 4 → 6.

## App

- [ ] **A second verdict pass doesn't start while another classifies** — `_start_classifier` returns early if a run is active, so opening Utility while Screenshots is classifying never starts Utility; polling stops when the first run ends and the user must reopen the tab. Queue the second run, or run one classifier over both passes' photos.
- [ ] **Measure verdicts against real choices** — `/commit` now logs the user's final decision against each verdict (`decisions.jsonl`, `GET /verdict-stats`). After real use of Screenshots and Utility, read the agreement rate and tune `photos_cleanup/verdict.swift`. Baseline: `f1751a9` (summary before `keep`, greedy, new kinds) matched 96/102 filed screenshots, but those filings mostly accepted the old preselected verdicts. Known miss: a medicine-box photo gets delete; adding "medical or health information" to the keep list didn't fix it and flipped another photo. Tried and dropped: asking for facts (`timeSensitive`/`reusableInfo`) and deciding in code — 66/101. Editing `verdict.swift` re-judges everything (the cache file is keyed to its hash).
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (keyed to `verdict.swift`'s hash, so an OS model update alone doesn't invalidate it — key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`is_in_user_album`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
