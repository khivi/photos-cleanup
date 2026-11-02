# photos-cleanup

A native macOS app (SwiftUI) for reviewing and clearing unwanted photos in the
Photos library. It moves flagged photos into a "Delete Me" album. It deletes only
those photos, only when the user clicks Delete in Photos…, after macOS confirms; Photos
keeps them in Recently Deleted for 30 days.

## One Swift package

All code is one SwiftPM package (`Package.swift`) with no dependencies. There is no
server, no web UI, no Node and no Python. Every Photos library access goes through
PhotoKit in `PhotosCleanupCore`. No osxphotos, no Full Disk Access.

`../../photo-cleanup` is a separate project: the command-line tool this app's
library code was taken from. The app no longer tracks it. Do NOT import it,
depend on it, point any build/config at it, or copy changes in from it.
Keep this sibling-repo note out of code and config comments — it belongs only here.

## Layout

- `Sources/PhotosCleanupCore/` — no UI framework. `Library.swift`: PhotoKit and Vision behind the `PhotoLibrary` protocol. `Verdicts.swift`: Foundation Models behind `Judge`. `Passes.swift`: pass names, tooltips, thresholds, candidate filter, time grouping. `Cleanup.swift`: the `Cleanup` actor (photo list, Vision job, verdict queue, commits, caches). `Review.swift`: `ReviewModel`, the screen's state and every label it shows
- `Sources/PhotosCleanupApp/` — the SwiftUI app: views only, no decisions. `Thumbnails.swift`: `PHCachingImageManager` with settings measured in the grid spike (`feea7cb`; removed, see git history). `Info.plist` holds the release version; `PhotosCleanup.entitlements` the Photos entitlement the hardened runtime requires; `AppIcon.svg` the icon
- `Sources/photos-import/` — `swift run photos-import <dir> [--dry-run]`: sorts a folder into `<dir>/Done/` (in the library, or a copy of a file that is) and `<dir>/Import/` (to drag into Photos), paths mirrored; `Import/Check date/` holds files with no camera date, which Photos would date by file creation. A rerun moves what `Import/` now has in the library to `Done/`. In library: same pixel size and capture time (`LibraryIndex` in `ImportMatch.swift`); a time-zone offset counts only with the same file name or the same 16×16 thumbnail. Delete Me photos count as not in the library. Writes `/tmp/photos-import.tsv`. `--skip <subdir>`: a library export, never moved, whose photos (and their copies elsewhere) are never new. Never writes to the library. Photos access goes to the terminal
- `Sources/photos-export/` — `swift run photos-export <dest> [--dry-run]`: incremental backup of the library's originals, edits and Live Photo videos into `<dest>/YYYY/MM`. `<dest>/.photos-export.tsv` (`ExportManifest` in `Export.swift`) records each photo's modification date and file stem, so a rerun copies only new or changed photos. Never deletes from `<dest>`: photos gone from the library stay, for `photos-import --skip`. Downloads iCloud originals
- `scripts/app.sh` — builds, bundles and signs `.build/Photos Cleanup.app`; `run` opens it. A bare binary from a shell never gets its window in front
- `Tests/` — Core tests with a fake `PhotoLibrary` and `Judge`, so they run without a library or Apple Intelligence
- Public docs: `README.md`, `CONTRIBUTING.md` (dev and release), `SECURITY.md`, `ARCHITECTURE.md`

## Naming a pass

A pass has exactly one name, set in `Passes.all` in `Sources/PhotosCleanupCore/Passes.swift`: the key (`bursts`) is the
view and the `decisions.jsonl` kind; the title (`Bursts`) is the tab label and the album prefix. Its
albums are always `<Title> - Delete Me` and `<Title> - Keep`, derived from the title,
never written out. No synonyms: not "clusters" for Bursts, not "Review Me" for an album.
`everyPassHasOneName` (Swift Core tests) enforces this, including the app's tab labels (`ReviewModel.tabs`).

Renaming a pass whose albums already exist in users' libraries: add the old album names
to `Passes.legacyAlbums`, so photos filed under them don't come back as candidates, and
a changed key to `Passes.legacyKeys`.

## Dev

```bash
scripts/app.sh run     # build, sign ad hoc, open; log in /tmp/photos-cleanup-app.log
swift test             # Core tests
```
