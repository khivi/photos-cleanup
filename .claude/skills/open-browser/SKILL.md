---
name: open-browser
description: Open the photos-cleanup UI (http://127.0.0.1:8765) in the default browser. TRIGGER when the user asks to open, show or view the app.
---

# open-browser

1. Check the server: `curl -sf http://127.0.0.1:8765/health`.
   If it's down, run the `start-server` skill first.
2. `open http://127.0.0.1:8765/`

Use `127.0.0.1`, not a LAN IP or another hostname: the server rejects any
Host other than `127.0.0.1`/`localhost` (DNS-rebinding guard).
