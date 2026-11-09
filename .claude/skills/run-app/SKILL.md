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
2. Start `scripts/check-sandbox.sh watch` with `run_in_background`. Add `--hidden` to every `scripts/app.sh run` or `demo` below, so the app opens behind the user's windows without taking focus.
3. Demo part: quit any running copy, then follow its steps. Drive "Photos Cleanup Demo" with the `cmux-cua` tools (`launch_app` attaches to the running copy), and read the window state after each action. Find controls by their accessibility ids (`CONTRIBUTING.md` → Driving the app).
   - Every step is safe here, Delete in Photos… included: the demo never touches the user's library.
   - Export into a new folder under `/tmp`. The folder picker is a separate system panel. If you can't drive it, ask the user to pick the folder.
4. Library part: quit the demo, then follow its steps on "Photos Cleanup Dev".
   - Never click Delete in Photos… and never commit Delete Me. The app is working on the user's real library.
   - If Photos access or Automation access is not granted yet, stop and ask the user to allow it. Claude can't grant it.
5. Stop `watch`. Report every `deny` line with the part and step that caused it, or say there were none. Leave out the expected ones that `CONTRIBUTING.md` lists. Also list any step you couldn't drive.

Always run the app as a bundle. A bare binary from a shell never gets its window in front.
Photos access is granted by the user, once, in the macOS prompt or System Settings →
Privacy & Security → Photos. Claude can't grant it.
