// Adds photos to a Photos album through PhotoKit, creating the album if missing.
// Usage: albums <album name>   with one photo UUID per stdin line.
// Prints "<added>\t<skipped>". Skipped: not found, or not in the user's own library (iCloud
// Shared Album photos resolve but can't join a regular album, and one fails the whole batch).
// Exits 3 with the authorization status on stderr when Photos access isn't granted.
// Built with photos_cleanup/Info.plist embedded: PhotoKit needs its usage string to prompt.
import Foundation
import Photos

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: albums <album name>\n".data(using: .utf8)!)
    exit(2)
}
let album = CommandLine.arguments[1]

var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
if status == .notDetermined {
    status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
}
guard status == .authorized else {
    FileHandle.standardError.write("Photos access not granted (status \(status.rawValue))\n".data(using: .utf8)!)
    exit(3)
}

var ids: [String] = []
while let line = readLine(strippingNewline: true), !line.isEmpty {
    ids.append("\(line)/L0/001")  // localIdentifier = osxphotos uuid + this suffix
}
var assets: [PHAsset] = []
PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in
    if a.sourceType.contains(.typeUserLibrary) { assets.append(a) }
}

let opts = PHFetchOptions()
opts.predicate = NSPredicate(format: "title == %@", album)
let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts)
    .firstObject
do {
    try PHPhotoLibrary.shared().performChangesAndWait {
        let req = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
            ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
        req.addAssets(assets as NSArray)
    }
} catch {
    FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
print("\(assets.count)\t\(ids.count - assets.count)")
