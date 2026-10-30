import AppKit
import Photos
import PhotosCleanupCore
import SwiftUI

let cellSize: CGFloat = 120
/// Adaptive cells grow up to this to fill a row; thumbnails are requested at this size.
let cellMax: CGFloat = 150

/// Thumbnails for the grid, from one PHCachingImageManager (settings measured in the grid spike, `feea7cb`).
@MainActor
final class Thumbnails {
    private let manager = PHCachingImageManager()
    private let uuids: [String]  // grid order, newest first
    private let assets: [String: PHAsset]
    private let size = CGSize(
        width: cellMax * (NSScreen.main?.backingScaleFactor ?? 2),
        height: cellMax * (NSScreen.main?.backingScaleFactor ?? 2))
    // Rows are ~8 cells wide: cache ~30 rows ahead of the lowest visible cell, ~15 behind.
    private let ahead = 240, behind = 120
    private var cached = 0..<0
    private let index: [String: Int]

    init(library: PhotoKitLibrary, uuids: [String]) {
        self.uuids = uuids
        assets = library.assets(uuids)
        index = Dictionary(uuids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
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
        return manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options()) {
            image, _ in
            MainActor.assumeIsolated { done(image) }
        }
    }

    /// A large aspect-fit image for the preview. Own options: the cache only holds grid-sized images.
    func requestLarge(_ uuid: String, side: CGFloat, done: @escaping (NSImage?) -> Void) -> PHImageRequestID? {
        guard let asset = assets[uuid] else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let o = PHImageRequestOptions()
        // The local copy first, then the full one. With Optimize Mac Storage the full one is only in
        // iCloud: Photos downloads it for the one photo being previewed.
        o.deliveryMode = .opportunistic
        o.isNetworkAccessAllowed = true
        return manager.requestImage(
            for: asset, targetSize: CGSize(width: side * scale, height: side * scale),
            contentMode: .aspectFit, options: o
        ) { image, _ in
            MainActor.assumeIsolated { done(image) }
        }
    }

    func cancel(_ id: PHImageRequestID) { manager.cancelImageRequest(id) }

    /// Called as a cell appears: slide the caching window when it nears either edge.
    /// Positions are in whole-library order, so any subset of photos can share one instance.
    func near(_ uuid: String) {
        guard let i = index[uuid] else { return }
        guard i + ahead / 2 > cached.upperBound || i - behind / 2 < cached.lowerBound else { return }
        let want = max(0, i - behind)..<min(uuids.count, i + ahead)
        func list(_ s: IndexSet) -> [PHAsset] { s.compactMap { assets[uuids[$0]] } }
        let add = IndexSet(integersIn: want).subtracting(IndexSet(integersIn: cached))
        let drop = IndexSet(integersIn: cached).subtracting(IndexSet(integersIn: want))
        if !add.isEmpty {
            manager.startCachingImages(for: list(add), targetSize: size, contentMode: .aspectFill, options: options())
        }
        if !drop.isEmpty {
            manager.stopCachingImages(for: list(drop), targetSize: size, contentMode: .aspectFill, options: options())
        }
        cached = want
    }
}

/// One photo. The badges and dimming follow the review model's state, passed in as `mark`.
struct PhotoCell: View {
    enum Mark {
        case none
        case decision(Decision)
        case deleteMe
    }

    let photo: PassPhoto
    let mark: Mark
    var selected = false
    var best = false
    let thumbnails: Thumbnails
    var onTap: (() -> Void)?
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    private var dim: Bool {
        switch mark {
        case .deleteMe, .decision(.delete): true
        default: false
        }
    }

    var body: some View {
        Color.gray.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill().opacity(dim ? 0.5 : 1) } }
            .overlay(alignment: .topLeading) { badge.padding(6) }
            .overlay(alignment: .topTrailing) {
                if best {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).shadow(radius: 2).padding(6).help(
                        "Vision's pick")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if case .decision = mark, let v = photo.verdict {
                    Text(v.kind).font(.caption2).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 4)).padding(6)
                }
            }
            .clipped()
            .overlay { if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 4) } }
            .clipShape(.rect(cornerRadius: 4))
            .contentShape(.rect)
            .onTapGesture { onTap?() }
            .help(photo.verdict.map { "\($0.kind): \($0.reason)" } ?? "")
            .onAppear {
                thumbnails.near(photo.id)
                requestID = thumbnails.request(photo.id) { image = $0 ?? image }
            }
            .onDisappear {
                if let requestID { thumbnails.cancel(requestID) }
                requestID = nil
            }
    }

    @ViewBuilder private var badge: some View {
        switch mark {
        case .none: EmptyView()
        case .deleteMe: label("✗ Delete Me", .red)
        case .decision(.delete): label("✗ Delete", .red)
        case .decision(.keep): EmptyView()  // most photos start as Keep: only the exceptions are marked
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: .rect(cornerRadius: 4))
    }
}

/// The large preview over the grid. It has no focus of its own: the grid keeps handling keys.
struct PhotoPreview: View {
    let preview: ReviewModel.Preview
    let thumbnails: Thumbnails

    var body: some View {
        GeometryReader { geo in
            Color.black
                .overlay {
                    LargeImage(id: preview.id, side: max(geo.size.width, geo.size.height), thumbnails: thumbnails)
                        .padding(12)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if let badge = preview.badge { chip(badge, preview.badge == "✓ Keep" ? .green : .red) }
                        if preview.best { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    }
                    .padding(16)
                }
                .overlay(alignment: .bottomLeading) {
                    if let reason = preview.reason { chip(reason, .black.opacity(0.6)).padding(16) }
                }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.callout.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color, in: .rect(cornerRadius: 5))
    }
}

/// One photo, aspect-fit, from `Thumbnails.requestLarge`: the local copy first, then the full one.
struct LargeImage: View {
    let id: String
    let side: CGFloat
    let thumbnails: Thumbnails
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Color.clear } }
            .task(id: id) {
                image = nil
                if let requestID { thumbnails.cancel(requestID) }
                let want = id
                requestID = thumbnails.requestLarge(want, side: side) { img in
                    if want == id { image = img ?? image }
                }
            }
            .onDisappear { if let requestID { thumbnails.cancel(requestID) } }
    }
}
