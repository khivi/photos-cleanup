# photos-cleanup

Tauri (Rust) shell + React webview + Python FastAPI sidecar for reviewing and
clearing unwanted photos in the macOS Photos library. The app never deletes; it
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

- `photo_cleanup/` — vendored engine (`common.py` is what the sidecar uses)
- `sidecar/server.py` — FastAPI sidecar wrapping the engine; `sidecar/test_server.py` mocks PhotosDB so tests run without Full Disk Access
- `src/` — React UI; `src-tauri/` — Rust shell that spawns the sidecar on a free port
- `scripts/build-sidecar.sh` — PyInstaller freeze for the bundled `.app`

## Dev

```bash
uv sync && pnpm install
pnpm tauri dev
uv run pytest -q     # sidecar tests
```
