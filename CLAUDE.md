# photos-cleanup

Local Python FastAPI server + React browser UI for reviewing and clearing
unwanted photos in the macOS Photos library. The app never deletes; it
moves flagged photos into a "Delete Me" album and the user deletes there.

## One package

All code is the `photos_cleanup` package, built from one `pyproject.toml`.
Library reads (osxphotos) live only in `photos_cleanup/library.py`.

`../../photo-cleanup` is a separate project: the command-line tool this app's
library code was taken from. The app no longer tracks it. Do NOT import it,
depend on it, point any build/config at it, or copy changes in from it.
Keep this sibling-repo note out of code and config comments — it belongs only here.

## Layout

- `photos_cleanup/library.py` — every osxphotos call: candidate filter, scores, time grouping, AppleScript album fallback
- `photos_cleanup/cli.py` — `photos-cleanup` entry point. Startup checks (macOS, UI built, port, library, Full Disk Access) fail fast with clear messages. Keep it free of osxphotos imports so `--version`/`--help` stay fast and `brew test` works in its sandbox
- `photos_cleanup/server.py` — FastAPI server; serves the built UI (`photos_cleanup/ui/`, gitignored) plus the API on 127.0.0.1:8765. Same-origin only, no CORS: any website could otherwise call the API. Swift helpers it compiles on first use: `verdict.swift` (Foundation Models verdicts), `featureprint.swift` (Vision similarity), `albums.swift` (PhotoKit album writes, built with `Info.plist` embedded)
- `tests/test_server.py` — mocks PhotosDB so tests run without Full Disk Access
- `src/` — React UI; in dev, Vite proxies API paths to :8765
- Public docs: `README.md`, `CONTRIBUTING.md` (dev and release), `SECURITY.md`

## Dev

```bash
uv sync && pnpm install
pnpm build && uv run photos-cleanup      # serve the built UI
uv run photos-cleanup --dev & pnpm dev   # hot reload
uv run pytest -q                         # server tests
```
