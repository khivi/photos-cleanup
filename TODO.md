# TODO

## Packaging
- [ ] **Local `.app` (in progress)** — PyInstaller sidecar + Tauri `externalBin`, ad-hoc signed. Runs on this Mac; permissions may need re-granting on rebuild.
- [ ] **Shareable build** — Apple Developer ID ($99/yr) sign the `.app` + sidecar, then notarize (`notarytool`) + staple. Needed to run on other Macs without Gatekeeper friction, and so TCC grants (Full Disk Access, Automation) survive rebuilds. Add Hardened Runtime entitlements (`com.apple.security.automation.apple-events`, likely `disable-library-validation` for PyInstaller dylibs).

## Distribution: publish on the Mac App Store
Decided path (2026-07-21). The $99/yr membership covers both this and Developer ID. Open questions to resolve before submitting:
- [ ] **Sandbox** — App Store requires the App Sandbox entitlement (`com.apple.security.app-sandbox`). Verify osxphotos + Photos.app access + AppleScript automation work sandboxed; may need `com.apple.security.personal-information.photos-library` and user-selected file entitlements. This is the biggest risk — a PyInstaller sidecar shelling out / AppleScripting may not survive the sandbox.
- [ ] **Sidecar signing** — the embedded Python sidecar and all its dylibs must be signed with the App Store distribution cert and satisfy library validation (no `disable-library-validation` allowed in the sandbox). Confirm PyInstaller output passes.
- [ ] **App Store Connect** — create the app record, bundle ID, screenshots, privacy nutrition labels (this app reads the whole photo library — declare it), review notes explaining the delete/review workflow.
- [ ] **Fallback** — if sandboxing blocks osxphotos/AppleScript, fall back to Developer ID + notarized direct download (the "Shareable build" item above).

## CI
- [ ] **GitHub Actions build** — matrix over the two Mac targets (`aarch64-apple-darwin`, `x86_64-apple-darwin`), producing a universal `.app`/`.dmg`. NOTE: macOS-only app (osxphotos / Photos.app / AppleScript) — no Windows/Linux targets are possible. Needs signing secrets for the shareable path.

## App
- [ ] **`/reload` endpoint** — clear the sidecar's db()/_index() caches to re-read the library mid-session without an app restart (also noted in sidecar/server.py).
- [ ] **Live "To be deleted"** — read the delete/review albums back from Photos so the tab survives restarts (currently session-scoped, client-side).
- [ ] **More passes** — clusters / similar / edited / documents; the grouped ones need a "keep best per group" review UI.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`is_in_user_album`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
