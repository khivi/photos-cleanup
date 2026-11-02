import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Import sorts a folder of old photos against the library. It never writes to the library: it
// moves files within the folder, into Done/ (in the library, or a copy of a file that is) and
// Import/ (to drag into Photos), paths mirrored. A rerun moves what Import/ now has in the library
// to Done/, and what Done/ has that the library lacks back to Import/.
// Done/manifest.tsv: the library photo each Done/ file stands for. A file with a row is
// never matched again while that photo is in the library. A skipped folder (a library
// export) is never moved, and never new, nor are its photos' copies elsewhere: it still holds
// photos deleted from the library.

public enum ImportStatus: String, CaseIterable, Sendable {
    case inLibrary = "in library"
    case inLibraryByFileDate = "in library by file date"
    case inLibraryByName = "in library by name"
    case copy
    case sameShot = "same shot"
    case liveVideo = "live video"
    case new
    case newCheckDate = "new check date"
    case newUndated = "new undated"
    case unreadable
    case libraryCache = "library cache"
    case skipped
    case other
    /// In Done/ for a library photo since removed (merged or deleted): goes to Removed/, never back to Import/.
    case removed = "removed from library"

    public var isInLibrary: Bool { [.inLibrary, .inLibraryByFileDate, .inLibraryByName].contains(self) }
    public var isNew: Bool { [.new, .newCheckDate, .newUndated].contains(self) }
}

/// A library photo as Import matches it: pixel size and capture time.
public struct LibraryShot: Sendable, Equatable {
    public let id: String
    public let date: Date
    public let width: Int
    public let height: Int

    public init(id: String, date: Date, width: Int, height: Int) {
        (self.id, self.date, self.width, self.height) = (id, date, width, height)
    }
}

public struct ImportRow: Sendable, Equatable {
    public let status: ImportStatus
    /// The path under the folder.
    public let rel: String
    /// A library photo's uuid; for a copy or same shot, the original's `rel`.
    public let match: String?
    /// "4032x3024", or the file type for `other`.
    public let detail: String?
    /// Folder and name without extension, lowercased: a Live Photo's still and video share it.
    let stem: String
    let isImage: Bool
    let isMovie: Bool

    public var tsv: String { [status.rawValue, rel, detail ?? "", match ?? ""].joined(separator: "\t") }
}

public struct ImportMove: Sendable, Equatable {
    public let from: String
    public let to: String
}

/// One folder's check: every file's status, and the moves that sort it.
public struct ImportScan: Sendable {
    /// Beside Import/, not in it: dragging Import/ into Photos must not take files it would misdate.
    public static let checkDate = "Check date/"
    /// Waiting to be imported: Import/ and Check date/.
    static func isWaiting(_ rel: String) -> Bool { rel.hasPrefix("Import/") || rel.hasPrefix(checkDate) }
    /// Files whose photo was in the library and was removed from it; the scan never moves them again.
    static let removed = "Removed/"
    static let manifestPath = "Done/manifest.tsv"

    public let root: URL
    public let skip: [String]
    public let rows: [ImportRow]
    public let moves: [ImportMove]
    /// After the moves: each Done/ file matched to the library (path under Done/) and its photo's uuid.
    let manifest: [String: String]

    public init(root: URL, skip: [String], rows: [ImportRow]) {
        self.root = root
        self.skip = skip
        self.rows = rows
        moves = Self.plan(rows, skip: skip)
        manifest = Self.manifest(rows, moves: moves)
    }

    /// The library photo a row stands for: its own match, a copy's original's, or a Live Photo
    /// video's or sidecar's still's.
    static func libraryIDs(_ rows: [ImportRow]) -> [String: String] {
        let byRel = Dictionary(rows.map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        let stills = Dictionary(grouping: rows.filter(\.isImage), by: \.stem)
        var memo: [String: String?] = [:]
        func id(_ rel: String) -> String? {
            if let d = memo[rel] { return d }
            guard let r = byRel[rel] else { return nil }
            let d: String?
            switch r.status {
            case .inLibrary, .inLibraryByFileDate, .inLibraryByName: d = r.match
            case .copy, .sameShot: d = r.match.flatMap(id)
            // A Live Photo's video may exist only here: it needs its photo in the library, not just a copy.
            case .liveVideo, .other: d = stills[r.stem]?.lazy.filter { $0.rel != rel }.compactMap { id($0.rel) }.first
            default: d = nil
            }
            memo[rel] = d
            return d
        }
        return rows.reduce(into: [:]) { ids, r in ids[r.rel] = id(r.rel) }
    }

    /// Rows a match decided (not a video or sidecar, which follow their still), at their path after `moves`.
    static func manifest(_ rows: [ImportRow], moves: [ImportMove]) -> [String: String] {
        let ids = libraryIDs(rows)
        let to = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        func after(_ rel: String) -> String {
            if let t = to[rel] { return t }
            guard let r = rel.range(of: ".photoslibrary/"), let t = to[String(rel[..<r.lowerBound]) + ".photoslibrary"]
            else { return rel }
            return t + "/" + rel[r.upperBound...]
        }
        let matched: Set<ImportStatus> = [.inLibrary, .inLibraryByFileDate, .inLibraryByName, .copy, .sameShot]
        var m: [String: String] = [:]
        for r in rows where matched.contains(r.status) {
            let path = after(r.rel)
            if path.hasPrefix("Done/"), let id = ids[r.rel] { m[String(path.dropFirst("Done/".count))] = id }
        }
        return m
    }

    static func readManifest(_ root: URL) -> [String: String] {
        guard let text = try? String(contentsOf: root.appending(path: manifestPath), encoding: .utf8) else {
            return [:]
        }
        return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { m, line in
            let c = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if c.count == 2 { m["Done/" + c[0]] = c[1] }
        }
    }

    public func count(_ s: ImportStatus) -> Int { rows.count { $0.status == s } }
    public var toDone: Int { moves.count { $0.to.hasPrefix("Done/") } }
    public var toImport: Int { moves.count { Self.isWaiting($0.to) } }
    public var toRemoved: Int { moves.count { $0.to.hasPrefix(Self.removed) } }
    /// Moves from Done/ back to Import/: files no match ever recorded as imported.
    public var fromDone: Int { moves.count { $0.from.hasPrefix("Done/") && Self.isWaiting($0.to) } }

    static func isSkipped(_ rel: String, _ skip: [String]) -> Bool { skip.contains { rel.hasPrefix($0 + "/") } }

    /// Done: in the library, or a copy of a file that is; a Photos library package only whole.
    /// Not done: a photo or video Photos can read goes to Import/, its sidecar with it; the rest stays.
    static func plan(_ rows: [ImportRow], skip: [String]) -> [ImportMove] {
        let byRel = Dictionary(rows.map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        let byStem = Dictionary(grouping: rows.filter { $0.isImage || $0.isMovie }, by: \.stem)
        // A sidecar goes with its photo or video; Apple names an edit's original-adjustments `<name>O.aae`.
        func media(_ r: ImportRow) -> [ImportRow]? {
            guard r.status == .other else { return nil }
            return byStem[r.stem] ?? (r.stem.hasSuffix("o") ? byStem[String(r.stem.dropLast())] : nil)
        }
        let ids = libraryIDs(rows)
        func inLibrary(_ rel: String) -> Bool { ids[rel] != nil }
        // A copy is done once its original is in the library; until then it stays put, so Done/
        // never holds the only copy of a photo to import.
        func done(_ rel: String) -> Bool {
            guard let r = byRel[rel], !isSkipped(rel, skip) else { return false }
            if let m = media(r) { return m.contains { $0.rel != rel && done($0.rel) } }
            return r.status == .libraryCache || inLibrary(rel)
        }
        func toImport(_ rel: String) -> Bool {
            guard let r = byRel[rel], !isSkipped(rel, skip) else { return false }
            if let m = media(r) { return m.contains { $0.rel != rel && toImport($0.rel) } }
            return r.status.isNew || r.status == .liveVideo
        }
        func unit(_ rel: String) -> String {
            guard let r = rel.range(of: ".photoslibrary/") else { return rel }
            return String(rel[..<r.lowerBound]) + ".photoslibrary"
        }
        // A photo whose date Photos would get wrong goes to Check date/, its video and sidecar with it.
        let checkStems = Set(rows.filter { $0.status == .newCheckDate || $0.status == .newUndated }.map(\.stem))
        func needsCheck(_ r: ImportRow) -> Bool {
            checkStems.contains(r.stem) || (r.stem.hasSuffix("o") && checkStems.contains(String(r.stem.dropLast())))
        }
        // A removed photo's video, sidecar and copies go with it.
        let removedStems = Set(rows.filter { $0.status == .removed }.map(\.stem))
        func wasRemoved(_ r: ImportRow) -> Bool {
            guard r.rel.hasPrefix("Done/") else { return false }
            if r.status == .copy || r.status == .sameShot { return r.match.flatMap { byRel[$0] }?.status == .removed }
            return removedStems.contains(r.stem)
                || (r.stem.hasSuffix("o") && removedStems.contains(String(r.stem.dropLast())))
        }
        var unitDone: [String: Bool] = [:]
        for r in rows { unitDone[unit(r.rel), default: true] = unitDone[unit(r.rel), default: true] && done(r.rel) }

        var moves: [ImportMove] = []
        for (u, d) in unitDone.sorted(by: { $0.key < $1.key }) {
            guard let r = byRel[u] ?? rows.first(where: { unit($0.rel) == u }), !isSkipped(r.rel, skip),
                !u.hasPrefix(removed)
            else { continue }
            let inImport = isWaiting(u)
            let inDone = u.hasPrefix("Done/")
            let prefix =
                u.hasPrefix(checkDate) ? checkDate.count : inImport ? "Import/".count : inDone ? "Done/".count : 0
            let rel = String(u.dropFirst(prefix))
            if d {
                if !inDone { moves.append(ImportMove(from: u, to: "Done/" + rel)) }
            } else if u == r.rel, wasRemoved(r) {
                moves.append(ImportMove(from: u, to: removed + rel))
            } else if !inImport, u == r.rel, toImport(u) {
                // From Done/ too: a photo there is not in the library (deleted since, or sorted by an
                // older matcher), and its copies elsewhere wait on it.
                // A Live Photo's video goes next to its still, where Photos pairs them.
                let dest = needsCheck(r) ? checkDate : "Import/"
                moves.append(ImportMove(from: u, to: dest + rel.replacingOccurrences(of: "/Live Videos/", with: "/")))
            }
        }
        return moves
    }

    /// Makes the moves, then drops folders they emptied; Done/, Import/, Check date/, Removed/ and skipped
    /// folders stay.
    /// Rewrites Done/manifest.tsv for what Done/ now holds. Returns the moves that failed, with why.
    public func apply() -> [String: String] {
        let fm = FileManager.default
        var failed: [String: String] = [:]
        for m in moves {
            let dest = root.appending(path: m.to)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: root.appending(path: m.from), to: dest)
            } catch {
                failed[m.from] = error.localizedDescription
            }
        }
        // A failed move leaves a row for a missing path; the next scan drops it.
        let tsv = manifest.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)\n" }.joined()
        let url = root.appending(path: Self.manifestPath)
        if !manifest.isEmpty || fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try tsv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                failed[Self.manifestPath] = error.localizedDescription
            }
        }
        let dirs = (fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { String($0.path.dropFirst(root.path.count + 1)) }
            .filter { d in
                !["Done", "Import", String(Self.checkDate.dropLast()), String(Self.removed.dropLast())].contains(d)
                    && !skip.contains { d == $0 || d.hasPrefix($0 + "/") }
            }
            .filter { !$0.contains(".photoslibrary") }
        for d in dirs.sorted(by: { $0.count > $1.count }) {
            let url = root.appending(path: d)
            guard let entries = try? fm.contentsOfDirectory(atPath: url.path), entries.allSatisfy({ $0 == ".DS_Store" })
            else { continue }
            try? fm.removeItem(at: url)
        }
        return failed
    }
}

/// Checks folders against the library. One check at a time; `done` of `total` files while it runs.
public actor Importer {
    let library: PhotoLibrary
    public private(set) var done = 0
    public private(set) var total = 0

    /// Per check: the library's file names per photo, and each file's picture key.
    var namesMemo: [String: Set<String>] = [:]
    var thumbs: [URL: [UInt8]?] = [:]

    public init(library: PhotoLibrary) { self.library = library }

    func names(_ id: String) -> Set<String> {
        if let n = namesMemo[id] { return n }
        let n = library.fileNames(id)
        namesMemo[id] = n
        return n
    }

    func fileThumb(_ url: URL) -> [UInt8]? {
        if let t = thumbs[url] { return t }
        let t = pictureKey(CGImageSourceCreateWithURL(url as CFURL, nil))
        thumbs[url] = t
        return t
    }

    struct File {
        let url: URL
        let rel: String
        let size: Int
        let type: UTType?
        let fileDate: Date?
        var isImage: Bool { type?.conforms(to: .image) == true }
        var isMovie: Bool { type?.conforms(to: .movie) == true }
        /// A backup may keep Live Photo videos in a `Live Videos` subfolder.
        var stem: String {
            let dir = url.deletingLastPathComponent()
            let base = dir.lastPathComponent == "Live Videos" ? dir.deletingLastPathComponent() : dir
            return base.appending(path: url.deletingPathExtension().lastPathComponent).path.lowercased()
        }
    }

    public func scan(_ folder: URL, skip: [String] = []) async throws -> ImportScan {
        // realpath, not resolvingSymlinksInPath: the enumerator's paths keep /private (/tmp is /private/tmp).
        guard let real = realpath(folder.path, nil) else { throw LibraryError.failed("\(folder.path): no such folder") }
        let root = URL(filePath: String(cString: real))
        free(real)
        let lib = library
        let shots = try await offload { try lib.importIndex() }
        let index = LibraryIndex(shots.map { ($0.id, $0.date, $0.width, $0.height) })
        let bySize = Dictionary(grouping: shots) { [max($0.width, $0.height), min($0.width, $0.height)] }
        let bySecond = Dictionary(grouping: shots) { LibraryIndex.seconds($0.date) }
        // A recorded decision holds while its photo is in the library (importIndex leaves out Delete Me).
        let present = Set(shots.map(\.id))
        let recorded = ImportScan.readManifest(root)
        let sticky = recorded.filter { present.contains($0.value) }

        (namesMemo, thumbs) = ([:], [:])

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentTypeKey, .creationDateKey]
        var files: [File] = []
        let all = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        for case let url as URL in all?.allObjects ?? [] {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if rel == ImportScan.manifestPath { continue }
            files.append(
                File(
                    url: url, rel: rel, size: v.fileSize ?? 0,
                    type: v.contentType, fileDate: v.creationDate))
        }
        // For copies: skipped folders, then Removed/, Import/ and Check date/, then Done/ first, so their
        // photos are the originals that copies elsewhere point to: a rerun never sends a second copy to
        // Import/, and a removed photo's copy left in Done/ follows it.
        func order(_ f: File) -> Int {
            if ImportScan.isSkipped(f.rel, skip) { return 0 }
            if f.rel.hasPrefix(ImportScan.removed) { return 1 }
            return ImportScan.isWaiting(f.rel) ? 2 : f.rel.hasPrefix("Done/") ? 3 : 4
        }
        files.sort { (order($0), $0.url.path) < (order($1), $1.url.path) }
        (done, total) = (0, files.count)

        var copyOf: [String: String] = [:]
        for group in Dictionary(grouping: files.filter { $0.isImage || $0.isMovie }, by: \.size).values
        where group.count > 1 {
            var first: [Data: String] = [:]
            for f in group {
                guard let h = sha256(f.url) else { continue }
                if let orig = first[h] { copyOf[f.rel] = orig } else { first[h] = f.rel }
            }
        }

        // A Live Photo's video has its still's name; the library holds the two as one.
        let imageStems = Set(files.filter(\.isImage).map(\.stem))
        // Same size and capture time in another folder: a re-encoded copy (Amazon exports).
        // In the same folder: frames from one second, so new; a skipped photo is lost, an extra
        // import lands in Photos' Duplicates album.
        var newShots = LibraryIndex()
        // Per folder, with Done/, Import/ and Check date/ seen as the folder they mirror, so a
        // file's match doesn't change when it moves.
        func mirrored(_ rel: String) -> String {
            let dir = (rel as NSString).deletingLastPathComponent + "/"
            for p in [ImportScan.checkDate, "Import/", "Done/"] where dir.hasPrefix(p) {
                return String(dir.dropFirst(p.count))
            }
            return dir
        }
        var claimed: [String: Set<String>] = [:]  // library ids matched
        // Recorded first, so no sibling takes a photo a Done/ file already stands for.
        let onDisk = Set(files.map(\.rel))
        for (rel, id) in sticky where onDisk.contains(rel) { claimed[mirrored(rel), default: []].insert(id) }
        let siblings = Dictionary(grouping: files.filter { !$0.rel.hasPrefix(ImportScan.removed) }) { mirrored($0.rel) }
            .mapValues {
                Set($0.map { $0.url.lastPathComponent.lowercased() })
            }
        func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }
        /// Whether library photo `id` is this file's rather than a sibling's in its folder (burst frames of
        /// one second, or `IMG_1.JPG` and its rotated `IMG_1.jpeg`, match the same photo). Decided by
        /// names, never by which file comes first, so the answer doesn't change when a file moves.
        func owns(_ f: File, _ id: String) -> Bool {
            let full = f.url.lastPathComponent.lowercased()
            let n = names(id)
            let others = (siblings[mirrored(f.rel)] ?? []).subtracting([full])
            if n.contains(full) { return true }
            if !n.isDisjoint(with: others) { return false }
            let stems = Set(n.map(stem))
            guard stems.contains(stem(full)) else { return others.allSatisfy { !stems.contains(stem($0)) } }
            return others.allSatisfy { !stems.contains(stem($0)) || full < $0 }
        }
        // Matching runs in mirrored order, skipped folders first: where two files tie for one library
        // photo (burst frames of one second, renamed exports), the first wins, and that must not depend
        // on whether a file sits in Done/ or Import/, or each run would swap them.
        files.sort {
            let a = (ImportScan.isSkipped($0.rel, skip) ? 0 : 1, mirrored($0.rel) + $0.url.lastPathComponent, $0.rel)
            let b = (ImportScan.isSkipped($1.rel, skip) ? 0 : 1, mirrored($1.rel) + $1.url.lastPathComponent, $1.rel)
            return a < b
        }
        var rows: [ImportRow] = []
        for (n, f) in files.enumerated() {
            done = n
            if n % 200 == 0 { await Task.yield() }  // lets `done` be read while a check runs
            let row = { (status: ImportStatus, match: String?, detail: String?) in
                rows.append(
                    ImportRow(
                        status: status, rel: f.rel, match: match, detail: detail, stem: f.stem, isImage: f.isImage,
                        isMovie: f.isMovie))
            }
            if let id = sticky[f.rel] {
                row(.inLibrary, id, "manifest")
                continue
            }
            if f.rel.hasPrefix(ImportScan.removed) || recorded[f.rel] != nil {
                // Its re-encodes elsewhere are same shots of it.
                if f.isImage, let info = imageInfo(f.url), let d = info.date {
                    newShots.add(id: f.rel, date: d, width: info.width, height: info.height)
                }
                row(.removed, recorded[f.rel], nil)
                continue
            }
            // Inside a Photos library package only originals/ holds photos; resources/ is its previews and renders.
            if f.rel.contains(".photoslibrary/") && !f.rel.contains(".photoslibrary/originals/") {
                row(.libraryCache, nil, nil)
                continue
            }
            if !f.isImage && !f.isMovie {
                row(.other, nil, f.type?.identifier ?? f.url.pathExtension)
                continue
            }
            if let orig = copyOf[f.rel] {
                row(.copy, orig, nil)
                continue
            }
            if ImportScan.isSkipped(f.rel, skip) {
                if let info = f.isImage ? imageInfo(f.url) : await movieInfo(f.url), let d = info.date {
                    newShots.add(id: f.rel, date: d, width: info.width, height: info.height)
                }
                row(.skipped, nil, nil)
                continue
            }
            if f.isMovie && imageStems.contains(f.stem) {
                row(.liveVideo, nil, nil)
                continue
            }
            guard let info = f.isImage ? imageInfo(f.url) : await movieInfo(f.url) else {
                row(.unreadable, nil, nil)
                continue
            }
            let dims = "\(info.width)x\(info.height)"
            let name = f.url.deletingPathExtension().lastPathComponent.lowercased()
            let stemmed = { (id: String) in self.names(id).map(stem) }
            // QuickTime's zero date is 1904; a reset camera writes 1900.
            let dated = info.date.map {
                info.trusted && Calendar.current.component(.year, from: $0) > 1904 && $0 < Date()
            }
            // A Check date photo's date was fixed by hand in Photos after import, so only name and size
            // still match. By its date, not its folder, so the answer holds once it moves to Done/.
            let byName =
                dated != true
                ? bySize[[max(info.width, info.height), min(info.width, info.height)]]?.filter {
                    stemmed($0.id).contains(name)
                }
                : nil
            if let byName, byName.count == 1 {
                row(.inLibraryByName, byName[0].id, dims)
            } else if let d = info.date {
                let dir = f.url.deletingLastPathComponent().path
                let confirm = { (id: String) in
                    stemmed(id).contains(name) || (f.isImage && samePicture(lib.pictureKey(id), self.fileThumb(f.url)))
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
                // Already claimed here, at the exact time, by no sibling's name, and the same picture:
                // another re-encode of that photo (an export may hold one photo nine times).
                if found == nil, f.isImage,
                    let id = index.match(date: d, width: info.width, height: info.height),
                    owns(f, id), samePicture(lib.pictureKey(id), fileThumb(f.url))
                {
                    found = id
                }
                // Photos' Merge Duplicates keeps the largest version: a smaller one at the exact time,
                // same shape and same picture is that photo.
                if found == nil, f.isImage {
                    let ratio = Double(max(info.width, info.height)) / Double(min(info.width, info.height))
                    found =
                        bySecond[LibraryIndex.seconds(d)]?.first { c in
                            let r = Double(max(c.width, c.height)) / Double(min(c.width, c.height))
                            return abs(r - ratio) < 0.01 * ratio && owns(f, c.id)
                                && samePicture(lib.pictureKey(c.id), fileThumb(f.url))
                        }?.id
                }
                if let id = found {
                    claimed[here, default: []].insert(id)
                    row(.inLibrary, id, dims)
                } else if let orig = newShots.match(
                    date: d, width: info.width, height: info.height,
                    confirm: { f.isImage && samePicture(fileThumb(root.appending(path: $0)), fileThumb(f.url)) }),
                    !orig.hasPrefix(String(dir.dropFirst(root.path.count + 1)) + "/")
                {
                    row(.sameShot, orig, dims)
                } else {
                    newShots.add(id: f.rel, date: d, width: info.width, height: info.height)
                    row(dated == true ? .new : .newCheckDate, nil, dims)
                }
            } else if let d = f.fileDate,
                // Photos sometimes dates an undated file a second before its file date.
                let id = [d, d - 1].lazy.compactMap({ index.match(date: $0, width: info.width, height: info.height) })
                    .first
            {
                row(.inLibraryByFileDate, id, dims)
            } else {
                row(.newUndated, nil, dims)
            }
        }
        done = files.count
        return ImportScan(root: root, skip: skip, rows: rows)
    }
}

func sha256(_ url: URL) -> Data? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize())
}

/// 16×16 grayscale; under 8 mean levels apart is the same picture (a re-encode or a resize), and
/// in one folder's offset matches no other photo came within 25.
func pictureKey(_ src: CGImageSource?) -> [UInt8]? {
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

// Photos reads an EXIF time without OffsetTimeOriginal in the Mac's time zone, as here; with GPS it
// may place the photo in the zone where it was taken, which LibraryIndex's offsets cover.
func exifFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
}

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
        let d = exifFormatter("yyyy:MM:dd HH:mm:ssxxx").date(from: camera + offset)
    {
        return (d, true, w, h)
    }
    let exifDate = exifFormatter("yyyy:MM:dd HH:mm:ss")
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

/// `import_folders`: the folders Import checks, one path per line.
public func loadImportFolders(dir: URL = settingsDir) -> [URL] {
    guard let text = try? String(contentsOf: dir.appendingPathComponent("import_folders"), encoding: .utf8) else {
        return []
    }
    return text.split(whereSeparator: \.isNewline).map { URL(filePath: String($0)) }
}

public func saveImportFolders(_ folders: [URL], dir: URL = settingsDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try folders.map { $0.path + "\n" }.joined()
        .write(to: dir.appendingPathComponent("import_folders"), atomically: true, encoding: .utf8)
}

/// Photos keyed by pixel size and capture time. Size ignores orientation: EXIF sizes are
/// unrotated, PhotoKit's are rotated.
public struct LibraryIndex {
    struct Key: Hashable { let long: Int, short: Int, second: Int }
    var byKey: [Key: [(seconds: Int, id: String)]] = [:]

    public init(_ photos: [(id: String, date: Date, width: Int, height: Int)] = []) {
        for p in photos { add(id: p.id, date: p.date, width: p.width, height: p.height) }
    }

    public mutating func add(id: String, date: Date, width: Int, height: Int) {
        let s = Self.seconds(date)
        byKey[Self.key(s, width, height), default: []].append((s, id))
    }

    /// The same time wins. Without one, Photos may have placed the photo in the zone where it was
    /// taken, a whole quarter-hour offset up to 14 hours: nearest first, and only if `confirm`
    /// (same name or same picture) agrees. A busy day of one camera has a photo at the same second
    /// of many offsets: unconfirmed, 55 of 124 offset matches in one folder were other photos.
    /// `excluding`: photos already matched, e.g. by an earlier frame of the same second.
    public func match(
        date: Date, width: Int, height: Int, excluding: Set<String> = [], confirm: (String) -> Bool = { _ in false }
    ) -> String? {
        let s = Self.seconds(date)
        let candidates = (byKey[Self.key(s, width, height)] ?? []).filter { !excluding.contains($0.id) }
        if let exact = candidates.first(where: { $0.seconds == s }) { return exact.id }
        return candidates.filter { abs(s - $0.seconds) <= 14 * 3600 && (s - $0.seconds) % 900 == 0 }
            .sorted { abs(s - $0.seconds) < abs(s - $1.seconds) }
            .first { confirm($0.id) }?.id
    }

    static func seconds(_ d: Date) -> Int { Int(d.timeIntervalSince1970.rounded(.down)) }

    static func key(_ seconds: Int, _ w: Int, _ h: Int) -> Key {
        Key(long: max(w, h), short: min(w, h), second: ((seconds % 60) + 60) % 60)
    }
}
