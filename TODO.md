# TODO

## Stack — DECIDED 2026-10-27: browser + local Python server

The app stays a local FastAPI server serving the React UI to the browser. All library access goes through PhotoKit, via the long-running Swift helper `photos_cleanup/photokit.swift` (reads, thumbnails, Vision analysis, album writes); `verdict.swift` runs Foundation Models. osxphotos and Full Disk Access were dropped on 2026-10-28.

Not pursuing:

- **Native SwiftUI + PhotoKit rewrite** (decided 2026-07-22, reversed here). The spikes in `spike/` showed Vision can replace osxphotos' signals; the reasoning and the PhotoKit audit are in commit `8320785` and the history of this file.
- **Mac App Store.** It needs a sandboxed app bundle, and a Python server driven from a browser isn't one. PhotoKit removed the other walls (private `Photos.sqlite` reads, Apple Events album writes), so a native rewrite would now face only the UI and packaging work.

## Packaging

Released on PyPI (`macos-photos-cleanup`) and the Homebrew tap; 0.2.0 is current. Release steps are in [CONTRIBUTING.md](CONTRIBUTING.md#release): bump `version` in `pyproject.toml` on master.

## CI

`ci.yml` passes on macOS runners for master and pull requests. Dependabot opens monthly PRs with a 7-day cooldown.

## App

- [ ] **Measure verdicts against real choices** — `/commit` now logs the user's final decision against each verdict (`decisions.jsonl`, `GET /verdict-stats`). After real use of Screenshots and Utility, read the agreement rate and tune `photos_cleanup/verdict.swift`. Baseline: `f1751a9` (summary before `keep`, greedy, new kinds) matched 96/102 filed screenshots, but those filings mostly accepted the old preselected verdicts. Known miss: a medicine-box photo gets delete; adding "medical or health information" to the keep list didn't fix it and flipped another photo. Tried and dropped: asking for facts (`timeSensitive`/`reusableInfo`) and deciding in code — 66/101. Editing `verdict.swift` re-judges everything (the cache file is keyed to its hash).
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (keyed to `verdict.swift`'s hash, so an OS model update alone doesn't invalidate it — key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`library.get_candidate_photos`). "Off" needs custom candidate logic to *include* album photos. Decide whether iCloud Shared Albums should protect photos; PhotoKit's album list leaves them out.
