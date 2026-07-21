# TODO

## Packaging
- [ ] **Local `.app` (in progress)** — PyInstaller sidecar + Tauri `externalBin`, ad-hoc signed. Runs on this Mac; permissions may need re-granting on rebuild.

## Distribution: Developer ID + notarized direct download (PRIMARY PATH)
Chosen path (spike 2026-07-21). Works with the existing PyInstaller sidecar unchanged — no sandbox. Needs the $99/yr Apple Developer membership (also covers Developer ID).
- [ ] **Shareable build** — Developer ID sign the `.app` + sidecar, then notarize (`notarytool`) + staple. Needed to run on other Macs without Gatekeeper friction, and so TCC grants (Full Disk Access, Automation) survive rebuilds. Add Hardened Runtime entitlements (`com.apple.security.automation.apple-events`, likely `disable-library-validation` for PyInstaller dylibs). Distribute as `.dmg`/`.zip` from the site.

## Distribution: Mac App Store — BLOCKED (sandbox kills the PyInstaller sidecar)
Investigated + spiked 2026-07-21. Not viable without a rewrite. Evidence from the spike (real sidecar, ad-hoc signed with `app-sandbox` + `personal-information.photos-library` + `temporary-exception.apple-events` for `com.apple.Photos`):
- Unsandboxed baseline reads fine: 9220 photos / 21.8 GB in ~6s.
- **onefile** in a sandboxed `.app`: dies at PyInstaller bootloader — `semctl: Operation not permitted`. Sandbox denies the SysV semaphore onefile needs. Python never starts.
- **onedir**: does NOT hit the semaphore (different bootstrap) but couldn't be cleanly verified — needs a properly structured `.app` (exec in `MacOS/`, dylibs in `Frameworks/`, `.dist-info` dirs cleaned for `codesign --deep`). In-place ad-hoc run SIGTRAPs (133) at sandbox init.
- Even past boot, three unresolved walls remain: (1) osxphotos raw-reads `Photos.sqlite` — the sandbox is built to block this, Apple wants PhotoKit; (2) Apple Events to Photos.app need a `temporary-exception` entitlement reviewers can reject; (3) whole read path bypasses PhotoKit.
- [ ] **Only revisit if** rebuilding the photo layer natively in Swift/PhotoKit (drops the Python/osxphotos sidecar — effectively a different app).

### PhotoKit rewrite cost (if App Store is ever pursued)
The blocker is a **data gap, not speed**. PhotoKit is backed by the same store, lazy, and native — for the fields we show (count, date, dims, filesize, screenshot flag) it's as fast or faster than osxphotos, and enumerate-once-into-our-own-SQLite makes steady-state identical. What breaks:
- **screenshots pass survives** — `PHAsset.mediaSubtypes` has `.photoScreenshot`.
- **low-quality pass breaks** — it relies on `common.get_photo_score()` (osxphotos `.score`, Photos' private aesthetic-scoring sqlite columns). PhotoKit does **not** expose this. A rewrite would have to compute our own quality heuristic (Vision/Core Image blur+exposure on pixels — real work, won't match Photos' scores).
- "Keep our own sqlite" is a speed win only; under the sandbox we can't copy Photos' sqlite, so the cache can only hold what PhotoKit gives — which never includes the score.

Full audit of the original engine (`../../photo-cleanup/photo_cleanup`, all passes) vs PhotoKit:

| osxphotos feature | Used by | PhotoKit |
|---|---|---|
| `date`, `uuid`, `width/height`, `favorite`, `ismovie`, `screenshot`, `live_photo` | candidate filter + all passes | ✅ direct (`creationDate`, `localIdentifier`, `pixelWidth/Height`, `isFavorite`, `mediaType`, `mediaSubtypes`) |
| `albums` membership | `is_in_user_album` filter | ✅ derivable via collection fetch |
| thumbnails (`path_derivatives`) | grid | ✅ better — `PHImageManager.requestImage` (no filesystem) |
| create/populate albums (`PhotosAlbum.add`) | every commit | ✅ **native** `PHAssetCollectionChangeRequest` — **removes the Apple Events wall** |
| `original_filename` | display, heic | ⚠️ indirect — `PHAssetResource.originalFilename` |
| `original_filesize` | size totals, heic | ⚠️ indirect/awkward — via `PHAssetResource` |
| `hasadjustments` | **edited** pass | ⚠️ no clean bool — infer from `.adjustmentData` resource |
| **`score.overall`** (aesthetic) | **low-quality** + **clusters** (keeper ranking) | ❌ not exposed → recompute (custom blur/exposure heuristic) |
| **`labels`** (scene classification) | **documents** pass | ❌ not exposed → recompute (`VNClassifyImageRequest` + OCR per image) |
| **`fingerprint`** (perceptual hash) | **similar** pass | ❌ not exposed → recompute (`VNGenerateImageFeaturePrintRequest` / pHash) |

Common thread: every "Apple already computed this" value (aesthetic score, scene labels, perceptual fingerprint) lives in the private sqlite and is **not** in PhotoKit — a rewrite re-derives all three with Vision (won't byte-match Apple's). Passes that survive on intrinsic metadata alone: **screenshots** and read-only **heic estimate** (**clusters** keeps its time-grouping but loses score-based keeper ranking). Upside: the album **write** path goes native, killing the Apple Events reviewer wall — but that doesn't offset losing the three computed signals.

## CI
- [ ] **GitHub Actions build** — matrix over the two Mac targets (`aarch64-apple-darwin`, `x86_64-apple-darwin`), producing a universal `.app`/`.dmg`. NOTE: macOS-only app (osxphotos / Photos.app / AppleScript) — no Windows/Linux targets are possible. Needs signing secrets for the shareable path.

## App
- [ ] **`/reload` endpoint** — clear the sidecar's db()/_index() caches to re-read the library mid-session without an app restart (also noted in sidecar/server.py).
- [ ] **Live "To be deleted"** — read the delete/review albums back from Photos so the tab survives restarts (currently session-scoped, client-side).
- [ ] **More passes** — clusters / similar / edited / documents; the grouped ones need a "keep best per group" review UI.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`is_in_user_album`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
