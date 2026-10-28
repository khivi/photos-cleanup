# TODO

## Stack — DECIDED 2026-10-28: browser UI + local Swift server

The app is a Swift package. A Hummingbird server serves the React UI to the browser.
All library access goes through PhotoKit, in-process. Vision and Foundation Models also run in-process.
The Python server, the Swift helper processes and the PyPI package are gone.
osxphotos and Full Disk Access were dropped on 2026-10-28.
See [ARCHITECTURE.md](ARCHITECTURE.md).

Not pursuing:

- **Native SwiftUI app** (decided 2026-07-22). `PhotosCleanupCore` has no web framework, so a native app could import it later. The reasoning and the PhotoKit audit are in commit `8320785`.
- **Mac App Store.** It needs a sandboxed app bundle, and a server driven from a browser isn't one.

## Packaging and CI

- [ ] **Switch the GitHub workflows and the Homebrew formula from PyPI and uv to `swift build`.** Both still target the Python package. A draft is in `docs/swift-release-draft.md`. The release steps in [CONTRIBUTING.md](CONTRIBUTING.md#release) assume the switch.

`ci.yml` ran `uv` and `pytest` on macOS runners. It must run `pnpm build` and `swift test`. Dependabot opens monthly PRs with a 7-day cooldown.

## App

- [ ] **Measure verdicts against real choices** — `/commit` logs the user's final decision against each verdict (`decisions.jsonl`, `GET /verdict-stats`). After real use of Screenshots and Utility, read the agreement rate and tune the prompt in `Sources/PhotosCleanupCore/Verdicts.swift`. Baseline: `f1751a9` (summary before `keep`, greedy, new kinds) matched 96/102 filed screenshots, but those filings mostly accepted the old preselected verdicts. Known miss: a medicine-box photo gets delete; adding "medical or health information" to the keep list didn't fix it and flipped another photo. Tried and dropped: asking for facts (`timeSensitive`/`reusableInfo`) and deciding in code — 66/101. After a prompt change, rename `Cleanup.verdictCache` to re-judge everything.
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (a constant name today, so an OS model update alone doesn't invalidate it; key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`candidatePhotos` in `Passes.swift`). "Off" needs custom candidate logic to *include* album photos. Decide whether iCloud Shared Albums should protect photos; PhotoKit's album list leaves them out.
