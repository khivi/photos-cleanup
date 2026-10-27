# Photo Cleanup

A macOS app for reviewing and clearing out unwanted photos in your
Photos library. Scan the library, review a cleanup pass (screenshots, low
quality) as a thumbnail grid, keep/delete per photo, then move the flagged ones
into a "Delete Me" album in Photos — you do the actual delete there. Nothing is
ever deleted by the app; favorites and photos already in your albums are skipped.

## Architecture

A local Python FastAPI server serves the React UI and an HTTP API on
127.0.0.1; you use it in your browser. The server wraps the vendored
`photo_cleanup` engine and
[`osxphotos`](https://github.com/RhetTbull/osxphotos) to read the library and
move photos into albums. macOS-only (reads `Photos.sqlite`, drives Photos.app
via AppleScript).

## Run

```bash
uv sync && pnpm install
pnpm build                       # build the UI into dist/
uv run python sidecar/server.py  # serves http://127.0.0.1:8765 and opens it
```

The terminal that runs the server needs Full Disk Access (to read the
library). On the first commit, it also needs permission to control Photos.
See [TODO.md](TODO.md) for open items.

## Develop

```bash
uv run python sidecar/server.py --no-browser   # API on :8765
pnpm dev                                       # Vite with hot reload; proxies the API
uv run pytest -q
```
