import AppKit
import Foundation
import Photos
import UniformTypeIdentifiers
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
    /// Deletes the photos it finds; macOS asks the user first. Returns how many were deleted:
    /// 0 when the user cancels.
    func delete(uuids: [String]) throws -> Int
    /// Every photo and video to back up, hidden ones and every burst frame included.
    func exportable() throws -> [ExportItem]
    /// The photo's original file name without extension, the stem its exported files share; nil if it's gone.
    func exportName(_ uuid: String) -> String?
    /// Writes the photo's files as `<stem>.<ext>` and `<stem>_edited.<ext>` under `dest`,
    /// downloading iCloud originals.
    func export(_ uuid: String, stem: String, to dest: URL) async throws
    /// Every photo and video with a capture date, for Import to match files against. Photos in a
    /// Delete Me album are left out: after Delete in Photos… the file is the only copy.
    func importIndex() throws -> [LibraryShot]
    /// The file names Photos keeps for the photo (a Live Photo has two), lowercased.
    func fileNames(_ uuid: String) -> Set<String>
    /// The photo's 16×16 grayscale key, from an original already on this Mac; nil if it's only in iCloud.
    func pictureKey(_ uuid: String) -> [UInt8]?
}

public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case accessDenied
    case failed(String)

    public var description: String {
        switch self {
        case .accessDenied: "Photos access not granted. Allow it in System Settings, Privacy & Security, Photos."
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
        // Selfies are a smart album, not a media subtype.
        var selfies: Set<String> = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
            .enumerateObjects { c, _, _ in
                PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in selfies.insert(Self.uuid(a)) }
            }
        var out: [Photo] = []
        PHAsset.fetchAssets(with: nil).enumerateObjects { a, _, _ in
            let id = Self.uuid(a)
            out.append(
                Photo(
                    uuid: id, date: a.creationDate, screenshot: a.mediaSubtypes.contains(.photoScreenshot),
                    isMovie: a.mediaType == .video, duration: a.duration,
                    favorite: a.isFavorite, edited: a.hasAdjustments, albums: albumsOf[id] ?? [],
                    live: a.mediaSubtypes.contains(.photoLive), selfie: selfies.contains(id),
                    screenRecording: a.mediaSubtypes.contains(.videoScreenRecording)))
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

    public func delete(uuids: [String]) throws -> Int {
        try requireAccess()
        let found = Array(assets(uuids).values)
        guard !found.isEmpty else { return 0 }
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.deleteAssets(found as NSArray)
            }
        } catch {
            let e = error as NSError
            // Cancelling macOS's confirmation: PHPhotosError.userCancelled, or Cocoa's NSUserCancelledError.
            if (e.domain == PHPhotosErrorDomain && e.code == PHPhotosError.userCancelled.rawValue)
                || (e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError)
            {
                return 0
            }
            throw LibraryError.failed(error.localizedDescription)
        }
        return found.count
    }
}

extension PhotoKitLibrary {
    static var everyAsset: PHFetchOptions {
        let o = PHFetchOptions()
        o.includeHiddenAssets = true
        o.includeAllBurstAssets = true
        return o
    }

    func asset(_ uuid: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [uuid + Self.idSuffix], options: Self.everyAsset).firstObject
    }

    func resources(_ uuid: String) -> [PHAssetResource] { asset(uuid).map(PHAssetResource.assetResources) ?? [] }

    public func importIndex() throws -> [LibraryShot] {
        try requireAccess()
        var waiting: Set<String> = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
            guard Passes.waitingAlbum(in: [c.localizedTitle ?? ""]) != nil else { return }
            PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in waiting.insert(Self.uuid(a)) }
        }
        var out: [LibraryShot] = []
        PHAsset.fetchAssets(with: Self.everyAsset).enumerateObjects { a, _, _ in
            let id = Self.uuid(a)
            if let d = a.creationDate, !waiting.contains(id) {
                out.append(LibraryShot(id: id, date: d, width: a.pixelWidth, height: a.pixelHeight))
            }
        }
        return out
    }

    public func fileNames(_ uuid: String) -> Set<String> {
        Set(resources(uuid).compactMap { $0.fileName?.lowercased() })
    }

    /// Only originals already on this Mac: an iCloud download per candidate would take hours.
    public func pictureKey(_ uuid: String) -> [UInt8]? {
        guard let a = asset(uuid), a.mediaType == .image else { return nil }
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.isNetworkAccessAllowed = false
        nonisolated(unsafe) var key: [UInt8]?
        PHImageManager.default().requestImageDataAndOrientation(for: a, options: opts) { data, _, _, _ in
            key = data.flatMap { PhotosCleanupCore.pictureKey(CGImageSourceCreateWithData($0 as CFData, nil)) }
        }
        return key
    }

    public func exportable() throws -> [ExportItem] {
        try requireAccess()
        var out: [ExportItem] = []
        PHAsset.fetchAssets(with: Self.everyAsset).enumerateObjects { a, _, _ in
            out.append(
                ExportItem(
                    uuid: Self.uuid(a), modified: a.modificationDate?.timeIntervalSince1970 ?? 0, date: a.creationDate))
        }
        return out
    }

    public func exportName(_ uuid: String) -> String? {
        let rs = resources(uuid)
        return (rs.first { $0.type == .photo || $0.type == .video } ?? rs.first)
            .map { r in r.fileName.map { ($0 as NSString).deletingPathExtension } ?? uuid }
    }

    public func export(_ uuid: String, stem: String, to dest: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: dest.appending(path: stem).deletingLastPathComponent(), withIntermediateDirectories: true)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // Optimize Mac Storage keeps only previews here
        var written: Set<String> = []
        for r in resources(uuid) {
            let suffix: String
            switch r.type {
            case .photo, .video, .alternatePhoto, .pairedVideo: suffix = ""
            case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: suffix = "_edited"
            default: continue  // adjustment data, render previews
            }
            let ext =
                r.fileName.map { ($0 as NSString).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
                ?? UTType(r.uniformTypeIdentifier)?.preferredFilenameExtension ?? ""
            let file = "\(stem)\(suffix).\(ext)"
            guard written.insert(file.lowercased()).inserted else { continue }
            let url = dest.appending(path: file)
            let part = url.appendingPathExtension("part")
            try? fm.removeItem(at: part)
            // writeData refuses an existing file; .part keeps a stopped run from leaving a truncated one.
            try await PHAssetResourceManager.default().writeData(for: r, toFile: part, options: options)
            try? fm.removeItem(at: url)
            try fm.moveItem(at: part, to: url)
        }
    }
}

func analyse(_ img: CGImage) -> VisionResult? {
    let printReq = VNGenerateImageFeaturePrintRequest()
    let aesthetics = VNCalculateImageAestheticsScoresRequest()
    guard (try? VNImageRequestHandler(cgImage: img).perform([printReq, aesthetics])) != nil,
        let fp = printReq.results?.first, let ae = aesthetics.results?.first
    else { return nil }
    return VisionResult(
        print: floats(fp.data, elementType: fp.elementType), utility: ae.isUtility,
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

/// This process's memory in MB, the figure Activity Monitor's Memory column shows; nil if unreadable.
public func footprintMB() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
}

extension PHAssetResource {
    /// originalFilename is declared non-optional but is nil for some resources (type 17 on 315 photos
    /// here): bridged to NSString it traps, and as String? the optimizer drops the nil check. KVC sees it.
    var fileName: String? { (value(forKey: "originalFilename") as? String).flatMap { $0.isEmpty ? nil : $0 } }
}
