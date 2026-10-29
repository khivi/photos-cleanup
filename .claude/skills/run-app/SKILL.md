---
name: run-app
description: Build, sign and open the Photos Cleanup app from this checkout. TRIGGER when the user asks to run, start, open or restart the app.
---

# run-app

Run from the repo root.

1. Quit any running copy first, or `open -n` starts a second one beside it:
   `pkill -f "Photos Cleanup.app/Contents/MacOS/PhotosCleanupApp" || true`
   (it may be denied; then ask the user to quit it with Cmd-Q).
2. `scripts/app.sh run`: builds `.build/Photos Cleanup.app` (release), signs it ad hoc with
   the Photos entitlement, and opens it. Output goes to `/tmp/photos-cleanup-app.log`.
   Without `run` it only builds.
3. Report that it opened. Claude can't see the window: ask the user to check it.

Always run the app as a bundle. A bare binary from a shell never gets its window in front.
Photos access is granted by the user, once, in the macOS prompt or System Settings →
Privacy & Security → Photos. Claude can't grant it.
