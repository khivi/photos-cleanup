import Foundation
import Photos
import PhotosCleanupCore

// Copies the library's originals, edits and Live Photo videos into <dest>/YYYY/MM. A rerun copies
// only photos new or changed since. Never deletes: a photo gone from the library stays here, so
// the export is a deletion record for `photos-import --skip`.

let arguments = CommandLine.arguments.dropFirst()
guard let destArg = arguments.first, !destArg.hasPrefix("--") else {
    print("usage: photos-export <dest> [--dry-run]")
    exit(64)
}
let dryRun = arguments.contains("--dry-run")
let dest = URL(filePath: (destArg as NSString).expandingTildeInPath).standardizedFileURL
let manifestURL = dest.appending(path: ".photos-export.tsv")

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let access = await PhotoKitLibrary().authorize()
guard access == "authorized" else {
    log("Photos access: \(access). Allow your terminal in System Settings → Privacy & Security → Photos.")
    exit(1)
}

var manifest = ExportManifest(tsv: (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? "")
@MainActor func saveManifest() throws {
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    try manifest.tsv.write(to: manifestURL, atomically: true, encoding: .utf8)
}

var assets: [PHAsset] = []
let fetch = PHFetchOptions()
fetch.includeHiddenAssets = true
fetch.includeAllBurstAssets = true
PHAsset.fetchAssets(with: fetch).enumerateObjects { a, _, _ in assets.append(a) }
let todo = assets.filter {
    !manifest.isCurrent(id: $0.localIdentifier, modified: $0.modificationDate?.timeIntervalSince1970 ?? 0)
}
let changed = todo.count { manifest.entries[$0.localIdentifier] != nil }
log(
    "library: \(assets.count); new: \(todo.count - changed); changed: \(changed); "
        + "unchanged: \(assets.count - todo.count)")
if dryRun { exit(0) }

let month = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy/MM"
    return f
}()

/// The resource's file name under the photo's stem; nil for resources not exported (adjustment
/// data, render previews).
func fileName(_ r: PHAssetResource, stem: String) -> String? {
    let ext = (r.originalFilename as NSString).pathExtension
    switch r.type {
    case .photo, .video, .alternatePhoto, .pairedVideo: return "\(stem).\(ext)"
    case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: return "\(stem)_edited.\(ext)"
    default: return nil
    }
}

let options = PHAssetResourceRequestOptions()
options.isNetworkAccessAllowed = true  // iCloud "Optimize Mac Storage" keeps only previews here

// ponytail: one photo at a time; a TaskGroup of a few if iCloud downloads make it too slow.
var exported = 0
var failed = 0
for a in todo {
    let resources = PHAssetResource.assetResources(for: a)
    guard let primary = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first
    else { continue }
    let dir = a.creationDate.map(month.string(from:)) ?? "undated"
    let name = (primary.originalFilename as NSString).deletingPathExtension
    let stem = manifest.stem(for: a.localIdentifier, dir: dir, name: name)
    do {
        try FileManager.default.createDirectory(
            at: dest.appending(path: dir), withIntermediateDirectories: true)
        var written: Set<String> = []
        for r in resources {
            guard let file = fileName(r, stem: stem), written.insert(file.lowercased()).inserted else { continue }
            let url = dest.appending(path: file)
            let part = url.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: part)
            // writeData refuses an existing file; .part keeps a killed run from leaving a truncated one.
            try await PHAssetResourceManager.default().writeData(for: r, toFile: part, options: options)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: part, to: url)
        }
        manifest.record(
            id: a.localIdentifier, modified: a.modificationDate?.timeIntervalSince1970 ?? 0, stem: stem)
        exported += 1
        if exported % 100 == 0 {
            try saveManifest()
            log("\(exported)/\(todo.count)")
        }
    } catch {
        failed += 1
        log("failed: \(stem): \(error.localizedDescription)")
    }
}
try saveManifest()
log("exported: \(exported); failed: \(failed) (a rerun retries them); \(dest.path)")
exit(failed == 0 ? 0 : 1)
