import AppKit
import Photos
import PhotosCleanupCore
import SwiftUI

let cellSize: CGFloat = 170

/// Thumbnails for the grid, from one PHCachingImageManager (settings measured in spike/grid_probe.swift).
@MainActor
final class Thumbnails {
    private let manager = PHCachingImageManager()
    private let uuids: [String]  // grid order, newest first
    private let assets: [String: PHAsset]
    private let size = CGSize(width: cellSize * (NSScreen.main?.backingScaleFactor ?? 2),
                              height: cellSize * (NSScreen.main?.backingScaleFactor ?? 2))
    // Rows are ~8 cells wide: cache ~30 rows ahead of the lowest visible cell, ~15 behind.
    private let ahead = 240, behind = 120
    private var cached = 0..<0

    init(library: PhotoKitLibrary, uuids: [String]) {
        self.uuids = uuids
        assets = library.assets(uuids)
    }

    // Must match requestImage's size and options, or the cache never hits.
    private func options() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = false
        return o
    }

    /// Calls `done` once, on the main actor. Returns an ID for `cancel`.
    func request(_ uuid: String, done: @escaping (NSImage?) -> Void) -> PHImageRequestID? {
        guard let asset = assets[uuid] else { return nil }
        return manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options()) { image, _ in
            MainActor.assumeIsolated { done(image) }
        }
    }

    func cancel(_ id: PHImageRequestID) { manager.cancelImageRequest(id) }

    /// Called as cell `i` appears: slide the caching window when it nears either edge.
    func near(_ i: Int) {
        guard i + ahead / 2 > cached.upperBound || i - behind / 2 < cached.lowerBound else { return }
        let want = max(0, i - behind)..<min(uuids.count, i + ahead)
        func list(_ s: IndexSet) -> [PHAsset] { s.compactMap { assets[uuids[$0]] } }
        let add = IndexSet(integersIn: want).subtracting(IndexSet(integersIn: cached))
        let drop = IndexSet(integersIn: cached).subtracting(IndexSet(integersIn: want))
        if !add.isEmpty { manager.startCachingImages(for: list(add), targetSize: size, contentMode: .aspectFill, options: options()) }
        if !drop.isEmpty { manager.stopCachingImages(for: list(drop), targetSize: size, contentMode: .aspectFill, options: options()) }
        cached = want
    }
}

struct PhotoCell: View {
    let index: Int
    let uuid: String
    let thumbnails: Thumbnails
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Color.gray.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear {
            thumbnails.near(index)
            requestID = thumbnails.request(uuid) { image = $0 ?? image }
        }
        .onDisappear {
            if let requestID { thumbnails.cancel(requestID) }
            requestID = nil
        }
    }
}
