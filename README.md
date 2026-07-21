# Photo Cleanup

A macOS desktop app for reviewing and clearing out unwanted photos in your
Photos library. Scan the library, review a cleanup pass (screenshots, low
quality) as a thumbnail grid, keep/delete per photo, then move the flagged ones
into a "Delete Me" album in Photos — you do the actual delete there. Nothing is
ever deleted by the app; favorites and photos already in your albums are skipped.

## Architecture

Tauri (Rust) shell that spawns a Python FastAPI sidecar. The webview talks HTTP
to the sidecar, which wraps the [`photo-cleanup`](../photo-cleanup) engine and
[`osxphotos`](https://github.com/RhetTbull/osxphotos) to read the library and
move photos into albums. macOS-only (reads `Photos.sqlite`, drives Photos.app
via AppleScript).

## Develop

```bash
uv sync                 # Python sidecar deps
pnpm install            # frontend deps
pnpm tauri dev          # run the app
```

Requires Full Disk Access (to read the library) and, on first commit, permission
to control Photos. See [TODO.md](TODO.md) for packaging and open items.

## Build a local .app

```bash
scripts/build-sidecar.sh   # freeze the Python sidecar (PyInstaller)
pnpm tauri build           # bundle + ad-hoc sign -> .app + .dmg
```
