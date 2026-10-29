// Spike: can the native app show a Quick Look preview (Space bar) of a Photos-library photo fast enough?
// Quick Look needs a file URL, PhotoKit gives PHAssets, so each photo is first written to a temp file two ways:
//   (a) PHAssetResourceManager.writeData of the primary photo resource
//   (b) PHImageManager.requestImageDataAndOrientation, then Data.write
// Sample: the 50 newest photos plus up to 3 HEIC, a Live Photo, a RAW and an iCloud-only original if the library has them.
// Then a window lists the (a) files: select a row, press Space, and `.quickLookPreview($url, in: urls)` opens.
//   quicklook_probe             measure, then open the window; press Space on a row, close the window to print the summary
//   quicklook_probe --measure   measure, print the summary and quit (no window)
//   --count N                   newest photos in the sample (default 50)
// Build (embeds the Info.plist PhotoKit requires for its permission prompt):
//   swiftc -O -parse-as-library spike/quicklook_probe.swift -o /tmp/quicklook_probe \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker spike/photokit_Info.plist
// Run it from an app bundle: a bare binary launched from a shell never gets its window in front.
//   B=/tmp/quicklook_probe.app/Contents; mkdir -p $B/MacOS; cp /tmp/quicklook_probe $B/MacOS/
//   cp spike/photokit_Info.plist $B/Info.plist; plutil -insert CFBundleExecutable -string quicklook_probe $B/Info.plist
//   codesign -s - -f /tmp/quicklook_probe.app
//   open -n /tmp/quicklook_probe.app --stdout /tmp/qp.out --args --measure
//
// Results, 7,390 assets, 55-photo sample (50 newest + 3 HEIC, 1 Live Photo, 1 iCloud-only; no RAW in library), 2026-10-29:
//   (a) writeData              47 ok, 8 failed (PHPhotosErrorDomain 3164 = original not on disk, 1 more -1); p50 2ms p95 4ms max 10ms; 22.6MB
//   (b) requestImageData+write 54 ok, 1 failed (3164); p50 2ms p95 4ms max 5ms; 27.0MB. Succeeds on the iCloud-only asset by writing a
//                              local 800KB derivative of a 4022x2597 original, so (b) is the fallback when (a) fails
//   .quickLookPreview($url, in: urls) works from a SwiftUI List: Space on a selected row shows the panel in ~57ms (cold),
//   Left/Right page through the URL list. The List needs @FocusState focus for onKeyPress(.space) to fire.
// Verdict: Quick Look is viable. Write the primary resource with writeData (2ms), fall back to requestImageData when it fails.
import AppKit
import Photos
import Quartz  // QuickLookUI: QLPreviewPanel
import QuickLook
import SwiftUI

let measureOnly = CommandLine.arguments.contains("--measure")
let count = Int(CommandLine.arguments.drop { $0 != "--count" }.dropFirst().first ?? "") ?? 50
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quicklook_probe", isDirectory: true)

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count) * p))]
}

struct Sample {
    let asset: PHAsset
    let tag: String
}

struct Timing {
    var ms: [Double] = []
    var failures: [String] = []
    var bytes: Int64 = 0
    var line: String {
        String(format: "%d ok, %d failed; ms p50 %.0f p95 %.0f max %.0f; %.1fMB", ms.count, failures.count,
               pct(ms, 0.5), pct(ms, 0.95), ms.max() ?? 0, Double(bytes) / 1_048_576)
    }
}

func primary(_ asset: PHAsset) -> PHAssetResource? {
    let rs = PHAssetResource.assetResources(for: asset)
    return rs.first { $0.type == .photo } ?? rs.first { $0.type == .alternatePhoto } ?? rs.first
}

func isRAW(_ r: PHAssetResource) -> Bool {
    UTType(r.uniformTypeIdentifier)?.conforms(to: UTType("public.camera-raw-image")!) == true
}

func localOnly(_ r: PHAssetResource) -> Bool? { r.value(forKey: "locallyAvailable") as? Bool }  // private KVC, spike only

func fileSize(_ u: URL) -> Int64 {
    Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}

func writeA(_ s: Sample, to dir: URL) async -> (URL?, String?) {
    guard let r = primary(s.asset) else { return (nil, "no resource") }
    let url = dir.appendingPathComponent(r.originalFilename)
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = false
    return await withCheckedContinuation { c in
        PHAssetResourceManager.default().writeData(for: r, toFile: url, options: opts) { err in
            c.resume(returning: err == nil ? (url, nil) : (nil, (err! as NSError).localizedDescription))
        }
    }
}

func writeB(_ s: Sample, to dir: URL) async -> (URL?, String?) {
    let opts = PHImageRequestOptions()
    opts.isNetworkAccessAllowed = false
    opts.version = .current
    let name = primary(s.asset)?.originalFilename ?? "\(s.asset.localIdentifier.prefix(8)).jpg"
    return await withCheckedContinuation { c in
        PHImageManager.default().requestImageDataAndOrientation(for: s.asset, options: opts) { data, uti, _, info in
            guard let data else {
                let why = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                    ?? ((info?[PHImageResultIsInCloudKey] as? Bool) == true ? "in iCloud" : "no data")
                return c.resume(returning: (nil, why))
            }
            let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
            let url = dir.appendingPathComponent((name as NSString).deletingPathExtension + "." + ext)
            do { try data.write(to: url); c.resume(returning: (url, nil)) } catch { c.resume(returning: (nil, "\(error)")) }
        }
    }
}

@MainActor
final class Probe: ObservableObject {
    @Published var status = "asking for Photos access"
    @Published var urls: [URL] = []
    var pressed: ContinuousClock.Instant?

    func run() async {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard auth == .authorized || auth == .limited else { status = "Photos access: \(auth.rawValue)"; print(status); return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: opts)
        var sample = (0..<min(count, all.count)).map { Sample(asset: all.object(at: $0), tag: "recent") }
        var seen = Set(sample.map(\.asset.localIdentifier))
        var heic = 0, live = false, raw = false, cloud = false
        for i in 0..<all.count {  // scan the whole library for the odd cases
            let a = all.object(at: i)
            guard !seen.contains(a.localIdentifier), let r = primary(a), a.mediaType == .image else { continue }
            var tag: String?
            if r.uniformTypeIdentifier == "public.heic", heic < 3 { heic += 1; tag = "heic" }
            else if a.mediaSubtypes.contains(.photoLive), !live { live = true; tag = "live" }
            else if isRAW(r), !raw { raw = true; tag = "raw" }
            else if localOnly(r) == false, !cloud { cloud = true; tag = "icloud-only" }
            if let tag { sample.append(Sample(asset: a, tag: tag)); seen.insert(a.localIdentifier) }
        }
        try? FileManager.default.removeItem(at: tmp)
        let dirA = tmp.appendingPathComponent("a"), dirB = tmp.appendingPathComponent("b")
        for d in [dirA, dirB] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        status = "writing \(sample.count) files"
        var ta = Timing(), tb = Timing(), good: [URL] = []
        var byTag: [String: [String]] = [:]
        for s in sample {
            for (name, fn, dir) in [("a", writeA, dirA), ("b", writeB, dirB)] {
                let t = ContinuousClock.now
                let (url, err) = await fn(s, dir)
                let ms = seconds(ContinuousClock.now - t) * 1000
                if name == "a" {
                    if let url { ta.ms.append(ms); ta.bytes += fileSize(url); good.append(url) } else { ta.failures.append("\(s.tag) \(err ?? "")") }
                } else {
                    if let url { tb.ms.append(ms); tb.bytes += fileSize(url) } else { tb.failures.append("\(s.tag) \(err ?? "")") }
                }
                if s.tag != "recent" { byTag[s.tag, default: []].append(String(format: "%@ %.0fms %@ %dx%d", name, ms, url == nil ? "FAIL \(err ?? "")" : "ok \(fileSize(url!) / 1024)KB", s.asset.pixelWidth, s.asset.pixelHeight)) }
            }
        }
        print("library \(all.count) assets, sample \(sample.count): heic \(heic), live \(live), raw \(raw), icloud-only \(cloud)")
        print("(a) writeData              \(ta.line)")
        print("(b) requestImageData+write \(tb.line)")
        for (t, l) in byTag.sorted(by: { $0.key < $1.key }) { print("  \(t): \(l.joined(separator: "; "))") }
        print("failures a: \(ta.failures)\nfailures b: \(tb.failures)")
        urls = good
        status = "ready"
        if measureOnly { NSApp.terminate(nil) }
    }

    // Space → panel visible, sampled every 10ms (QLPreviewPanel is what quickLookPreview drives underneath).
    func watchPanel() {
        pressed = .now
        Task { @MainActor in
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(10))
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()!.isVisible {
                    print(String(format: "space → panel visible %.0fms", seconds(.now - pressed!) * 1000)); return
                }
            }
            print("space → panel never became visible in 3s")
        }
    }
}

struct Root: View {
    @StateObject private var probe = Probe()
    @State private var selection: URL?
    @State private var preview: URL?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if probe.urls.isEmpty {
                Text(probe.status).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(probe.urls, id: \.self, selection: $selection) { Text($0.lastPathComponent) }
                    .focused($focused)
                    .onAppear { focused = true }
                    .onKeyPress(.space) {
                        guard let selection else { return .ignored }
                        print("space on \(selection.lastPathComponent)")
                        preview = selection
                        probe.watchPanel()
                        return .handled
                    }
                    .quickLookPreview($preview, in: probe.urls)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .task { await probe.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
    func applicationWillTerminate(_: Notification) { try? FileManager.default.removeItem(at: tmp) }
    func applicationDidFinishLaunching(_: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)  // --stdout is a file, so print would otherwise buffer until exit
        NSApp.setActivationPolicy(.regular)  // a bare binary otherwise gets no Dock icon or key window
        NSApp.activate()
    }
}

@main
struct QuickLookProbe: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { WindowGroup("quicklook_probe") { Root() } }
}
