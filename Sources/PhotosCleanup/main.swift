// `photos-cleanup`: checks the environment, then serves the UI and API on 127.0.0.1.
import AppKit
import Foundation
import Hummingbird
import PhotosCleanupCore
import PhotosCleanupServer

let version = "0.3.0"
let photosSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("photos-cleanup: \(message)\n".utf8))
    exit(1)
}

func openURL(_ url: String) { NSWorkspace.shared.open(URL(string: url)!) }

let options: Options
do { options = try parseOptions(Array(CommandLine.arguments.dropFirst())) } catch let e as StartupError { die(e.message) }
switch options.action {
case .version:
    print("photos-cleanup \(version)")
    exit(0)
case .help:
    print(usage)
    exit(0)
case .run: break
}
let (port, openBrowser, dev) = (options.port, options.openBrowser, options.dev)
setvbuf(stdout, nil, _IOLBF, 0)  // progress lines reach logs and pipes promptly
let url = "http://127.0.0.1:\(port)/"

let uiDir = uiDirectory(executable: Bundle.main.executableURL)
if !dev, uiDir == nil { die(uiMissing) }

switch portOutcome(await portState(port: port), port: port) {
case .proceed: break
case .fail(let message): die(message)
case .alreadyRunning(let url):
    print("Already running at \(url)")
    if openBrowser { openURL(url) }
    exit(0)
}

// PhotoKit's requestImage returns nil, with no error, unless the process is an app. No Dock
// icon or window.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let library = PhotoKitLibrary()
print("Checking Photos access (macOS may ask once)…")
let status = await library.authorize()
let terminal = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
if let problem = accessProblem(status: status, terminal: terminal) {
    if isatty(STDIN_FILENO) != 0 { openURL(photosSettings) }
    die(problem)
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
