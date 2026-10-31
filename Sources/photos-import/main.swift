import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Photos
import PhotosCleanupCore
import UniformTypeIdentifiers

// Reads only. A --skip folder (a library export) is never new, nor are its photos' copies
// elsewhere: the export still holds photos deleted from the library.

let arguments = CommandLine.arguments.dropFirst()
guard let rootArg = arguments.first else {
    print("usage: photos-import <dir> [--skip <subdir>]... [--stage <new dir> [--only <subdir>]]")
    exit(64)
}
let options = zip(arguments, arguments.dropFirst())
let skip = options.filter { $0.0 == "--skip" }.map { $0.1 }
let only = options.first { $0.0 == "--only" }.map { $0.1 + "/" } ?? ""
let stage = options.first { $0.0 == "--stage" }.map { URL(filePath: ($0.1 as NSString).expandingTildeInPath) }
if let stage, FileManager.default.fileExists(atPath: stage.path) {
    print("\(stage.path) exists; --stage takes a new folder")
    exit(64)
}
let root = URL(filePath: (rootArg as NSString).expandingTildeInPath).standardizedFileURL
let report = URL(filePath: "/tmp/photos-import.tsv")

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let access = await PhotoKitLibrary().authorize()
guard access == "authorized" else {
    log("Photos access: \(access). Allow your terminal in System Settings → Privacy & Security → Photos.")
    exit(1)
}

var library: [(id: String, date: Date, width: Int, height: Int)] = []
let fetch = PHFetchOptions()
fetch.includeHiddenAssets = true
fetch.includeAllBurstAssets = true
PHAsset.fetchAssets(with: fetch).enumerateObjects { a, _, _ in
    if let d = a.creationDate { library.append((a.localIdentifier, d, a.pixelWidth, a.pixelHeight)) }
}
let index = LibraryIndex(library)
log("library: \(library.count) photos and videos")

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
// Skipped folders first, so their photos are the originals that copies elsewhere point to.
files.sort { (isSkipped($0) ? 0 : 1, $0.url.path) < (isSkipped($1) ? 0 : 1, $1.url.path) }
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

let exifDate = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return f
}()

func imageInfo(_ url: URL) -> (date: Date?, width: Int, height: Int)? {
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
    let s =
        (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]) as? String
        ?? xmp ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
    return (s.flatMap(exifDate.date(from:)), w, h)
}

func movieInfo(_ url: URL) async -> (date: Date?, width: Int, height: Int)? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
        let size = try? await track.load(.naturalSize)
    else { return nil }
    let date = try? await asset.load(.creationDate)?.load(.dateValue)
    return (date, Int(abs(size.width)), Int(abs(size.height)))
}

// A Live Photo's video has its still's name; the library holds the two as one.
let imageStems = Set(files.filter(isImage).map(\.stem))

// Same size and capture time in another folder: a re-encoded copy (Amazon exports).
// In the same folder: frames from one second, so new; a skipped photo is lost, an extra
// import lands in Photos' Duplicates album.
var newShots = LibraryIndex()
var claimed: [String: Set<String>] = [:]  // library ids matched, per folder
var rows: [(status: String, file: File, detail: String)] = []
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
    if let d = info.date {
        let dir = f.url.deletingLastPathComponent().path
        if let id = index.match(date: d, width: info.width, height: info.height, excluding: claimed[dir] ?? []),
            claimed[dir, default: []].insert(id).inserted
        {
            row("in library", "\(dims)\t\(id)")
        } else if let orig = newShots.match(date: d, width: info.width, height: info.height),
            !orig.hasPrefix(String(dir.dropFirst(root.path.count + 1)) + "/")
        {
            row("same shot", "\(dims)\t\(orig)")
        } else {
            newShots.add(id: f.rel, date: d, width: info.width, height: info.height)
            row("new", dims)
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
    "in library", "in library by file date", "copy", "same shot", "live video", "new", "new undated", "unreadable",
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

// A Live Photo's video goes next to its still, where Photos pairs them.
if let stage {
    let movies = Dictionary(grouping: files.filter(isMovie), by: \.stem)
    var linked = 0
    for r in rows where r.status.hasPrefix("new") && r.file.rel.hasPrefix(only) {
        for f in [r.file] + (isImage(r.file) ? movies[r.file.stem] ?? [] : []) {
            let dest = stage.appending(path: f.rel.replacingOccurrences(of: "/Live Videos/", with: "/"))
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: f.url, to: dest)
            linked += 1
        }
    }
    log("staged: \(linked) files in \(stage.path)")
}
