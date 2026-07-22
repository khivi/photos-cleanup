# TODO

## Packaging
- [ ] **Local `.app` (in progress)** — PyInstaller sidecar + Tauri `externalBin`, ad-hoc signed. Runs on this Mac; permissions may need re-granting on rebuild.

## Distribution: Developer ID + notarized direct download (PRIMARY PATH)
Chosen path (spike 2026-07-21). Works with the existing PyInstaller sidecar unchanged — no sandbox. Needs the $99/yr Apple Developer membership (also covers Developer ID).
- [ ] **Shareable build** — Developer ID sign the `.app` + sidecar, then notarize (`notarytool`) + staple. Needed to run on other Macs without Gatekeeper friction, and so TCC grants (Full Disk Access, Automation) survive rebuilds. Add Hardened Runtime entitlements (`com.apple.security.automation.apple-events`, likely `disable-library-validation` for PyInstaller dylibs). Distribute as `.dmg`/`.zip` from the site.

## Native SwiftUI rewrite — DECIDED, gated on learning SwiftUI (2026-07-22)
Chosen end-state: rebuild as one native **SwiftUI + PhotoKit + Vision** app — drop Tauri, React, the Python sidecar, and osxphotos entirely. Opens the App Store, swaps Full Disk Access for a normal Photos permission, makes album writes native (`PHAssetCollectionChangeRequest`, no AppleScript), single signed binary. Not starting yet — learning SwiftUI first. Evidence lives in `spike/` (run against the real 6.6k-photo library):
- **low-quality survives natively** — `VNCalculateImageAestheticsScoresRequest.overallScore` vs osxphotos `score.overall`: Spearman **rho 0.91**, worst-decile overlap 70%. Near-identical ranking; a native pass just needs its own threshold.
- **screenshots/documents get a free native signal** — Vision's `isUtility` flag fired on 19% of photos (screenshots/receipts/docs).
- **similar survives and upgrades** — osxphotos `.fingerprint` is a 28-char content fingerprint, not perceptual: it only finds near-identical dupes (3 clusters in the whole library; 0 of 1.1M random pairs > 50%). Vision feature-print distance catches those exact dupes (0.0–0.35) with a clean margin to random pairs (0.70+), and adds the graded visual similarity osxphotos never had.

Net: nothing is lost in the rewrite; two passes improve. This overturns the "data gap" pessimism recorded below (kept as the record of why the *Python* stack can't reach the App Store).

## Distribution: Mac App Store — BLOCKED (sandbox kills the PyInstaller sidecar)
Investigated + spiked 2026-07-21. Not viable without a rewrite. Evidence from the spike (real sidecar, ad-hoc signed with `app-sandbox` + `personal-information.photos-library` + `temporary-exception.apple-events` for `com.apple.Photos`):
- Unsandboxed baseline reads fine: 9220 photos / 21.8 GB in ~6s.
- **onefile** in a sandboxed `.app`: dies at PyInstaller bootloader — `semctl: Operation not permitted`. Sandbox denies the SysV semaphore onefile needs. Python never starts.
- **onedir**: does NOT hit the semaphore (different bootstrap) but couldn't be cleanly verified — needs a properly structured `.app` (exec in `MacOS/`, dylibs in `Frameworks/`, `.dist-info` dirs cleaned for `codesign --deep`). In-place ad-hoc run SIGTRAPs (133) at sandbox init.
- Even past boot, three unresolved walls remain: (1) osxphotos raw-reads `Photos.sqlite` — the sandbox is built to block this, Apple wants PhotoKit; (2) Apple Events to Photos.app need a `temporary-exception` entitlement reviewers can reject; (3) whole read path bypasses PhotoKit.
- [ ] **Only revisit if** rebuilding the photo layer natively in Swift/PhotoKit (drops the Python/osxphotos sidecar — effectively a different app).

### PhotoKit rewrite cost (if App Store is ever pursued)
Originally feared a **data gap** (PhotoKit doesn't expose Apple's private score/labels/fingerprint). The 2026-07-22 spikes disproved this — Vision recomputes those signals faithfully (see the decision section above). PhotoKit is backed by the same store, lazy, and native — for the fields we show (count, date, dims, filesize, screenshot flag) it's as fast or faster than osxphotos. Status of each pass:
- **screenshots pass survives** — `PHAsset.mediaSubtypes` has `.photoScreenshot` (and Vision `isUtility` as a cross-check).
- **low-quality pass survives** — spike-proven: `VNCalculateImageAestheticsScoresRequest.overallScore` reproduces osxphotos `score.overall` at rho 0.91. Not a byte-match to Apple's private score, but the *ranking* — all the pass needs — holds.
- **similar pass survives + upgrades** — Vision feature prints reproduce osxphotos' dupe grouping and add real graded visual similarity (spike-proven).

Full audit of the vendored engine (`./photo_cleanup`, all passes) vs PhotoKit:

| osxphotos feature | Used by | PhotoKit |
|---|---|---|
| `date`, `uuid`, `width/height`, `favorite`, `ismovie`, `screenshot`, `live_photo` | candidate filter + all passes | ✅ direct (`creationDate`, `localIdentifier`, `pixelWidth/Height`, `isFavorite`, `mediaType`, `mediaSubtypes`) |
| `albums` membership | `is_in_user_album` filter | ✅ derivable via collection fetch |
| thumbnails (`path_derivatives`) | grid | ✅ better — `PHImageManager.requestImage` (no filesystem) |
| create/populate albums (`PhotosAlbum.add`) | every commit | ✅ **native** `PHAssetCollectionChangeRequest` — **removes the Apple Events wall** |
| `original_filename` | display, heic | ⚠️ indirect — `PHAssetResource.originalFilename` |
| `original_filesize` | size totals, heic | ⚠️ indirect/awkward — via `PHAssetResource` |
| `hasadjustments` | **edited** pass | ⚠️ no clean bool — infer from `.adjustmentData` resource |
| **`score.overall`** (aesthetic) | **low-quality** + **clusters** (keeper ranking) | ✅ spike-proven — `VNCalculateImageAestheticsScoresRequest.overallScore` reproduces the ranking (rho 0.91) |
| **`labels`** (scene classification) | **documents** pass | ⚠️ Vision `isUtility` covers docs/receipts directly; `VNClassifyImageRequest` for full labels |
| **`fingerprint`** (perceptual hash) | **similar** pass | ✅ spike-proven — `VNGenerateImageFeaturePrintRequest` distance reproduces dupes + adds real similarity |

Common thread (updated post-spike): every "Apple already computed this" value (aesthetic score, scene labels, perceptual fingerprint) lives in the private sqlite and is **not** in PhotoKit — but Vision re-derives all three on-device and, per the spikes, reproduces the rankings/grouping the passes actually depend on (it won't byte-match Apple's, and doesn't need to). **clusters** keeps its time-grouping and regains score-based keeper ranking via the Vision aesthetics score. Upside stacks: the album **write** path also goes native, killing the Apple Events reviewer wall.

## CI
- [ ] **GitHub Actions build** — matrix over the two Mac targets (`aarch64-apple-darwin`, `x86_64-apple-darwin`), producing a universal `.app`/`.dmg`. NOTE: macOS-only app (osxphotos / Photos.app / AppleScript) — no Windows/Linux targets are possible. Needs signing secrets for the shareable path.

## App
- [ ] **`/reload` endpoint** — clear the sidecar's db()/_index() caches to re-read the library mid-session without an app restart (also noted in sidecar/server.py).
- [ ] **Live "To be deleted"** — read the delete/review albums back from Photos so the tab survives restarts (currently session-scoped, client-side).
- [ ] **More passes** — clusters / similar / edited / documents; the grouped ones need a "keep best per group" review UI.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`is_in_user_album`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
