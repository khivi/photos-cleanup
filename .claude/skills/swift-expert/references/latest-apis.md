# Latest APIs — deprecated → current

Facts, not opinions. Left column is what the training corpus overflows with;
right column is what to actually write. Verified against the SwiftUI /
PhotoKit / Vision surface through iOS 26 / macOS 26 (WWDC 2025).

## SwiftUI — state & observation

| Deprecated / stale | Current |
|---|---|
| `class VM: ObservableObject` + `@Published var x` | `@Observable final class VM { var x }` (Observation framework, iOS 17+) |
| `@StateObject var vm = VM()` | `@State private var vm = VM()` (with `@Observable`) |
| `@ObservedObject var vm` | plain `let vm: VM` or `@Bindable var vm` when you need `$` bindings |
| `@EnvironmentObject var vm` | `@Environment(VM.self) private var vm` |
| `.environmentObject(vm)` | `.environment(vm)` |

`@Observable` tracks only the properties a view actually reads — no `@Published`,
finer-grained invalidation. Use `@Bindable` inside a view to get `$vm.x`.

## SwiftUI — navigation

| Deprecated | Current |
|---|---|
| `NavigationView` | `NavigationStack` (single column) / `NavigationSplitView` (sidebar+detail — the right one for a review UI) |
| `NavigationLink(destination:)` push-everywhere | value-based: `NavigationLink(value:)` + `.navigationDestination(for:) { }`, path driven by `@State path: [Route]` |

## SwiftUI — modifiers that moved

| Deprecated | Current |
|---|---|
| `.foregroundColor(_)` | `.foregroundStyle(_)` |
| `.cornerRadius(_)` | `.clipShape(.rect(cornerRadius:))` |
| `Alert(title:...)` init | `.alert(_:isPresented:) { actions } message: { }` |
| `ActionSheet` | `.confirmationDialog(_:isPresented:)` |
| `.onChange(of:) { value in }` (single-arg) | `.onChange(of:) { old, new in }` or zero-arg `{ }` (iOS 17 signature change) |
| manual `if #available` for previews | `#Preview { }` macro; `@Previewable @State` for stateful previews |

## SwiftUI — iOS 18+ additions worth using

- `Tab("x", systemImage:) { }` inside `TabView` — replaces the old `.tabItem` closure form.
- `@Entry` macro for custom `EnvironmentValues` / `FocusedValues` — kills the old `EnvironmentKey` boilerplate.
- `ScrollView` + `.scrollTargetBehavior(.viewAligned)` and `.scrollPosition` for the grid.
- `LazyVGrid` is still correct for the thumbnail grid; pair with `.task` for async thumbnail loads.

## Swift language

- **Swift 6 language mode**: strict data-race checking is on. Types crossing
  concurrency boundaries must be `Sendable`. Annotate UI-touching types
  `@MainActor` (the whole `View` graph already is).
- Prefer `async`/`await` + structured concurrency (`async let`, `TaskGroup`)
  over `DispatchQueue`/completion handlers.
- `Duration`/`ContinuousClock` over `Date`-diffing for timing.

## PhotoKit — the part this repo actually needs

| Task | API |
|---|---|
| Ask for library access | `PHPhotoLibrary.requestAuthorization(for: .readWrite)` (the `for:` overload; the arg-less one is deprecated) |
| User-picks-photos, **no permission prompt** | `PHPickerViewController` / `PhotosPicker` (SwiftUI) — use when you don't need the whole library |
| Enumerate library | `PHAsset.fetchAssets(with:)` + `PHFetchOptions` (`predicate`, `sortDescriptors`, `fetchLimit`) |
| Screenshot detection | `asset.mediaSubtypes.contains(.photoScreenshot)` |
| Thumbnails | `PHImageManager.default().requestImage(...)` — callback-based; wrap in `withCheckedContinuation` for async. `PHCachingImageManager` for grids. |
| Original filename / size | `PHAssetResource.assetResources(for:)` → `.originalFilename`, resource size via `PHAssetResourceManager` |
| Was-edited flag | infer from a resource of type `.adjustmentData` (no clean bool) |
| **Create / populate an album (the commit path)** | `PHAssetCollectionChangeRequest` inside `PHPhotoLibrary.shared().performChanges` — **native, no Apple Events**. This is the win that removes the AppleScript wall. |

PhotoKit does **not** expose Apple's aesthetic `score`, scene `labels`, or
perceptual `fingerprint`. Those get re-derived with Vision (below). They will
not byte-match Photos' values — that's expected, see `TODO.md`.

## Vision — re-deriving the lost signals

| Lost osxphotos signal | Vision replacement |
|---|---|
| `score.overall` (aesthetic) | `VNCalculateImageAestheticsScoresRequest` (iOS 18+) — closest native aesthetic score; else custom Core Image blur/exposure heuristic |
| `labels` (scene classification) | `VNClassifyImageRequest` (+ `VNRecognizeTextRequest` OCR for the receipt/menu/document buckets) |
| `fingerprint` (perceptual hash) | `VNGenerateImageFeaturePrintRequest` → `VNFeaturePrintObservation.computeDistance` for the "similar" pass |

Vision requests: build `VNImageRequestHandler(url:)`, `perform([request])`, read
`request.results`. Batch off the main actor.

## When updating this file

New WWDC lands → add the rows, don't rewrite prose. This is a lookup table, not
an essay. If a row here ever turns out wrong, the fix is to correct the row —
the model can't self-correct these from weights.
