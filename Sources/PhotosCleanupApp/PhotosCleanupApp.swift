// Photos Cleanup: the native app. Phase 0 shell: Photos access, Cleanup.load(), the photo count.
import AppKit
import PhotosCleanupCore
import SwiftUI

@main
struct PhotosCleanupApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

enum Phase {
    case starting
    case noAccess(String)
    case loaded(photos: [Photo], thumbnails: Thumbnails, verdictsOff: String?)
    case failed(String)
}

let photosSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

struct ContentView: View {
    @State private var phase = Phase.starting

    var body: some View {
        VStack(spacing: 12) {
            switch phase {
            case .starting:
                ProgressView("Reading your Photos library…")
            case .noAccess(let status):
                Text("Photos access is \(status).")
                Button("Open Privacy Settings") { NSWorkspace.shared.open(photosSettings) }
            case .loaded(let photos, let thumbnails, let verdictsOff):
                HStack {
                    Text("\(photos.count.formatted()) photos").font(.title2)
                    if let verdictsOff { Text("\(verdictsOff). Everything else works.").foregroundStyle(.secondary) }
                    Spacer()
                }
                .padding(.horizontal)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize), spacing: 4)], spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                            PhotoCell(index: i, uuid: photo.uuid, thumbnails: thumbnails)
                        }
                    }
                    .padding(.horizontal)
                }
            case .failed(let message):
                Text("Couldn't load the Photos library: \(message)")
            }
        }
        .padding(.vertical)
        .frame(minWidth: 400, minHeight: 240)
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
            ignoreAlbums: loadIgnoreAlbums(), verdictsOff: verdictsOff)
        do { try await cleanup.load() } catch { return .failed("\(error)") }
        let photos = await cleanup.photos
        return .loaded(photos: photos, thumbnails: Thumbnails(library: library, uuids: photos.map(\.uuid)), verdictsOff: verdictsOff)
    }
}
