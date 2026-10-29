// Photos Cleanup: the native app. Phase 0 shell: Photos access, Cleanup.load(), the photo count.
import AppKit
import PhotosCleanupCore
import SwiftUI

@main
struct PhotosCleanupApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .commands { UndoCommands() }
        Settings { SettingsView() }
    }
}

enum Phase {
    case starting
    case noAccess(String)
    case loaded(ReviewModel, Thumbnails)
    case failed(String)
}

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

    func start() async -> Phase {
        let library = PhotoKitLibrary()
        let status = await library.authorize()
        guard status == "authorized" else { return .noAccess(status) }
        let judge = FoundationModelsJudge(library: library)
        let verdictsOff = judge.unavailableReason()
        let cleanup = Cleanup(
            library: library, judge: judge,
            cacheDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/photos-cleanup"),
            ignoreAlbums: loadIgnoreAlbums(),
            keepAlbumPhotos: UserDefaults.standard.object(forKey: keepAlbumPhotosKey) as? Bool ?? true, verdictsOff: verdictsOff)
        do { try await cleanup.load() } catch { return .failed("\(error)") }
        let photos = await cleanup.photos
        await cleanup.startVision(photos.filter { !$0.isMovie && !$0.screenshot })
        let model = ReviewModel(cleanup: cleanup)
        await model.select(.all)
        return .loaded(model, Thumbnails(library: library, uuids: photos.map(\.uuid)))
    }
}
