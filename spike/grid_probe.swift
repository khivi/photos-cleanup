// Spike: can a native SwiftUI grid replace the browser UI for the whole library?
// LazyVGrid of every asset, thumbnails from PHCachingImageManager, metrics on stdout:
// fetch time, time to first thumbnail, thumbnail latency, main-thread hitches, memory.
//   grid_probe               open the window; scroll by hand, close it to print the summary
//   grid_probe --autoscroll  scroll top to bottom by itself, print the summary and quit
//   --mode opportunistic|fast|hq  PHImageRequestOptions.deliveryMode (default opportunistic)
//   --preload      startCachingImages for the rows ahead of the visible ones
//   --select       click to select, ⇧-click for a range, ⌘-click to toggle, ⌘A for all, arrow keys
//                  to move. With --autoscroll: select all, toggle one visible cell every 50ms while
//                  scrolling, then from the top press ↓ 300 times at key-repeat rate (30/s)
// Build (embeds the Info.plist PhotoKit requires for its permission prompt):
//   swiftc -O -parse-as-library spike/grid_probe.swift -o /tmp/grid_probe \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker spike/photokit_Info.plist
// Run it from an app bundle: a bare binary launched from a shell never gets its window in front,
// and SwiftUI does not render (or autoscroll) until it does.
//   B=/tmp/grid_probe.app/Contents; mkdir -p $B/MacOS; cp /tmp/grid_probe $B/MacOS/
//   cp spike/photokit_Info.plist $B/Info.plist; plutil -insert CFBundleExecutable -string grid_probe $B/Info.plist
//   codesign -s - -f /tmp/grid_probe.app
//   open -n /tmp/grid_probe.app --stdout /tmp/gp.out --args --autoscroll --mode hq
//
// Results, 7,383 assets, --autoscroll at ~2400pt/s (ideal 86s), 2026-10-28:
//   opportunistic  194s, 1,192 hitches >50ms (worst 1,009ms), peak 102MB: the degraded image
//                  arrives synchronously on the main thread, then gets replaced
//   fast            93s, 1 hitch (248ms), peak 53MB, thumbnail p95 4ms: smooth but visibly pixelated
//   hq             130s, 458 hitches (worst 117ms), peak 147MB, thumbnail p95 12ms: sharp
//   hq --preload    93s, 1 hitch (84ms), peak 309MB, thumbnail p95 4ms: sharp and smooth
// Verdict: native is viable. Use hq plus startCachingImages ~30 rows ahead (`near`); the cache
// costs ~150MB more and makes hq as smooth as fast. Off-main decoding is not needed.
// --select, by hand, 7,390 assets, 2026-10-29: click, ⇧-click, ⌘-click, ⌘A and the arrow keys all
// work, and scrolling with everything selected stays smooth. One shared selection set is enough.
import AppKit
import Photos
import SwiftUI

let cell: CGFloat = 170
let autoscroll = CommandLine.arguments.contains("--autoscroll")
let mode = CommandLine.arguments.drop { $0 != "--mode" }.dropFirst().first ?? "opportunistic"
let preload = CommandLine.arguments.contains("--preload")
let selecting = CommandLine.arguments.contains("--select")
let launched = ContinuousClock.now  // globals are lazy: touched in GridProbe.init to pin it to launch

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count) * p))]
}

@MainActor
final class Stats {
    static let shared = Stats()
    var firstThumb: Double?
    var latencies: [Double] = []  // request → first image, seconds
    var finals: [Double] = []  // request → non-degraded image
    var syncFirst = 0  // first image delivered inside requestImage, on the main thread
    var requested = 0, cancelled = 0, peakMB = 0.0
    var bodies = 0, changes = 0  // Thumb body evaluations; selection changes
    var gaps: [Double] = []  // main-thread timer gaps over 50ms
    private var last = ContinuousClock.now
    private var timer: Timer?

    func startHitchWatch() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ContinuousClock.now
                let gap = seconds(now - self.last)
                if gap > 0.05 { self.gaps.append(gap) }
                self.last = now
                self.peakMB = max(self.peakMB, footprintMB())
            }
        }
        RunLoop.main.add(timer!, forMode: .common)  // keep firing while a scroll tracks
    }

    func summary() {
        let ms = latencies.map { $0 * 1000 }
        let fm = finals.map { $0 * 1000 }
        print("mode \(mode)\(preload ? " +preload" : "")")
        print(String(format: "full-quality %d; latency ms p50 %.0f p95 %.0f max %.0f; first image synchronous %d",
                     finals.count, pct(fm, 0.5), pct(fm, 0.95), fm.max() ?? 0, syncFirst))
        print(String(format: "first thumbnail %.2fs after launch", firstThumb ?? -1))
        print(String(format: "thumbnails %d requested, %d delivered, %d cancelled; latency ms p50 %.0f p95 %.0f max %.0f",
                     requested, latencies.count, cancelled, pct(ms, 0.5), pct(ms, 0.95), ms.max() ?? 0))
        print(String(format: "main-thread hitches >50ms: %d, worst %.0fms", gaps.count, (gaps.max() ?? 0) * 1000))
        print(String(format: "memory now %.0fMB, peak %.0fMB", footprintMB(), peakMB))
        if selecting {
            print(String(format: "selection changes %d, thumb bodies %d (%.1f per change)",
                         changes, bodies, Double(bodies) / Double(max(changes, 1))))
        }
    }
}

func thumbOptions() -> PHImageRequestOptions {
    let opts = PHImageRequestOptions()
    opts.deliveryMode = mode == "fast" ? .fastFormat : mode == "hq" ? .highQualityFormat : .opportunistic
    opts.resizeMode = .fast
    opts.isNetworkAccessAllowed = false
    return opts
}

@MainActor let thumbSize = CGSize(width: cell * (NSScreen.main?.backingScaleFactor ?? 2),
                                  height: cell * (NSScreen.main?.backingScaleFactor ?? 2))

@MainActor
final class Library: ObservableObject {
    @Published var assets: PHFetchResult<PHAsset>?
    @Published var status = "asking for Photos access"
    let manager = PHCachingImageManager()

    func load() async {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard auth == .authorized || auth == .limited else { status = "Photos access: \(auth.rawValue)"; return }
        let t = ContinuousClock.now
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: opts)
        _ = all.count  // forces the fetch
        print(String(format: "fetch %d assets: %.2fs", all.count, seconds(ContinuousClock.now - t)))
        assets = all
    }

    // Window of assets being cached: ~30 rows ahead of the lowest visible cell, ~15 behind.
    // Must use the same size and options as requestImage, or the cache never hits.
    private var cached = 0..<0
    private let ahead = 240, behind = 120

    func near(_ i: Int) {
        guard preload, let assets, i + ahead / 2 > cached.upperBound || i - behind / 2 < cached.lowerBound else { return }
        let want = max(0, i - behind)..<min(assets.count, i + ahead)
        let add = IndexSet(integersIn: want).subtracting(IndexSet(integersIn: cached))
        let drop = IndexSet(integersIn: cached).subtracting(IndexSet(integersIn: want))
        if !add.isEmpty {
            manager.startCachingImages(for: assets.objects(at: add), targetSize: thumbSize,
                                       contentMode: .aspectFill, options: thumbOptions())
        }
        if !drop.isEmpty {
            manager.stopCachingImages(for: assets.objects(at: drop), targetSize: thumbSize,
                                      contentMode: .aspectFill, options: thumbOptions())
        }
        cached = want
    }
}

// One set read by every cell: the simplest design. Each change re-evaluates every visible
// Thumb, since Observation tracks `ids` as a whole.
@MainActor @Observable
final class Selection {
    var ids = Set<Int>()
    var anchor: Int?

    func click(_ i: Int) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let anchor {
            ids = Set(min(anchor, i)...max(anchor, i))
        } else if mods.contains(.command) {
            if ids.remove(i) == nil { ids.insert(i) }
            anchor = i
        } else {
            ids = [i]
            anchor = i
        }
        Stats.shared.changes += 1
    }
}

struct Thumb: View {
    let index: Int
    let asset: PHAsset
    let lib: Library
    let sel: Selection
    private var manager: PHCachingImageManager { lib.manager }
    @State private var image: NSImage?

    var body: some View {
        let _ = Stats.shared.bodies += 1
        let selected = selecting && sel.ids.contains(index)
        ZStack {
            Color.gray.opacity(0.15)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: cell, height: cell)
        .clipped()
        .overlay { if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 4) } }
        .contentShape(Rectangle())
        .onTapGesture { if selecting { sel.click(index) } }
        .onAppear {
            lib.near(index)
            request()
        }
        .onDisappear(perform: cancel)
    }

    @State private var requestID: PHImageRequestID?

    private func request() {
        let start = ContinuousClock.now
        var first = true, inCall = true
        Stats.shared.requested += 1
        requestID = manager.requestImage(
            for: asset, targetSize: thumbSize, contentMode: .aspectFill, options: thumbOptions()
        ) { img, info in
            MainActor.assumeIsolated {
                guard let img else { return }
                let s = Stats.shared
                let now = seconds(ContinuousClock.now - start)
                if first {
                    first = false
                    s.latencies.append(now)
                    if inCall { s.syncFirst += 1 }
                    if s.firstThumb == nil { s.firstThumb = seconds(ContinuousClock.now - launched) }
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) != true { s.finals.append(now) }
                image = img
            }
        }
        inCall = false
    }

    private func cancel() {
        if let requestID, image == nil {
            manager.cancelImageRequest(requestID)
            Stats.shared.cancelled += 1
        }
        requestID = nil
    }
}

struct Grid: View {
    @StateObject private var lib = Library()
    @State private var sel = Selection()
    @State private var position = ScrollPosition(edge: .top)
    @State private var y: CGFloat = 0
    @State private var width: CGFloat = 1200
    @FocusState private var focused: Bool

    // The adaptive grid fits as many fixed-width columns as the width allows.
    private var columns: Int { max(1, Int((width - 8 + 4) / (cell + 4))) }

    private func move(_ delta: Int, count: Int) {
        let i = min(count - 1, max(0, (sel.anchor ?? -1) + delta))
        sel.ids = [i]
        sel.anchor = i
        Stats.shared.changes += 1
        position.scrollTo(id: i)
    }

    var body: some View {
        Group {
            if let assets = lib.assets {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 4)], spacing: 4) {
                        ForEach(0..<assets.count, id: \.self) { i in
                            Thumb(index: i, asset: assets.object(at: i), lib: lib, sel: sel)
                        }
                    }
                    .padding(4)
                }
                .scrollPosition($position)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .focusable(selecting)
                .focused($focused)
                .focusEffectDisabled()
                .onAppear { focused = selecting }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard selecting else { return .ignored }
                    switch press.key {
                    case .leftArrow: move(-1, count: assets.count)
                    case .rightArrow: move(1, count: assets.count)
                    case .upArrow: move(-columns, count: assets.count)
                    default: move(columns, count: assets.count)
                    }
                    return .handled
                }
                .background {
                    Button("Select All") { sel.ids = Set(0..<assets.count); Stats.shared.changes += 1 }
                        .keyboardShortcut("a").hidden()
                }
                .task { if autoscroll { await scrollThrough(rows: assets.count) } }
            } else {
                Text(lib.status).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1200, minHeight: 800)
        .task {
            Stats.shared.startHitchWatch()
            await lib.load()
        }
    }

    // ~2400pt/s: about 14 rows a second, a brisk flick-scroll held for the whole library.
    private func scrollThrough(rows count: Int) async {
        try? await Task.sleep(for: .seconds(2))
        let t = ContinuousClock.now
        let columns = max(1, Int((1200 - 8) / (cell + 4)))
        let height = CGFloat((count + columns - 1) / columns) * (cell + 4)
        if selecting { sel.ids = Set(0..<count); Stats.shared.changes += 1 }
        var lastToggle = ContinuousClock.now
        while y < height {
            y += 40
            position.scrollTo(y: y)
            if selecting && ContinuousClock.now - lastToggle >= .milliseconds(50) {
                let i = min(count - 1, Int(y / (cell + 4)) * columns + Int.random(in: 0..<columns))
                if sel.ids.remove(i) == nil { sel.ids.insert(i) }
                Stats.shared.changes += 1
                lastToggle = .now
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .seconds(2))
        print(String(format: "autoscroll %.0fpt in %.1fs", height, seconds(ContinuousClock.now - t)))
        if selecting {
            position.scrollTo(edge: .top)
            sel.anchor = nil
            try? await Task.sleep(for: .seconds(2))
            let before = Stats.shared.gaps.count
            let ta = ContinuousClock.now
            for _ in 0..<300 {
                move(columns, count: count)
                try? await Task.sleep(for: .milliseconds(33))
            }
            let arrows = Stats.shared.gaps.dropFirst(before)
            print(String(format: "arrows: 300 x ↓ (%d columns) in %.1fs (ideal 9.9s), ended at %d of %d; hitches >50ms %d, worst %.0fms",
                         columns, seconds(ContinuousClock.now - ta), sel.anchor ?? -1, count,
                         arrows.count, (arrows.max() ?? 0) * 1000))
            try? await Task.sleep(for: .seconds(1))
        }
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
    func applicationWillTerminate(_: Notification) { MainActor.assumeIsolated { Stats.shared.summary() } }
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)  // a bare binary otherwise gets no Dock icon or key window
        NSApp.activate()
    }
}

@main
struct GridProbe: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() { _ = launched }
    var body: some Scene { WindowGroup("grid_probe") { Grid() } }
}
