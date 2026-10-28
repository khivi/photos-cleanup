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

Homebrew is the only install path: `khivi/homebrew-photos-cleanup` installs the prebuilt universal tarball from each GitHub Release (v0.3.0 is the first). The PyPI project `macos-photos-cleanup` is archived (2026-10-28). Release steps are in [CONTRIBUTING.md](CONTRIBUTING.md#release).

`ci.yml` runs `pnpm build`, `swift build` and `swift test` on `macos-latest` (no macOS 27 SDK: the no-verdicts fallback) and `xcode-27` (preview runner: verdicts compiled in). Dependabot opens monthly PRs with a 7-day cooldown.

## App

- [ ] **UI tests** — the React UI (`src/App.tsx`) has only the `tsc` type-check; changes are checked by hand in the browser. Add Vitest (it runs on the existing Vite config) with React Testing Library and a mocked `fetch`: each tab loads its pass, `initialDecision` (verdicts, burst best shot), toggling and Select all, the commit request body (`uuids`/`keep`) and the error banner, polling while `classify.pending > 0`, tab counts. Run it alongside `pnpm build` in pre-commit and CI. Use JSON response fixtures that the Swift `RoutesTests` also assert against, so the UI and the API can't drift apart. A Playwright click-through against the Swift server with the fake library is a later step.
- [ ] **Faster first Vision analysis** — `PhotoKitLibrary.vision` analyses one photo at a time (~80/s, ~1.5 min for 7k photos). Only a first run or a new Mac pays it; later starts read the cache. Run the per-photo image fetch + Vision requests concurrently (a bounded `TaskGroup`, ~4 at a time) inside each batch of 20, keeping batches small so thumbnails still interleave. Measure before and after on the real library.
- [ ] **Measure verdicts against real choices** — `/commit` logs the user's final decision against each verdict (`decisions.jsonl`, `GET /verdict-stats`). After real use of Screenshots and Utility, read the agreement rate and tune the prompt in `Sources/PhotosCleanupCore/Verdicts.swift`. Baseline: `f1751a9` (summary before `keep`, greedy, new kinds) matched 96/102 filed screenshots, but those filings mostly accepted the old preselected verdicts. Known miss: a medicine-box photo gets delete; adding "medical or health information" to the keep list didn't fix it and flipped another photo. Tried and dropped: asking for facts (`timeSensitive`/`reusableInfo`) and deciding in code — 66/101. After a prompt change, rename `Cleanup.verdictCache` to re-judge everything.
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (a constant name today, so an OS model update alone doesn't invalidate it; key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`candidatePhotos` in `Passes.swift`). "Off" needs custom candidate logic to *include* album photos. Decide whether iCloud Shared Albums should protect photos; PhotoKit's album list leaves them out.
