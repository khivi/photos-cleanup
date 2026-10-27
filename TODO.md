# TODO

## Stack — DECIDED 2026-10-27: browser + local Python server

The app stays a local FastAPI server (osxphotos engine) serving the React UI to the browser. Swift exists only as on-device helpers the server shells out to (`photos_cleanup/verdict.swift`).

Not pursuing:

- **Native SwiftUI + PhotoKit rewrite** (decided 2026-07-22, reversed here). The spikes in `spike/` showed Vision can replace osxphotos' signals; the reasoning and the PhotoKit audit are in commit `8320785` and the history of this file.
- **Mac App Store.** The sandbox blocks the PyInstaller bundle, osxphotos' direct `Photos.sqlite` reads, and the Apple Events album writes. Only a native rewrite gets past it.

## Packaging

The installable package is done: Homebrew tap, `uv tool install macos-photos-cleanup`, `pipx`. Release steps are in [CONTRIBUTING.md](CONTRIBUTING.md#release). Remaining one-time setup:

- [ ] Create the GitHub repos `khivi/photos-cleanup` and `khivi/homebrew-photos-cleanup`.
- [ ] Add the `HOMEBREW_TAP_TOKEN` secret: a PAT with Contents write on `khivi/homebrew-photos-cleanup` and this repo.
- [ ] Add a PyPI pending trusted publisher: project `macos-photos-cleanup`, owner `khivi`, repo `photos-cleanup`, workflow `publish.yml`, environment `pypi`.
- [ ] Enable private vulnerability reporting on the repo.

## CI

The CI workflow exists (`.github/workflows/`).

- [ ] Confirm the first CI run passes on a macOS runner.

## App

- [ ] **Measure screenshot verdicts against real choices** — `f1751a9` (summary before `keep`, greedy, new kinds) matches 96/102 filed screenshots, but those filings mostly accepted the old preselected verdicts, so it's a consistency check, not accuracy. Log which photos the user toggles before commit to get a real disagreement rate. Known miss: a medicine-box photo gets delete; adding "medical or health information" to the keep list didn't fix it and flipped another photo. Tried and dropped: asking for facts (`timeSensitive`/`reusableInfo`) and deciding in code — 66/101, neither fact separated kept from deleted. Editing `photos_cleanup/verdict.swift` re-judges everything (the cache file is keyed to its hash).
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (keyed to `verdict.swift`'s hash, so an OS model update alone doesn't invalidate it — key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **More passes** — clusters / similar / documents; the grouped ones need a "keep best per group" review UI.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`is_in_user_album`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
