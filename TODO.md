# TODO

## Stack — DECIDED 2026-10-27: browser + local Python server

The app stays a local FastAPI server serving the React UI to the browser. Library reads use osxphotos (`photos_cleanup/library.py`); album writes use PhotoKit. Swift exists only as on-device helpers the server shells out to: `verdict.swift` (Foundation Models), `featureprint.swift` (Vision), `albums.swift` (PhotoKit).

Not pursuing:

- **Native SwiftUI + PhotoKit rewrite** (decided 2026-07-22, reversed here). The spikes in `spike/` showed Vision can replace osxphotos' signals; the reasoning and the PhotoKit audit are in commit `8320785` and the history of this file.
- **Mac App Store.** The sandbox blocks the PyInstaller bundle, osxphotos' direct `Photos.sqlite` reads, and the Apple Events album writes. Only a native rewrite gets past it.

## Packaging

Released on PyPI (`macos-photos-cleanup`) and the Homebrew tap; 0.2.0 is current. Release steps are in [CONTRIBUTING.md](CONTRIBUTING.md#release): bump `version` in `pyproject.toml` on master.

## CI

`ci.yml` passes on macOS runners for master and pull requests. Dependabot opens monthly PRs with a 7-day cooldown.

## App

- [ ] **Read the library through PhotoKit, drop osxphotos and Full Disk Access** — album writes already moved (`7cef4e1`). The spike (`aa4ebee`, `spike/photokit_probe.swift`) settled the risks: Photos permission prompts once, is held by the launching terminal, and survives helper recompiles; 8,449 assets list in 0.17s with flags in 0.09s and 31 albums in 0.03s; PhotoKit omits iCloud Shared Album photos, which the app can't file anyway. Replace `library.py` with a long-running Swift helper: list photos (uuid = `localIdentifier` prefix, so verdict caches and decision logs carry over), album membership, and thumbnails written to a cache dir for `/thumb`. Low quality needs Vision's aesthetics score instead of Apple's `score.overall` (rho 0.91 in the spike): score the library once, cache it, re-tune the threshold against the filed "Low Quality - Review Me" photos. Skip file size (only readable via an undocumented key). Then switch the startup check and README from Full Disk Access to Photos, and remove osxphotos.
- [ ] **Measure verdicts against real choices** — `/commit` now logs the user's final decision against each verdict (`decisions.jsonl`, `GET /verdict-stats`). After real use of Screenshots and Utility, read the agreement rate and tune `photos_cleanup/verdict.swift`. Baseline: `f1751a9` (summary before `keep`, greedy, new kinds) matched 96/102 filed screenshots, but those filings mostly accepted the old preselected verdicts. Known miss: a medicine-box photo gets delete; adding "medical or health information" to the keep list didn't fix it and flipped another photo. Tried and dropped: asking for facts (`timeSensitive`/`reusableInfo`) and deciding in code — 66/101. Editing `verdict.swift` re-judges everything (the cache file is keyed to its hash).
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (keyed to `verdict.swift`'s hash, so an OS model update alone doesn't invalidate it — key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`library.get_candidate_photos`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
