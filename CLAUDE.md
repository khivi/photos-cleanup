# photos-cleanup

Local Python FastAPI server + React browser UI for reviewing and clearing
unwanted photos in the macOS Photos library. The app never deletes; it
moves flagged photos into a "Delete Me" album and the user deletes there.

## One codebase — the engine is vendored

All code lives in this one repo, built from one `pyproject.toml`. The
photo-scanning engine (`photo_cleanup`) is **vendored at `./photo_cleanup`** and
is the source of truth. The top-level pyproject builds and installs it
(`[tool.hatch.build.targets.wheel] packages = ["photo_cleanup"]`); there is no
separate engine package and no external path dependency.

`../../photo-cleanup` is **reference-only** — the upstream repo the engine was
copied from. Do NOT import it, depend on it, or point any build/config at it.
When upstream changes and you want them, copy the files into `./photo_cleanup`
manually. Keep this sibling-repo note out of code and config comments — it
belongs only here.

## Layout

- `photo_cleanup/` — vendored engine (`common.py` is what the server uses)
- `sidecar/server.py` — FastAPI server wrapping the engine; serves the built UI (`dist/`) plus the API on 127.0.0.1:8765 and opens the browser. Same-origin only, no CORS: any website could otherwise call the API. `sidecar/test_server.py` mocks PhotosDB so tests run without Full Disk Access
- `src/` — React UI; in dev, Vite proxies API paths to :8765

## Dev

```bash
uv sync && pnpm install
uv run python sidecar/server.py --no-browser & pnpm dev   # dev with hot reload
pnpm build && uv run python sidecar/server.py            # serve the built UI
uv run pytest -q     # server tests
```
