# photos-cleanup

Local Swift (Hummingbird) server + React browser UI for reviewing and clearing
unwanted photos in the macOS Photos library. The app never deletes; it
moves flagged photos into a "Delete Me" album and the user deletes there.

## One Swift package

All code is one SwiftPM package (`Package.swift`) plus the React UI in `src/`.
There is no Python, no uv and no PyPI. The server is Hummingbird; every Photos library
access goes through PhotoKit in `PhotosCleanupCore`. No osxphotos, no Full Disk Access.

`../../photo-cleanup` is a separate project: the command-line tool this app's
library code was taken from. The app no longer tracks it. Do NOT import it,
depend on it, point any build/config at it, or copy changes in from it.
Keep this sibling-repo note out of code and config comments — it belongs only here.

## Layout

- `Sources/PhotosCleanupCore/` — pure Swift, no web framework (a native app could reuse it). `Library.swift`: PhotoKit and Vision behind the `PhotoLibrary` protocol. `Verdicts.swift`: Foundation Models behind `Judge`. `Passes.swift`: pass names, thresholds, candidate filter, time grouping. `Cleanup.swift`: the `Cleanup` actor (photo list, Vision job, verdict queue, commits, caches)
- `Sources/PhotosCleanupServer/Routes.swift` — Hummingbird routes, JSON, Host allowlist, static UI. Same-origin only, no CORS: any website could otherwise call the API
- `Sources/PhotosCleanup/main.swift` — the `photos-cleanup` executable: `let version`, startup checks (port, Photos access), then the server. It sets up `NSApplication` (no Dock icon) or `requestImage` returns nil. `Info.plist` is embedded by linker flags in `Package.swift`. The built UI is a SwiftPM resource at `Sources/PhotosCleanup/ui/dist` (gitignored; `pnpm build` writes it)
- `Tests/` — Core and server tests with a fake `PhotoLibrary` and `Judge`, so they run without a library or Apple Intelligence
- `src/` — React UI; in dev, Vite proxies API paths to :8765
- Public docs: `README.md`, `CONTRIBUTING.md` (dev and release), `SECURITY.md`, `ARCHITECTURE.md`

## Naming a pass

A pass has exactly one name, set in `Passes.all` in `Sources/PhotosCleanupCore/Passes.swift`: the key (`bursts`) is the
URL and the UI view; the title (`Bursts`) is the tab label and the album prefix. Its
albums are always `<Title> - Delete Me` and `<Title> - Keep`, derived from the title,
never written out. No synonyms: not "clusters" for Bursts, not "Review Me" for an album.
`everyPassHasOneName` (Swift Core tests) enforces this, including the tab labels in `App.tsx`.

Renaming a pass whose albums already exist in users' libraries: add the old album names
to `Passes.legacyAlbums`, so photos filed under them don't come back as candidates.

## Dev

```bash
pnpm install && pnpm build
swift run photos-cleanup                      # serve the built UI
swift run photos-cleanup --dev & pnpm dev     # hot reload
swift test                                    # Core and server tests
```
