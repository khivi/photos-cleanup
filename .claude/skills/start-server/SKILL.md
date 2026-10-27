---
name: start-server
description: Start the photos-cleanup server (UI + API on 127.0.0.1:8765) in the background. TRIGGER when the user asks to start, run or restart the server or app.
---

# start-server

Run from the repo root.

1. If something already answers, report it and stop:
   `curl -sf http://127.0.0.1:8765/health`
2. Rebuild the UI when `dist/` is missing or older than `src/`:
   `[ -d dist ] && [ -z "$(find src index.html -newer dist/index.html)" ] || pnpm build`
3. Start it with the Bash tool's `run_in_background`, so it outlives this turn:
   `uv run python sidecar/server.py --no-browser`
   Opening the browser is the `open-browser` skill's job.
4. Poll `/health` for up to ~10s, then report the URL.

On failure, read the background output. A library-load error usually means the
terminal running Claude Code lacks Full Disk Access (System Settings → Privacy
& Security). The user must grant it; Claude can't.
