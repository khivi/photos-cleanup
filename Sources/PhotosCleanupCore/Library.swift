import AppKit
import Foundation
import Photos
import Vision

/// The Photos library. PhotoKitLibrary is the real one; tests substitute a fake.
public protocol PhotoLibrary: Sendable {
    /// "authorized", "denied", "limited", "restricted" or "notDetermined"; prompts if undecided.
    func authorize() async -> String
    func photos() throws -> [Photo]
    /// nil per photo when it has no local image.
    func vision(_ uuids: [String]) -> [String: VisionResult?]
    /// Adds the photos it finds in the user's own library; returns how many.
    func add(album: String, uuids: [String]) throws -> Int
}

public enum LibraryError: Error, CustomStringConvertible {
    case accessDenied
    case failed(String)

    public var description: String {
        switch self {
        case .accessDenied: "Photos access not granted"
        case .failed(let why): why
        }
    }
}

/// PhotoKit, plus Vision on PhotoKit images. requestImage returns nil, with no error, unless the
/// process is an app: the executable must create NSApplication.shared before using this.
public struct PhotoKitLibrary: PhotoLibrary {
    // The UI and the caches key photos by bare UUID; localIdentifier adds this suffix.
    static let idSuffix = "/L0/001"

    public init() {}

    public func authorize() async -> String {
        var s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .notDetermined { s = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .limited: return "limited"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func uuid(_ a: PHAsset) -> String { String(a.localIdentifier.prefix { $0 != "/" }) }

    /// The PHAssets for these photo uuids, e.g. to feed a PHCachingImageManager.
    public func assets(_ uuids: [String]) -> [String: PHAsset] {
        var out: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: uuids.map { $0 + Self.idSuffix }, options: nil)
            .enumerateObjects { a, _, _ in out[Self.uuid(a)] = a }
        return out
    }

    func requireAccess() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw LibraryError.accessDenied
        }
    }

    public func photos() throws -> [Photo] {
        try requireAccess()
        var albumsOf: [String: [String]] = [:]
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { c, _, _ in
                let name = c.localizedTitle ?? ""
                PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in
                    albumsOf[Self.uuid(a), default: []].append(name)
                }
            }
        var out: [Photo] = []
        PHAsset.fetchAssets(with: nil).enumerateObjects { a, _, _ in
            let id = Self.uuid(a)
            out.append(
                Photo(
                    uuid: id, date: a.creationDate, width: a.pixelWidth, height: a.pixelHeight,
                    screenshot: a.mediaSubtypes.contains(.photoScreenshot),
                    livePhoto: a.mediaSubtypes.contains(.photoLive), isMovie: a.mediaType == .video,
                    favorite: a.isFavorite, albums: albumsOf[id] ?? []))
        }
        return out
    }

    /// Photos' own local previews exist even for iCloud-only originals (Optimize Mac Storage);
    /// some have nothing larger than ~340px locally, so fall back to that size.
    func cgImage(_ asset: PHAsset, maxSide: Int) -> CGImage? {
        for side in Set([maxSide, min(maxSide, 340)]).sorted(by: >) {
            let opts = PHImageRequestOptions()
            opts.isSynchronous = true
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            // Local only: an iCloud-only original would otherwise download mid-request.
            opts.isNetworkAccessAllowed = false
            nonisolated(unsafe) var out: NSImage?
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit,
                options: opts
            ) { img, _ in out = img }
            if let img = out?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return img }
        }
        return nil
    }

    /// Feature print, isUtility and aesthetics score from one 1024px image. The similarity cutoff
    /// was calibrated on prints of roughly this size.
    public func vision(_ uuids: [String]) -> [String: VisionResult?] {
        let found = assets(uuids)
        // Each worker takes every 4th photo and writes only its own slots, so no lock is needed.
        let workers = 4
        var results = [VisionResult?](repeating: nil, count: uuids.count)
        results.withUnsafeMutableBufferPointer { buf in
            nonisolated(unsafe) let slots = buf
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                for i in stride(from: w, to: uuids.count, by: workers) {
                    slots[i] = found[uuids[i]].flatMap { cgImage($0, maxSide: 1024) }.flatMap(analyse)
                }
            }
        }
        return Dictionary(zip(uuids, results)) { $1 }
    }

    public func add(album: String, uuids: [String]) throws -> Int {
        try requireAccess()
        // iCloud Shared Album photos resolve but can't join a regular album; one fails the batch.
        let mine = assets(uuids).values.filter { $0.sourceType.contains(.typeUserLibrary) }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", album)
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: opts
        ).firstObject
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let req =
                    existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                    ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
                req.addAssets(Array(mine) as NSArray)
            }
        } catch {
            throw LibraryError.failed(error.localizedDescription)
        }
        return mine.count
    }
}

func analyse(_ img: CGImage) -> VisionResult? {
    let printReq = VNGenerateImageFeaturePrintRequest()
    let aesthetics = VNCalculateImageAestheticsScoresRequest()
    guard (try? VNImageRequestHandler(cgImage: img).perform([printReq, aesthetics])) != nil,
        let fp = printReq.results?.first, let ae = aesthetics.results?.first
    else { return nil }
    return VisionResult(print: floats(fp.data, elementType: fp.elementType), utility: ae.isUtility,
                        score: Double(ae.overallScore))
}

func floats(_ data: Data, elementType: VNElementType) -> [Float] {
    data.withUnsafeBytes { raw in
        elementType == .double
            ? raw.bindMemory(to: Double.self).map(Float.init)
            : Array(raw.bindMemory(to: Float.self))
    }
}

/// Runs blocking PhotoKit and Vision work off Swift's cooperative threads.
public func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result(catching: work)) }
    }
}
