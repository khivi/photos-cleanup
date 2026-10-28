// The server's only door into the Photos library: PhotoKit reads and writes, plus Vision on
// PhotoKit images. Long-running: one JSON request per stdin line, one JSON reply per line.
//   {"op":"auth"}                                -> {"status":"authorized"} (prompts if undecided)
//   {"op":"list"}                                -> {"photos":[{uuid,date,w,h,shot,live,movie,fav,albums}]}
//   {"op":"image","uuid":U,"size":N,"path":P}    -> {"ok":true}  JPEG, longest side <= N
//   {"op":"vision","uuids":[U...]}               -> {"results":[{uuid,print,ptype,utility,score} | {uuid,error}]}
//   {"op":"add","album":A,"uuids":[U...]}        -> {"added":n,"skipped":m}
// Any failure replies {"error":"..."}. Built with Info.plist embedded: PhotoKit needs its
// usage string to show the permission prompt.
import AppKit
import Foundation
import Photos
import Vision

// Caches and the UI key photos by bare UUID; PhotoKit's localIdentifier adds this suffix.
let idSuffix = "/L0/001"

func reply(_ obj: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"error":"encode"}"#.utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func uuid(_ a: PHAsset) -> String { String(a.localIdentifier.prefix { $0 != "/" }) }

func assets(_ uuids: [String]) -> [String: PHAsset] {
    var out: [String: PHAsset] = [:]
    PHAsset.fetchAssets(withLocalIdentifiers: uuids.map { $0 + idSuffix }, options: nil)
        .enumerateObjects { a, _, _ in out[uuid(a)] = a }
    return out
}

// Photos' own local previews exist even for iCloud-only originals (Optimize Mac Storage);
// some have nothing larger than ~340px locally, so fall back to that size.
func cgImage(_ asset: PHAsset, maxSide: Int) -> CGImage? {
    for side in Set([maxSide, min(maxSide, 340)]).sorted(by: >) {
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        // Local only: an iCloud-only original would otherwise download mid-request.
        opts.isNetworkAccessAllowed = false
        var out: NSImage?
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: opts
        ) { img, _ in out = img }
        if let img = out?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return img }
    }
    return nil
}

func writeJPEG(_ img: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

func list() -> [String: Any] {
    var albumsOf: [String: [String]] = [:]
    let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
    albums.enumerateObjects { c, _, _ in
        let name = c.localizedTitle ?? ""
        PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in
            albumsOf[uuid(a), default: []].append(name)
        }
    }
    var photos: [[String: Any]] = []
    PHAsset.fetchAssets(with: nil).enumerateObjects { a, _, _ in
        let id = uuid(a)
        photos.append([
            "uuid": id,
            "date": a.creationDate?.timeIntervalSince1970 ?? NSNull(),
            "w": a.pixelWidth,
            "h": a.pixelHeight,
            "shot": a.mediaSubtypes.contains(.photoScreenshot),
            "live": a.mediaSubtypes.contains(.photoLive),
            "movie": a.mediaType == .video,
            "fav": a.isFavorite,
            "albums": albumsOf[id] ?? [],
        ])
    }
    return ["photos": photos]
}

// Feature print, isUtility and aesthetics score from one 1024px image. The server's
// similarity cutoff was calibrated on prints of roughly this size.
func vision(_ uuids: [String]) -> [String: Any] {
    let found = assets(uuids)
    let results: [[String: Any]] = uuids.map { id in
        guard let a = found[id], let img = cgImage(a, maxSide: 1024) else {
            return ["uuid": id, "error": "no local image"]
        }
        let printReq = VNGenerateImageFeaturePrintRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        do {
            try VNImageRequestHandler(cgImage: img).perform([printReq, aesthetics])
        } catch {
            return ["uuid": id, "error": error.localizedDescription]
        }
        guard let fp = printReq.results?.first, let ae = aesthetics.results?.first else {
            return ["uuid": id, "error": "no result"]
        }
        return [
            "uuid": id, "print": fp.data.base64EncodedString(), "ptype": fp.elementType.rawValue,
            "utility": ae.isUtility, "score": ae.overallScore,
        ]
    }
    return ["results": results]
}

func add(album: String, uuids: [String]) throws -> [String: Any] {
    // iCloud Shared Album photos resolve but can't join a regular album; one fails the batch.
    let mine = assets(uuids).values.filter { $0.sourceType.contains(.typeUserLibrary) }
    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(format: "title == %@", album)
    let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts)
        .firstObject
    try PHPhotoLibrary.shared().performChangesAndWait {
        let req = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
            ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
        req.addAssets(Array(mine) as NSArray)
    }
    return ["added": mine.count, "skipped": uuids.count - mine.count]
}

func authorized() -> Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

let statusNames: [PHAuthorizationStatus: String] = [
    .notDetermined: "notDetermined", .restricted: "restricted", .denied: "denied",
    .authorized: "authorized", .limited: "limited",
]

// requestImage returns nil, with no error, unless the process is an app; no Dock icon or window.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

while let line = readLine(strippingNewline: true) {
    guard let req = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let op = req["op"] as? String
    else { reply(["error": "bad request"]); continue }
    if op == "auth" {
        var s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .notDetermined { s = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        reply(["status": statusNames[s] ?? "unknown"])
        continue
    }
    guard authorized() else { reply(["error": "Photos access not granted"]); continue }
    let ids = req["uuids"] as? [String] ?? []
    switch op {
    case "list":
        reply(list())
    case "image":
        guard let id = req["uuid"] as? String, let size = req["size"] as? Int, let path = req["path"] as? String,
              let a = assets([id])[id], let img = cgImage(a, maxSide: size), writeJPEG(img, to: path)
        else { reply(["error": "no local image"]); break }
        reply(["ok": true])
    case "vision":
        reply(vision(ids))
    case "add":
        guard let album = req["album"] as? String else { reply(["error": "no album"]); break }
        do { reply(try add(album: album, uuids: ids)) } catch { reply(["error": error.localizedDescription]) }
    default:
        reply(["error": "unknown op \(op)"])
    }
}
