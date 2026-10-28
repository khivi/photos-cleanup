// `photos-cleanup`: checks the environment, then serves the UI and API on 127.0.0.1.
import AppKit
import Foundation
import Hummingbird
import PhotosCleanupCore
import PhotosCleanupServer

let version = "0.3.0"
let usage = """
    usage: photos-cleanup [--port N] [--no-browser] [--dev] [--version]

    Review and clear unwanted photos in your Photos library, in your browser.

      --port N      local port (default: 8765)
      --no-browser  don't open the browser
      --dev         API only, for `pnpm dev` (implies --no-browser)
    """
let photosSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("photos-cleanup: \(message)\n".utf8))
    exit(1)
}

func openURL(_ url: String) { NSWorkspace.shared.open(URL(string: url)!) }

var port = 8765
var openBrowser = true
var dev = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--port":
        guard let p = args.popFirst().flatMap(Int.init) else { die("--port needs a number") }
        port = p
    case "--no-browser": openBrowser = false
    case "--dev": (dev, openBrowser) = (true, false)
    case "--version":
        print("photos-cleanup \(version)")
        exit(0)
    case "-h", "--help":
        print(usage)
        exit(0)
    default: die("unknown option \(arg)\n\(usage)")
    }
}
setvbuf(stdout, nil, _IOLBF, 0)  // progress lines reach logs and pipes promptly
let url = "http://127.0.0.1:\(port)/"

// The UI ships in SwiftPM's resource bundle beside the real binary. Found by hand, not via
// Bundle.module, which traps when the bundle is missing instead of letting the check below
// explain it.
let resources = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    .appendingPathComponent("photos-cleanup_PhotosCleanup.bundle")
let uiDir = resources.flatMap { Bundle(url: $0)?.url(forResource: "ui", withExtension: nil) }?
    .appendingPathComponent("dist")
if !dev, !(uiDir.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? false) {
    die("the web UI is missing. In a source checkout, run `pnpm build` (or use --dev).")
}

/// Exit if the port is taken; if it's taken by us, just reopen the UI.
func checkPort(_ port: Int, _ url: String, openBrowser: Bool) async {
    var req = URLRequest(url: URL(string: "\(url)health")!)
    req.timeoutInterval = 2
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool] == ["ok": true] else {
            die("port \(port) is in use by another program. Pick another with --port.")
        }
        print("Already running at \(url)")
        if openBrowser { openURL(url) }
        exit(0)
    } catch let e as URLError where e.code == .cannotConnectToHost {
        return  // free
    } catch {
        die("port \(port) is in use by another program. Pick another with --port.")
    }
}
await checkPort(port, url, openBrowser: openBrowser)

// PhotoKit's requestImage returns nil, with no error, unless the process is an app. No Dock
// icon or window.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let library = PhotoKitLibrary()
print("Checking Photos access (macOS may ask once)…")
let status = await library.authorize()
if status != "authorized" {
    let app = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
    if isatty(STDIN_FILENO) != 0 { openURL(photosSettings) }
    die("""
        can't read your Photos library: Photos access is \(status).
          In System Settings > Privacy & Security > Photos, turn on \(app)
          with "Full Access", then run photos-cleanup again.
        """)
}

let judge = FoundationModelsJudge(library: library)
let verdictsOff = judge.unavailableReason()
if let verdictsOff { print("Note: \(verdictsOff). Everything else works.") }
let cleanup = Cleanup(
    library: library, judge: judge,
    cacheDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/photos-cleanup"),
    ignoreAlbums: loadIgnoreAlbums(), verdictsOff: verdictsOff)

print("Reading your Photos library…")
let start = Date()
do { try await cleanup.load() } catch { die("couldn't load the Photos library: \(error)") }
let photos = await cleanup.photos
print("\(photos.count.formatted()) photos loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)))s.")
// Bursts, Low Quality and Utility all need the Vision analysis; start it now.
let progress = await cleanup.startVision(photos.filter { !$0.isMovie && !$0.screenshot })
if progress.pending > 0 {
    print("Analysing \(progress.pending.formatted()) photos in the background; cached afterwards.")
}
print("Open \(url) — press Ctrl-C to stop.")

let app = Application(
    router: buildRouter(cleanup: cleanup, uiDir: dev ? nil : uiDir),
    configuration: .init(address: .hostname("127.0.0.1", port: port))
)
if openBrowser {
    Task {
        try? await Task.sleep(for: .seconds(1))
        openURL(url)
    }
}
try await app.runService()
