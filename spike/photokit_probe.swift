// Spike: can a command-line helper use PhotoKit instead of osxphotos + AppleScript?
//   photokit_probe auth          print / request Photos authorization
//   photokit_probe read          time a full-library fetch and per-asset resource lookups
//   photokit_probe add <album>   read "<uuid>" lines from stdin, add them to <album> (created
//                                if missing) in one performChanges call, and time it
// Build (embeds the Info.plist PhotoKit requires for its permission prompt):
//   swiftc -O spike/photokit_probe.swift -o /tmp/photokit_probe \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker spike/photokit_Info.plist
import Foundation
import Photos

func status() -> PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

func name(_ s: PHAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorized: "authorized"
    case .limited: "limited"
    @unknown default: "unknown(\(s.rawValue))"
    }
}

func elapsed(_ start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    return String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "auth":
    print("before: \(name(status()))")
    let after = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    print("after: \(name(after))")

case "read":
    guard status() == .authorized else {
        print("not authorized: \(name(status()))")
        exit(1)
    }
    var t = ContinuousClock.now
    let all = PHAsset.fetchAssets(with: nil)
    print("fetch \(all.count) assets: \(elapsed(t))")

    t = ContinuousClock.now
    var shots = 0
    var live = 0
    var fav = 0
    var videos = 0
    all.enumerateObjects { a, _, _ in
        if a.mediaSubtypes.contains(.photoScreenshot) { shots += 1 }
        if a.mediaSubtypes.contains(.photoLive) { live += 1 }
        if a.isFavorite { fav += 1 }
        if a.mediaType == .video { videos += 1 }
    }
    print("scan fields: \(elapsed(t))  screenshots=\(shots) live=\(live) favorites=\(fav) videos=\(videos)")

    t = ContinuousClock.now
    let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
    var memberships = 0
    albums.enumerateObjects { c, _, _ in memberships += PHAsset.fetchAssets(in: c, options: nil).count }
    print("user albums \(albums.count), memberships \(memberships): \(elapsed(t))")

    t = ContinuousClock.now
    let n = min(500, all.count)
    var withSize = 0
    var bytes: Int64 = 0
    for i in 0..<n {
        let res = PHAssetResource.assetResources(for: all.object(at: i))
        // "fileSize" is not public API; this measures whether it works and what it costs.
        if let r = res.first, let size = r.value(forKey: "fileSize") as? Int64 {
            withSize += 1
            bytes += size
        }
    }
    print(
        "resources for \(n): \(elapsed(t))  fileSize readable=\(withSize)  sample id=\(all.firstObject?.localIdentifier ?? "-")"
    )

case "add":
    guard status() == .authorized else {
        print("not authorized: \(name(status()))")
        exit(1)
    }
    guard let album = args.dropFirst().first else {
        print("usage: add <album>")
        exit(2)
    }
    var uuids: [String] = []
    while let line = readLine(strippingNewline: true), !line.isEmpty { uuids.append(line) }
    let ids = uuids.map { "\($0)/L0/001" }
    var t = ContinuousClock.now
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    print("resolved \(assets.count) of \(ids.count) uuids: \(elapsed(t))")

    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(format: "title == %@", album)
    let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts)
        .firstObject
    t = ContinuousClock.now
    try PHPhotoLibrary.shared().performChangesAndWait {
        let req =
            existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
            ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
        req.addAssets(assets)
    }
    print("added \(assets.count) to \"\(album)\" (\(existing == nil ? "created" : "existing")): \(elapsed(t))")

default:
    print("usage: photokit_probe auth | read | add <album>")
    exit(2)
}
