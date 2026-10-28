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
   find Sources Package.swift Package.resolved -type f -not -path 'Sources/PhotosCleanup/ui/*' -newermt "$T"
   ```

   No output: the server is current. Rebuild the UI if needed (step 2), report the
   URL and stop. Output: `kill "$P"`, wait until `/health` stops answering, then
   continue. The UI is static files in the built resource bundle, read per request, so a
   UI change needs `pnpm build` and `swift build -c release`, but no restart. Verdicts are cached on disk, so a restart only loses in-flight
   classification time.
2. Rebuild the UI when `Sources/PhotosCleanup/ui/dist` is missing or older than `src/` or `index.html`:
   `[ -f Sources/PhotosCleanup/ui/dist/index.html ] && [ -z "$(find src index.html -newer Sources/PhotosCleanup/ui/dist/index.html)" ] || pnpm build`
3. Build the server (this also copies the built UI into the bundle): `swift build -c release`.
4. Start it with the Bash tool's `run_in_background`, so it outlives this turn:
   `.build/release/photos-cleanup --no-browser`
   (`swift run photos-cleanup` also works, but it is a debug build.)
   Opening the browser is the `open-browser` skill's job.
5. Poll `/health` for up to ~60s, then report the URL. The server reads the whole
   library before it listens; a large library takes a while.

The server fails fast with a clear message (port in use, Photos
access off, UI missing). On failure, read the background output. Photos access is granted by the user in System Settings → Privacy & Security → Photos;
Claude can't grant it.
