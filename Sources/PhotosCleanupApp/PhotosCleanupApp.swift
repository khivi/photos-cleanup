import AppKit
import PhotosCleanupCore
import SwiftUI

@main
struct PhotosCleanupApp: App {
    init() {
        // AppKit's tooltip delay, in ms (macOS waits ~1.5 s by default): the pass explanations are worth showing sooner.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .commands { ReviewCommands() }
        Settings { SettingsView() }
    }
}

enum Phase {
    case starting
    case noAccess(String)
    case loaded(ReviewModel, Thumbnails)
    case failed(String)
}

/// The fixtures folder when the app runs in demo mode (`--demo`, Dev bundle built by `scripts/app.sh demo`).
let demoDirectory = demoFixtures(resources: Bundle.main.resourceURL)

let photosSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

struct ContentView: View {
    @State private var phase = Phase.starting

    var body: some View {
        Group {
            switch phase {
            case .starting:
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Reading your Photos library…")
                }
            case .noAccess(let status):
                ContentUnavailableView {
                    Label("No access to Photos", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Photos access is \(status). Allow it in System Settings, Privacy & Security, Photos.")
                } actions: {
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(photosSettings) }
                }
            case .loaded(let model, let thumbnails):
                ReviewScreen(model: model, thumbnails: thumbnails)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn’t load the Photos library", systemImage: "exclamationmark.triangle",
                    description: Text(message))
            }
        }
        .frame(minWidth: 760, minHeight: 360)
        .task { phase = await start() }
    }

    func settings() -> LaunchSettings {
        let defaults = UserDefaults.standard
        return LaunchSettings(
            ignoreAlbums: loadIgnoreAlbums(),
            keepAlbumPhotos: defaults.object(forKey: keepAlbumPhotosKey) as? Bool ?? true,
            exportFolder: loadExportDestination(),
            showsInspector: savedInspector(.all),
            zoom: defaults.object(forKey: zoomKey) as? Int,
            aspectFit: defaults.bool(forKey: aspectFitKey))
    }

    func start() async -> Phase {
        let result: LaunchResult
        let thumbnails: ([String], CGFloat) -> Thumbnails
        if let demoDirectory {
            // Caches and decisions go in a fresh folder, so every demo launch starts the same.
            let scratch = URL.temporaryDirectory.appending(path: "photos-cleanup-demo", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: scratch)
            guard let library = try? DemoLibrary(directory: demoDirectory) else {
                return .failed("The demo manifest is unreadable.")
            }
            result = await launch(
                library: library, judge: DemoJudge(library: library), settings: settings(), cacheDir: scratch,
                dir: scratch)
            thumbnails = { Thumbnails(files: library.imageURLs, uuids: $0, cell: $1) }
        } else {
            let library = PhotoKitLibrary()
            result = await launch(
                library: library, judge: FoundationModelsJudge(library: library), settings: settings(),
                cacheDir: URL.cachesDirectory.appending(path: "photos-cleanup", directoryHint: .isDirectory))
            thumbnails = { Thumbnails(library: library, uuids: $0, cell: $1) }
        }
        switch result {
        case .noAccess(let status): return .noAccess(status)
        case .failed(let message): return .failed(message)
        case .loaded(let model, let uuids): return .loaded(model, thumbnails(uuids, model.cellSize))
        }
    }
}
