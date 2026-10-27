# TODO

## Packaging

Tauri + PyInstaller `.app` dropped 2026-10-27: the app is now a local FastAPI server serving the React UI to the browser (see README). No `.app` means nothing to sign or notarize. Full Disk Access and Photos automation go to whichever terminal runs the server.

- [ ] **Installable package** — put the built `dist/` inside the wheel (hatch `force-include`) and package `sidecar/` with a `[project.scripts]` entry point. Then `uv tool install git+https://github.com/khivi/photos-cleanup` works.
- [ ] **Homebrew tap (optional, after the above)** — formula in `khivi/homebrew-tap` using `virtualenv_install_with_resources`; regenerate resources with `brew update-python-resources`. homebrew-core is unlikely to accept it.

## Native SwiftUI rewrite — DECIDED, gated on learning SwiftUI (2026-07-22)

Chosen end-state: rebuild as one native **SwiftUI + PhotoKit + Vision** app — drop the browser UI, the Python server, and osxphotos entirely. Opens the App Store, swaps Full Disk Access for a normal Photos permission, makes album writes native (`PHAssetCollectionChangeRequest`, no AppleScript), single signed binary. Not starting yet — learning SwiftUI first. Evidence lives in `spike/` (run against the real 6.6k-photo library):

- **low-quality survives natively** — `VNCalculateImageAestheticsScoresRequest.overallScore` vs osxphotos `score.overall`: Spearman **rho 0.91**, worst-decile overlap 70%. Near-identical ranking; a native pass just needs its own threshold.
- **screenshots/documents get a free native signal** — Vision's `isUtility` flag fired on 19% of photos (screenshots/receipts/docs).
- **similar survives and upgrades** — osxphotos `.fingerprint` is a 28-char content fingerprint, not perceptual: it only finds near-identical dupes (3 clusters in the whole library; 0 of 1.1M random pairs > 50%). Vision feature-print distance catches those exact dupes (0.0–0.35) with a clean margin to random pairs (0.70+), and adds the graded visual similarity osxphotos never had.

Net: nothing is lost in the rewrite; two passes improve. This overturns the "data gap" pessimism recorded below (kept as the record of why the *Python* stack can't reach the App Store).

Dev workflow when we start: install Xcode, keep it open on a second display purely as a live preview canvas — do all editing and building from Claude Code. Once the layout reflex is there (~two weeks, not two months), drop to xcodegen + Inject for hot-reload and stop opening Xcode.

- [x] **Xcode installed (2026-07-22)** — step one done. Next (khivi, keyboard): make a throwaway macOS SwiftUI app in Xcode, toggle the Canvas preview, drill `Text`/`VStack`/`HStack`/`LazyVGrid`/`Image(systemName:)` until the layout reflex sticks. Then signal "start" and Claude scaffolds the real single-target SwiftUI + PhotoKit project.

## Distribution: Mac App Store — BLOCKED (sandbox kills the PyInstaller sidecar)

Investigated + spiked 2026-07-21 against the former Tauri + PyInstaller build; the osxphotos walls below still apply to the Python server. Not viable without a rewrite. Evidence from the spike (real sidecar, ad-hoc signed with `app-sandbox` + `personal-information.photos-library` + `temporary-exception.apple-events` for `com.apple.Photos`):

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

- [ ] **GitHub Actions** — macOS runner: `uv run pytest -q` + `pnpm build`. macOS-only app (osxphotos / Photos.app / AppleScript), so no Windows/Linux targets.

## App

- [ ] **Live "To be deleted"** — read the delete/review albums back from Photos so the tab survives restarts (currently session-scoped, client-side).
- [ ] **Tune screenshot verdicts** — the delete-trusted kinds (receipt, ticket, app/chat screenshot, meme) come from the 300-photo spike. The model's `reason` sometimes contradicts its `keep` (parrots the instructions). Editing `sidecar/verdict.swift` re-judges everything (the cache file is keyed to its hash).
- [ ] **Recheck kept photos when the on-device model improves** — a pass's "Keep" album is the record of what was kept. Load it (hidden from candidates today), re-classify bypassing the verdict cache (keyed to `verdict.swift`'s hash, so an OS model update alone doesn't invalidate it — key on the OS build too), show only new delete verdicts, and on commit move them Keep → Delete Me (needs album-removal code). Wait for an actual model update first.
- [ ] **More passes** — clusters / similar / edited / documents; the grouped ones need a "keep best per group" review UI.
- [ ] **"Keep photos in albums" toggle** — persisted setting (default on) that surfaces the *existing* default: candidates already skip any photo in a user-created album (`is_in_user_album`). "Off" needs custom candidate logic to *include* album photos. Decide how iCloud Shared Albums count — osxphotos may report them outside `photo.albums`.
