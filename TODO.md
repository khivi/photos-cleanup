# TODO

## Stack — DECIDED 2026-10-27: browser + local Python server

The app stays a local FastAPI server (osxphotos engine) serving the React UI to the browser. Swift exists only as on-device helpers the server shells out to (`sidecar/verdict.swift`).

Not pursuing:

- **Native SwiftUI + PhotoKit rewrite** (decided 2026-07-22, reversed here). The spikes in `spike/` showed Vision can replace osxphotos' signals; the reasoning and the PhotoKit audit are in commit `8320785` and the history of this file.
- **Mac App Store.** The sandbox blocks the PyInstaller bundle, osxphotos' direct `Photos.sqlite` reads, and the Apple Events album writes. Only a native rewrite gets past it.

## Packaging

Tauri + PyInstaller `.app` dropped 2026-10-27: the app is now a local FastAPI server serving the React UI to the browser (see README). No `.app` means nothing to sign or notarize. Full Disk Access and Photos automation go to whichever terminal runs the server.

- [ ] **Installable package** — put the built `dist/` inside the wheel (hatch `force-include`) and package `sidecar/` with a `[project.scripts]` entry point. Then `uv tool install git+https://github.com/khivi/photos-cleanup` works.
- [ ] **Homebrew tap (optional, after the above)** — formula in `khivi/homebrew-tap` using `virtualenv_install_with_resources`; regenerate resources with `brew update-python-resources`. homebrew-core is unlikely to accept it.

## CI

- [ ] **GitHub Actions** — macOS runner: `uv run pytest -q` + `pnpm build`. macOS-only app (osxphotos / Photos.app / AppleScript), so no Windows/Linux targets.

## App

- [ ] **Measure screenshot verdicts against real choices** — `f1751a9` (summary before `keep`, greedy, new kinds) matches 96/102 filed screenshots, but those filings mostly accepted the old preselected verdicts, so it's a consistency check, not accuracy. Log which photos the user toggles before commit to get a real disagreement rate. Known miss: a medicine-box photo gets delete; adding "medical or health information" to the keep list didn't fix it and flipped another photo. Tried and dropped: asking for facts (`timeSensitive`/`reusableInfo`) and deciding in code — 66/101, neither fact separated kept from deleted. Editing `sidecar/verdict.swift` re-judges everything (the cache file is keyed to its hash).
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (keyed to `verdict.swift`'s hash, so an OS model update alone doesn't invalidate it — key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **More passes** — clusters / similar / edited / documents; the grouped ones need a "keep best per group" review UI.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`is_in_user_album`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
