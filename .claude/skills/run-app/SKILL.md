---
name: run-app
description: Build, sign and open the Photos Cleanup app from this checkout, and run the sandbox check by driving it. TRIGGER when the user asks to run, start, open or restart the app, or for a sandbox check.
---

# run-app

Run from the repo root.

1. Quit any running copy first, or `open -n` starts a second one beside it:
   `pkill -f "Photos Cleanup.app/Contents/MacOS/PhotosCleanupApp" || true`
   (it may be denied; then ask the user to quit it with Cmd-Q).
2. `scripts/app.sh run`: builds `.build/Photos Cleanup.app` (release), signs it ad hoc as "Photos Cleanup Dev" in the App Sandbox with
   the Photos entitlement, and opens it. Output goes to `/tmp/photos-cleanup-app.log`.
   Without `run` it only builds.
3. Report that it opened. Claude can't see the window: ask the user to check it.

## Sandbox check

Run when the user asks for a sandbox check, or before a release. These are the steps in `CONTRIBUTING.md` → Sandbox check, with Claude driving the app.

1. Run `scripts/check-sandbox.sh entitlements`. Stop if it fails.
2. Start `scripts/check-sandbox.sh watch` with `run_in_background`, then do steps 1–2 above.
3. Drive "Photos Cleanup Dev" with the `cmux-cua` tools (`launch_app` attaches to the running copy). Follow `CONTRIBUTING.md` steps 3–8, and read the window state after each action.
   - Export into a new folder under `/tmp`, and add a folder under `/tmp` for Import. The folder picker is a separate system panel. If you can't drive it, ask the user to pick the folder.
   - Never click Delete in Photos… and never commit Delete Me. The app is working on the user's real library.
   - If Photos access or Automation access is not granted yet, stop and ask the user to allow it. Claude can't grant it.
4. Stop `watch`. Report every `deny` line with the step that caused it, or say there were none. Also list any step you couldn't drive.

Always run the app as a bundle. A bare binary from a shell never gets its window in front.
Photos access is granted by the user, once, in the macOS prompt or System Settings →
Privacy & Security → Photos. Claude can't grant it.
