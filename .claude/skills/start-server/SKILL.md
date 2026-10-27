---
name: start-server
description: Start the photos-cleanup server (UI + API on 127.0.0.1:8765) in the background. TRIGGER when the user asks to start, run or restart the server or app.
---

# start-server

Run from the repo root.

1. If something already answers, report it and stop:
   `curl -sf http://127.0.0.1:8765/health`
2. Rebuild the UI when `photos_cleanup/ui/` is missing or older than `src/` or `index.html`:
   `[ -f photos_cleanup/ui/index.html ] && [ -z "$(find src index.html -newer photos_cleanup/ui/index.html)" ] || pnpm build`
3. Start it with the Bash tool's `run_in_background`, so it outlives this turn:
   `uv run photos-cleanup --no-browser`
   Opening the browser is the `open-browser` skill's job.
4. Poll `/health` for up to ~60s, then report the URL. The server reads the whole
   library before it listens; a large library takes a while.

The server fails fast with a clear message (port in use, no library, Full Disk
Access off, UI missing). On failure, read the background output. Full Disk
Access is granted by the user in System Settings → Privacy & Security; Claude
can't grant it.
