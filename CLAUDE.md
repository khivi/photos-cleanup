# photos-cleanup

Local Python FastAPI server + React browser UI for reviewing and clearing
unwanted photos in the macOS Photos library. The app never deletes; it
moves flagged photos into a "Delete Me" album and the user deletes there.

## One codebase — the engine is vendored

All code lives in this one repo, built from one `pyproject.toml`. The
photo-scanning engine (`photo_cleanup`) is **vendored at `./photo_cleanup`** and
is the source of truth. The top-level pyproject builds and installs it
(`[tool.hatch.build.targets.wheel] packages = ["photo_cleanup", "photos_cleanup"]`); there is no
separate engine package and no external path dependency.

`../../photo-cleanup` is **reference-only** — the upstream repo the engine was
copied from. Do NOT import it, depend on it, or point any build/config at it.
When upstream changes and you want them, copy the files into `./photo_cleanup`
manually. Keep this sibling-repo note out of code and config comments — it
belongs only here.

## Layout

- `photo_cleanup/` — vendored engine (`common.py` is what the server uses)
- `photos_cleanup/cli.py` — `photos-cleanup` entry point. Startup checks (macOS, UI built, port, library, Full Disk Access) fail fast with clear messages. Keep it free of osxphotos imports so `--version`/`--help` stay fast and `brew test` works in its sandbox
- `photos_cleanup/server.py` — FastAPI server wrapping the engine; serves the built UI (`photos_cleanup/ui/`, gitignored) plus the API on 127.0.0.1:8765. Same-origin only, no CORS: any website could otherwise call the API. `photos_cleanup/verdict.swift` is the on-device verdict helper
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
