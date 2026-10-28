# photos-cleanup

Local Python FastAPI server + React browser UI for reviewing and clearing
unwanted photos in the macOS Photos library. The app never deletes; it
moves flagged photos into a "Delete Me" album and the user deletes there.

## One package

All code is the `photos_cleanup` package, built from one `pyproject.toml`.
Every Photos library access goes through `photos_cleanup/library.py`, which drives the
long-running PhotoKit helper `photokit.swift`. No osxphotos, no Full Disk Access.

`../../photo-cleanup` is a separate project: the command-line tool this app's
library code was taken from. The app no longer tracks it. Do NOT import it,
depend on it, point any build/config at it, or copy changes in from it.
Keep this sibling-repo note out of code and config comments — it belongs only here.

## Layout

- `photos_cleanup/library.py` — the PhotoKit helper client (`photokit` process, `load_photos`), candidate filter, time grouping, `swift_bin`
- `photos_cleanup/cli.py` — `photos-cleanup` entry point. Startup checks (macOS, UI built, port, Swift toolchain, Photos access) fail fast with clear messages. Keep it free of osxphotos imports so `--version`/`--help` stay fast and `brew test` works in its sandbox
- `photos_cleanup/server.py` — FastAPI server; serves the built UI (`photos_cleanup/ui/`, gitignored) plus the API on 127.0.0.1:8765. Same-origin only, no CORS: any website could otherwise call the API. Swift helpers compiled on first use into `~/Library/Caches/photos-cleanup`: `photokit.swift` (long-running, JSON lines: list, images, Vision prints/scores, album adds; built with `Info.plist` embedded, and must init `NSApplication` or `requestImage` returns nil) and `verdict.swift` (Foundation Models verdicts, fed exported JPEGs)
- `tests/test_server.py` — mocks the PhotoKit helper so tests run without a library or Swift
- `src/` — React UI; in dev, Vite proxies API paths to :8765
- Public docs: `README.md`, `CONTRIBUTING.md` (dev and release), `SECURITY.md`

## Dev

```bash
uv sync && pnpm install
pnpm build && uv run photos-cleanup      # serve the built UI
uv run photos-cleanup --dev & pnpm dev   # hot reload
uv run pytest -q                         # server tests
```
