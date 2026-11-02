import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Photos
import PhotosCleanupCore
import UniformTypeIdentifiers

// Never writes to the library. Sorts the folder into Done/ (in the library, or a copy of a
// file that is) and Import/ (to drag into Photos), paths mirrored; a rerun moves what Import/
// now has in the library to Done/, and what Done/ has that the library lacks back to Import/.
// A --skip folder (a library export) is never moved, and never new, nor are its photos' copies
// elsewhere: it still holds photos deleted from the library.

let arguments = CommandLine.arguments.dropFirst()
guard let rootArg = arguments.first else {
    print("usage: photos-import <dir> [--skip <subdir>]... [--dry-run]")
    exit(64)
}
let options = zip(arguments, arguments.dropFirst())
let skip = options.filter { $0.0 == "--skip" }.map { $0.1 }
let dryRun = arguments.contains("--dry-run")
// realpath, not resolvingSymlinksInPath: the enumerator's paths keep /private (/tmp is /private/tmp).
guard let real = realpath((rootArg as NSString).expandingTildeInPath, nil) else {
    print("\(rootArg): no such folder")
    exit(66)
}
let root = URL(filePath: String(cString: real))
free(real)
let report = URL(filePath: "/tmp/photos-import.tsv")

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let access = await PhotoKitLibrary().authorize()
guard access == "authorized" else {
    log("Photos access: \(access). Allow your terminal in System Settings → Privacy & Security → Photos.")
    exit(1)
}

// A Delete Me photo is not in the library: after Delete in Photos… the file is the only copy.
var waiting: Set<String> = []
PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
    guard Passes.waitingAlbum(in: [c.localizedTitle ?? ""]) != nil else { return }
    PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in waiting.insert(a.localIdentifier) }
}
var library: [(id: String, date: Date, width: Int, height: Int)] = []
let fetch = PHFetchOptions()
fetch.includeHiddenAssets = true
fetch.includeAllBurstAssets = true
PHAsset.fetchAssets(with: fetch).enumerateObjects { a, _, _ in
    if let d = a.creationDate, !waiting.contains(a.localIdentifier) {
        library.append((a.localIdentifier, d, a.pixelWidth, a.pixelHeight))
    }
}
let index = LibraryIndex(library)
log("library: \(library.count) photos and videos, \(waiting.count) in Delete Me left out")

// File names Photos keeps per photo (a Live Photo has two), lowercased.
var namesMemo: [String: Set<String>] = [:]
@MainActor func names(_ id: String) -> Set<String> {
    if let n = namesMemo[id] { return n }
    var n: Set<String> = []
    if let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
        n = Set(
            // originalFilename is declared non-optional but is nil for some resources.
            PHAssetResource.assetResources(for: a).compactMap { r in
                (r.originalFilename as String?)?.lowercased()
            })
    }
    namesMemo[id] = n
    return n
}
// 16×16 grayscale; under 8 mean levels apart is the same picture (a re-encode or a resize), and
// in one folder's offset matches no other photo came within 25.
func thumb(_ src: CGImageSource?) -> [UInt8]? {
    let opts =
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
    guard let src, let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
    var px = [UInt8](repeating: 0, count: 256)
    guard
        let ctx = CGContext(
            data: &px, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
    return px
}
func samePicture(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
    guard let a, let b else { return false }
    return zip(a, b).map { abs(Int($0) - Int($1)) }.reduce(0, +) < 8 * a.count
}
var fileThumbs: [URL: [UInt8]?] = [:]
@MainActor func fileThumb(_ url: URL) -> [UInt8]? {
    if let t = fileThumbs[url] { return t }
    let t = thumb(CGImageSourceCreateWithURL(url as CFURL, nil))
    fileThumbs[url] = t
    return t
}
// Only originals already on this Mac: an iCloud download per candidate would take hours.
@MainActor func libraryThumb(_ id: String) -> [UInt8]? {
    guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject, a.mediaType == .image
    else { return nil }
    let opts = PHImageRequestOptions()
    opts.isSynchronous = true
    opts.isNetworkAccessAllowed = false
    var t: [UInt8]?
    PHImageManager.default().requestImageDataAndOrientation(for: a, options: opts) { data, _, _, _ in
        t = data.flatMap { thumb(CGImageSourceCreateWithData($0 as CFData, nil)) }
    }
    return t
}
let bySize = Dictionary(grouping: library) { [max($0.width, $0.height), min($0.width, $0.height)] }

struct File {
    let url: URL
    let size: Int
    let type: UTType?
    let fileDate: Date?
    var rel: String { String(url.path.dropFirst(root.path.count + 1)) }
    /// A backup may keep Live Photo videos in a `Live Videos` subfolder.
    var stem: String {
        let dir = url.deletingLastPathComponent()
        let base = dir.lastPathComponent == "Live Videos" ? dir.deletingLastPathComponent() : dir
        return base.appending(path: url.deletingPathExtension().lastPathComponent).path.lowercased()
    }
}

let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentTypeKey, .creationDateKey]
var files: [File] = []
let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])!
for case let url as URL in all.allObjects {
    guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
    files.append(File(url: url, size: v.fileSize ?? 0, type: v.contentType, fileDate: v.creationDate))
}
func isSkipped(_ f: File) -> Bool { skip.contains { f.rel.hasPrefix($0 + "/") } }
func isDone(_ f: File) -> Bool { f.rel.hasPrefix("Done/") }
let checkDate = "Import/Check date/"
// For copies: skipped folders, then Import/, then Done/ first, so their photos are the originals
// that copies elsewhere point to, and a rerun never sends a second copy to Import/.
func order(_ f: File) -> Int { isSkipped(f) ? 0 : f.rel.hasPrefix("Import/") ? 1 : isDone(f) ? 2 : 3 }
files.sort { (order($0), $0.url.path) < (order($1), $1.url.path) }
log("folder: \(files.count) files")

func isImage(_ f: File) -> Bool { f.type?.conforms(to: .image) == true }
func isMovie(_ f: File) -> Bool { f.type?.conforms(to: .movie) == true }

func sha(_ url: URL) -> Data? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize())
}
var copyOf: [String: String] = [:]
for group in Dictionary(grouping: files.filter { isImage($0) || isMovie($0) }, by: \.size).values
where group.count > 1 {
    var first: [Data: String] = [:]
    for f in group {
        guard let h = sha(f.url) else { continue }
        if let orig = first[h] { copyOf[f.rel] = orig } else { first[h] = f.rel }
    }
}
log("copies within the folder: \(copyOf.count)")

// Photos reads an EXIF time without OffsetTimeOriginal in the Mac's time zone, as here; with GPS it
// may place the photo in the zone where it was taken, which LibraryIndex's offsets cover.
func exifFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
}
let exifDate = exifFormatter("yyyy:MM:dd HH:mm:ss")
let exifDateWithOffset = exifFormatter("yyyy:MM:dd HH:mm:ssxxx")

/// `trusted`: a camera's capture time (EXIF DateTimeOriginal or DateTimeDigitized). Without one,
/// Photos falls back to the file's creation date: when the backup was copied, not the photo taken.
func imageInfo(_ url: URL) -> (date: Date?, trusted: Bool, width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
        let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    // Scans often carry only XMP CreateDate ("2011-05-16T12:35:55+05:30"), which Photos takes as
    // the capture time; TIFF DateTime is when the file was last edited.
    let xmp = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
        .flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:CreateDate" as CFString) as String? }
        .map { String($0.prefix(19)).replacingOccurrences(of: "-", with: ":").replacingOccurrences(of: "T", with: " ") }
    let camera =
        (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]) as? String
    if let camera, let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String,
        let d = exifDateWithOffset.date(from: camera + offset)
    {
        return (d, true, w, h)
    }
    let s = camera ?? xmp ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
    return (s.flatMap(exifDate.date(from:)), camera.flatMap(exifDate.date(from:)) != nil, w, h)
}

func movieInfo(_ url: URL) async -> (date: Date?, trusted: Bool, width: Int, height: Int)? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
        let size = try? await track.load(.naturalSize)
    else { return nil }
    let date = try? await asset.load(.creationDate)?.load(.dateValue)
    return (date, date != nil, Int(abs(size.width)), Int(abs(size.height)))
}

// A Live Photo's video has its still's name; the library holds the two as one.
let imageStems = Set(files.filter(isImage).map(\.stem))

// Same size and capture time in another folder: a re-encoded copy (Amazon exports).
// In the same folder: frames from one second, so new; a skipped photo is lost, an extra
// import lands in Photos' Duplicates album.
var newShots = LibraryIndex()
// Per folder, with Done/, Import/ and Import/Check date/ seen as the folder they mirror, so a
// file's match doesn't change when it moves.
func mirrored(_ rel: String) -> String {
    let dir = (rel as NSString).deletingLastPathComponent
    for p in [checkDate, "Import/", "Done/"] where (dir + "/").hasPrefix(p) {
        return String((dir + "/").dropFirst(p.count))
    }
    return dir + "/"
}
var claimed: [String: Set<String>] = [:]  // library ids matched
let siblings = Dictionary(grouping: files) { mirrored($0.rel) }.mapValues {
    Set($0.map { $0.url.lastPathComponent.lowercased() })
}
func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }
/// Whether library photo `id` is this file's rather than a sibling's in its folder (burst frames of
/// one second, or `IMG_1.JPG` and its rotated `IMG_1.jpeg`, match the same photo). Decided by
/// names, never by which file comes first, so the answer doesn't change when a file moves.
@MainActor func owns(_ f: File, _ id: String) -> Bool {
    let full = f.url.lastPathComponent.lowercased()
    let n = names(id)
    let others = (siblings[mirrored(f.rel)] ?? []).subtracting([full])
    if n.contains(full) { return true }
    if !n.isDisjoint(with: others) { return false }
    let stems = Set(n.map(stem))
    guard stems.contains(stem(full)) else { return others.allSatisfy { !stems.contains(stem($0)) } }
    return others.allSatisfy { !stems.contains(stem($0)) || full < $0 }
}
var rows: [(status: String, file: File, detail: String)] = []
// Matching runs in mirrored order, skipped folders first: where two files tie for one library
// photo (burst frames of one second, renamed exports), the first wins, and that must not depend on
// whether a file sits in Done/ or Import/, or each run would swap them.
files.sort {
    let a = (isSkipped($0) ? 0 : 1, mirrored($0.rel) + $0.url.lastPathComponent, $0.rel)
    let b = (isSkipped($1) ? 0 : 1, mirrored($1.rel) + $1.url.lastPathComponent, $1.rel)
    return a < b
}
for (n, f) in files.enumerated() {
    if n % 5000 == 0 { log("\(n)/\(files.count)") }
    let row = { (status: String, detail: String) in rows.append((status, f, detail)) }
    // Inside a Photos library package only originals/ holds photos; resources/ is its previews and renders.
    if f.rel.contains(".photoslibrary/") && !f.rel.contains(".photoslibrary/originals/") {
        row("library cache", "")
        continue
    }
    if !isImage(f) && !isMovie(f) {
        row("other", f.type?.identifier ?? f.url.pathExtension)
        continue
    }
    if let orig = copyOf[f.rel] {
        row("copy", orig)
        continue
    }
    if isSkipped(f) {
        if isImage(f), let info = imageInfo(f.url), let d = info.date {
            newShots.add(id: f.rel, date: d, width: info.width, height: info.height)
        } else if isMovie(f), let info = await movieInfo(f.url), let d = info.date {
            newShots.add(id: f.rel, date: d, width: info.width, height: info.height)
        }
        row("skipped", "")
        continue
    }
    if isMovie(f) && imageStems.contains(f.stem) {
        row("live video", "")
        continue
    }
    guard let info = isImage(f) ? imageInfo(f.url) : await movieInfo(f.url) else {
        row("unreadable", "")
        continue
    }
    let dims = "\(info.width)x\(info.height)"
    let name = f.url.deletingPathExtension().lastPathComponent.lowercased()
    let stemmed = { (id: String) in names(id).map(stem) }
    // QuickTime's zero date is 1904; a reset camera writes 1900.
    let dated = info.date.map { info.trusted && Calendar.current.component(.year, from: $0) > 1904 && $0 < Date() }
    // A Check date photo's date was fixed by hand in Photos after import, so only name and size
    // still match. By its date, not its folder, so the answer holds once it moves to Done/.
    let byName =
        dated != true
        ? bySize[[max(info.width, info.height), min(info.width, info.height)]]?.filter { stemmed($0.id).contains(name) }
        : nil
    if let byName, byName.count == 1 {
        row("in library by name", "\(dims)\t\(byName[0].id)")
    } else if let d = info.date {
        let dir = f.url.deletingLastPathComponent().path
        let confirm = { (id: String) in
            stemmed(id).contains(name) || (isImage(f) && samePicture(libraryThumb(id), fileThumb(f.url)))
        }
        let here = mirrored(f.rel)
        var excluding = claimed[here] ?? []
        var found: String?
        while let id = index.match(
            date: d, width: info.width, height: info.height, excluding: excluding, confirm: confirm)
        {
            if owns(f, id) {
                found = id
                break
            }
            excluding.insert(id)
        }
        if let id = found {
            claimed[here, default: []].insert(id)
            row("in library", "\(dims)\t\(id)")
        } else if let orig = newShots.match(
            date: d, width: info.width, height: info.height,
            confirm: { isImage(f) && samePicture(fileThumb(root.appending(path: $0)), fileThumb(f.url)) }),
            !orig.hasPrefix(String(dir.dropFirst(root.path.count + 1)) + "/")
        {
            row("same shot", "\(dims)\t\(orig)")
        } else {
            newShots.add(id: f.rel, date: d, width: info.width, height: info.height)
            row(dated == true ? "new" : "new check date", dims)
        }
    } else if let d = f.fileDate,
        // Photos sometimes dates an undated file a second before its file date.
        let id = [d, d - 1].lazy.compactMap({ index.match(date: $0, width: info.width, height: info.height) }).first
    {
        row("in library by file date", "\(dims)\t\(id)")
    } else {
        row("new undated", dims)
    }
}

try rows.map { "\($0.status)\t\($0.file.rel)\t\($0.detail)" }.joined(separator: "\n")
    .write(to: report, atomically: true, encoding: .utf8)

let statuses = [
    "in library", "in library by file date", "in library by name", "copy", "same shot", "live video", "new",
    "new check date", "new undated", "unreadable",
    "library cache", "skipped", "other",
]
let folder = { (f: File) in f.rel.split(separator: "/").dropLast().prefix(2).joined(separator: "/") }
let byFolder = Dictionary(grouping: rows) { folder($0.file) }
print((["folder"] + statuses).joined(separator: "\t"))
for (name, rs) in byFolder.sorted(by: { $0.key < $1.key }) + [("TOTAL", rows)] {
    print(
        ([name.isEmpty ? "." : name] + statuses.map { s in String(rs.count { $0.status == s }) })
            .joined(separator: "\t"))
}
log("report: \(report.path)")

let byRel = Dictionary(rows.map { ($0.file.rel, $0) }, uniquingKeysWith: { a, _ in a })
let stills = Dictionary(grouping: rows.filter { isImage($0.file) }, by: \.file.stem)
let byStem = Dictionary(grouping: rows.filter { isImage($0.file) || isMovie($0.file) }, by: \.file.stem)
var memo: [String: Bool] = [:]
func origin(_ r: (status: String, file: File, detail: String)) -> String {
    String(r.detail.split(separator: "\t").last ?? "")
}
@MainActor func inLibrary(_ rel: String) -> Bool {
    if let d = memo[rel] { return d }
    guard let r = byRel[rel] else { return false }
    let d: Bool
    switch r.status {
    case "in library", "in library by file date", "in library by name": d = true
    case "copy", "same shot": d = inLibrary(origin(r))
    // A Live Photo's video may exist only here: it needs its photo in the library, not just a copy.
    case "live video", "other":
        d = stills[r.file.stem]?.contains { $0.file.rel != rel && inLibrary($0.file.rel) } ?? false
    default: d = false
    }
    memo[rel] = d
    return d
}
// A copy is done once its original is in the library; until then it stays put, so Done/ never
// holds the only copy of a photo to import. A --skip folder stays whole.
@MainActor func done(_ rel: String) -> Bool {
    guard let f = byRel[rel]?.file, !isSkipped(f) else { return false }
    let status = byRel[rel]?.status
    // A sidecar goes with its photo or video; Apple names an edit's original-adjustments `<name>O.aae`.
    if status == "other",
        let media = byStem[f.stem] ?? (f.stem.hasSuffix("o") ? byStem[String(f.stem.dropLast())] : nil)
    {
        return media.contains { $0.file.rel != rel && done($0.file.rel) }
    }
    return status == "library cache" || inLibrary(rel)
}
// A Photos library package moves whole, to Done/ only if every file in it is done; else it stays.
@MainActor func unit(_ rel: String) -> String {
    guard let r = rel.range(of: ".photoslibrary/") else { return rel }
    return String(rel[..<r.lowerBound]) + ".photoslibrary"
}
var unitDone: [String: Bool] = [:]
for r in rows {
    unitDone[unit(r.file.rel), default: true] = unitDone[unit(r.file.rel), default: true] && done(r.file.rel)
}
// Not done: a photo or video Photos can read goes to Import/, a sidecar with it; the rest stays.
@MainActor func toImport(_ rel: String) -> Bool {
    guard let r = byRel[rel], !isSkipped(r.file) else { return false }
    if r.status == "other",
        let media = byStem[r.file.stem] ?? (r.file.stem.hasSuffix("o") ? byStem[String(r.file.stem.dropLast())] : nil)
    {
        return media.contains { $0.file.rel != rel && toImport($0.file.rel) }
    }
    return ["new", "new check date", "new undated", "live video"].contains(r.status)
}
// A photo whose date Photos would get wrong goes to Import/Check date/, its video and sidecar with it.
let checkStems = Set(rows.filter { ["new check date", "new undated"].contains($0.status) }.map(\.file.stem))
func needsCheck(_ f: File) -> Bool {
    checkStems.contains(f.stem) || (f.stem.hasSuffix("o") && checkStems.contains(String(f.stem.dropLast())))
}

let fm = FileManager.default
var moves: [(from: String, to: String)] = []
for (u, d) in unitDone.sorted(by: { $0.key < $1.key }) {
    guard let r = byRel[u] ?? rows.first(where: { unit($0.file.rel) == u }), !isSkipped(r.file) else { continue }
    let inImport = u.hasPrefix("Import/")
    let inDone = u.hasPrefix("Done/")
    let prefix = u.hasPrefix(checkDate) ? checkDate.count : inImport ? "Import/".count : inDone ? "Done/".count : 0
    let rel = String(u.dropFirst(prefix))
    if d {
        if !inDone { moves.append((u, "Done/" + rel)) }
    } else if !inImport, u == r.file.rel, toImport(u) {
        // From Done/ too: a photo there is not in the library (deleted since, or sorted by an older
        // matcher), and its copies elsewhere wait on it.
        // A Live Photo's video goes next to its still, where Photos pairs them.
        let dest = needsCheck(r.file) ? checkDate : "Import/"
        moves.append((u, dest + rel.replacingOccurrences(of: "/Live Videos/", with: "/")))
    }
}
let toDone = moves.count { $0.to.hasPrefix("Done/") }
let fromDone = moves.count { $0.from.hasPrefix("Done/") }
log(
    "\(dryRun ? "would move" : "moving"): \(toDone) to Done, \(moves.count - toDone) to Import"
        + " (\(fromDone) of them from Done/, not in the library)")
if dryRun { exit(0) }
var failed = 0
for m in moves {
    let dest = root.appending(path: m.to)
    do {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: root.appending(path: m.from), to: dest)
    } catch {
        log("not moved: \(m.from): \(error.localizedDescription)")
        failed += 1
    }
}
// Drop folders the moves emptied; Done/, Import/ and --skip folders stay.
let dirs = (fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL] ?? [])
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .map { String($0.path.dropFirst(root.path.count + 1)) }
    .filter { d in !["Done", "Import"].contains(d) && !skip.contains { d == $0 || d.hasPrefix($0 + "/") } }
    .filter { !$0.contains(".photoslibrary") }
for d in dirs.sorted(by: { $0.count > $1.count }) {
    let url = root.appending(path: d)
    guard let entries = try? fm.contentsOfDirectory(atPath: url.path), entries.allSatisfy({ $0 == ".DS_Store" })
    else { continue }
    try? fm.removeItem(at: url)
}
log("moved: \(moves.count - failed); not moved: \(failed)")
