// Spike: can a native SwiftUI grid replace the browser UI for the whole library?
// LazyVGrid of every asset, thumbnails from PHCachingImageManager, metrics on stdout:
// fetch time, time to first thumbnail, thumbnail latency, main-thread hitches, memory.
//   grid_probe               open the window; scroll by hand, close it to print the summary
//   grid_probe --autoscroll  scroll top to bottom by itself, print the summary and quit
//   --mode opportunistic|fast|hq  PHImageRequestOptions.deliveryMode (default opportunistic)
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
// Verdict: native is viable; hq looks right and holds ~40fps under a sustained fling.
import AppKit
import Photos
import SwiftUI

let cell: CGFloat = 170
let autoscroll = CommandLine.arguments.contains("--autoscroll")
let mode = CommandLine.arguments.drop { $0 != "--mode" }.dropFirst().first ?? "opportunistic"
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
        print("mode \(mode)")
        print(String(format: "full-quality %d; latency ms p50 %.0f p95 %.0f max %.0f; first image synchronous %d",
                     finals.count, pct(fm, 0.5), pct(fm, 0.95), fm.max() ?? 0, syncFirst))
        print(String(format: "first thumbnail %.2fs after launch", firstThumb ?? -1))
        print(String(format: "thumbnails %d requested, %d delivered, %d cancelled; latency ms p50 %.0f p95 %.0f max %.0f",
                     requested, latencies.count, cancelled, pct(ms, 0.5), pct(ms, 0.95), ms.max() ?? 0))
        print(String(format: "main-thread hitches >50ms: %d, worst %.0fms", gaps.count, (gaps.max() ?? 0) * 1000))
        print(String(format: "memory now %.0fMB, peak %.0fMB", footprintMB(), peakMB))
    }
}

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
}

struct Thumb: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: cell, height: cell)
        .clipped()
        .onAppear(perform: request)
        .onDisappear(perform: cancel)
    }

    @State private var requestID: PHImageRequestID?

    private func request() {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = mode == "fast" ? .fastFormat : mode == "hq" ? .highQualityFormat : .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        let start = ContinuousClock.now
        var first = true, inCall = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        Stats.shared.requested += 1
        requestID = manager.requestImage(
            for: asset, targetSize: CGSize(width: cell * scale, height: cell * scale),
            contentMode: .aspectFill, options: opts
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
    @State private var position = ScrollPosition(edge: .top)
    @State private var y: CGFloat = 0

    var body: some View {
        Group {
            if let assets = lib.assets {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 4)], spacing: 4) {
                        ForEach(0..<assets.count, id: \.self) { i in
                            Thumb(asset: assets.object(at: i), manager: lib.manager)
                        }
                    }
                    .padding(4)
                }
                .scrollPosition($position)
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
        while y < height {
            y += 40
            position.scrollTo(y: y)
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .seconds(2))
        print(String(format: "autoscroll %.0fpt in %.1fs", height, seconds(ContinuousClock.now - t)))
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
