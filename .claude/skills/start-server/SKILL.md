---
name: start-server
description: Start the photos-cleanup server (UI + API on 127.0.0.1:8765) in the background, restarting it if it runs code older than the checkout. TRIGGER when the user asks to start, run or restart the server or app.
---

# start-server

Run from the repo root.

1. If something already answers, check whether it runs stale code:

   ```bash
   P=$(lsof -ti tcp:8765 -sTCP:LISTEN)
   T=$(date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p "$P" | xargs)" +%FT%T)
   find photos_cleanup pyproject.toml uv.lock -name '*.py' -newermt "$T" -o -name '*.toml' -newermt "$T" -o -name uv.lock -newermt "$T"
   ```

   No output: the server is current. Rebuild the UI if needed (step 2), report the
   URL and stop. Output: `kill "$P"`, wait until `/health` stops answering, then
   continue. The UI is static files read from disk, so a UI change never needs a
   restart. Swift helpers recompile themselves when their source changes. Verdicts
   are cached on disk, so a restart only loses in-flight classification time.
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
