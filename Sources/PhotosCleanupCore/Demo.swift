import Foundation
import ImageIO
import Synchronization

/// Where demo mode finds its fixtures: `--demo` among `arguments`, and `demo/manifest.json` under
/// `resources`. Release bundles carry no `demo` folder, so the flag does nothing there.
public func demoFixtures(arguments: [String] = CommandLine.arguments, resources: URL?) -> URL? {
    guard arguments.contains("--demo"), let dir = resources?.appending(path: "demo", directoryHint: .isDirectory),
        FileManager.default.fileExists(atPath: dir.appending(path: DemoLibrary.manifestName).path)
    else { return nil }
    return dir
}

/// A photo library read from a fixtures folder: `manifest.json` and the images it names.
/// Albums and deletes change memory only, so every launch starts from the manifest.
public final class DemoLibrary: PhotoLibrary {
    public static let manifestName = "manifest.json"

    struct Entry: Decodable {
        var uuid: String
        var file: String
        var date: Date?
        var width: Int
        var height: Int
        var screenshot = false
        var movie = false
        var duration: TimeInterval = 0
        var favorite = false
        var edited = false
        var live = false
        var albums: [String] = []
        var vision: Vision?
        var verdict: Verdict?

        struct Vision: Decodable {
            var print: [Float]
            var utility: Bool
            var score: Double
            var face: Double?
        }

        struct Verdict: Decodable {
            var keep: Bool
            var kind: String
            var reason: String
        }

        // Absent flags mean false; the manifest lists only what is set.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Key.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            file = try c.decode(String.self, forKey: .file)
            date = try c.decodeIfPresent(Date.self, forKey: .date)
            width = try c.decode(Int.self, forKey: .width)
            height = try c.decode(Int.self, forKey: .height)
            screenshot = try c.decodeIfPresent(Bool.self, forKey: .screenshot) ?? false
            movie = try c.decodeIfPresent(Bool.self, forKey: .movie) ?? false
            duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
            favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
            edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
            live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
            albums = try c.decodeIfPresent([String].self, forKey: .albums) ?? []
            vision = try c.decodeIfPresent(Vision.self, forKey: .vision)
            verdict = try c.decodeIfPresent(Verdict.self, forKey: .verdict)
        }

        enum Key: String, CodingKey {
            case uuid, file, date, width, height, screenshot, movie, duration, favorite, edited, live, albums, vision,
                verdict
        }
    }

    struct Manifest: Decodable { var photos: [Entry] }

    private struct State {
        var albums: [String: [String]]
        var deleted: Set<String> = []
    }

    private let directory: URL
    private let entries: [Entry]
    private let byUUID: [String: Entry]
    private let state: Mutex<State>

    public init(directory: URL) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = try decoder.decode(
            Manifest.self, from: Data(contentsOf: directory.appending(path: Self.manifestName))
        ).photos
        self.directory = directory
        byUUID = Dictionary(entries.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        state = Mutex(State(albums: Dictionary(entries.map { ($0.uuid, $0.albums) }, uniquingKeysWith: { a, _ in a })))
    }

    /// The image file for each photo, for the grid and the preview.
    public var imageURLs: [String: URL] {
        Dictionary(entries.map { ($0.uuid, directory.appending(path: $0.file)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The manifest's keep/delete call for the photo, if it has one.
    public func verdict(_ uuid: String) -> Verdict? {
        byUUID[uuid]?.verdict.map { Verdict(keep: $0.keep, kind: $0.kind, reason: $0.reason) }
    }

    private func live() -> [Entry] { state.withLock { s in entries.filter { !s.deleted.contains($0.uuid) } } }

    public func authorize() async -> String { "authorized" }

    public func photos() throws -> [Photo] {
        let albums = state.withLock { $0.albums }
        return live().map {
            Photo(
                uuid: $0.uuid, date: $0.date, screenshot: $0.screenshot, isMovie: $0.movie, duration: $0.duration,
                favorite: $0.favorite, edited: $0.edited, albums: albums[$0.uuid] ?? [], live: $0.live)
        }
    }

    public func vision(_ uuids: [String]) -> [String: VisionResult?] {
        Dictionary(
            uniqueKeysWithValues: uuids.map { id in
                (
                    id,
                    byUUID[id]?.vision.map {
                        VisionResult(print: $0.print, utility: $0.utility, score: $0.score, face: $0.face)
                    }
                )
            })
    }

    public func add(album: String, uuids: [String]) throws -> Int {
        state.withLock { s in
            let found = uuids.filter { byUUID[$0] != nil && !s.deleted.contains($0) }
            for id in found where !(s.albums[id] ?? []).contains(album) { s.albums[id, default: []].append(album) }
            return found.count
        }
    }

    public func delete(uuids: [String]) throws -> Int {
        state.withLock { s in
            let found = uuids.filter { byUUID[$0] != nil && !s.deleted.contains($0) }
            s.deleted.formUnion(found)
            return found.count
        }
    }

    public func exportable() throws -> [ExportItem] {
        live().map { ExportItem(uuid: $0.uuid, modified: $0.date?.timeIntervalSince1970 ?? 0, date: $0.date) }
    }

    public func exportName(_ uuid: String) -> String? {
        live().first { $0.uuid == uuid }.map { ($0.file as NSString).deletingPathExtension }
    }

    public func export(_ uuid: String, stem: String, to dest: URL) async throws {
        guard let e = byUUID[uuid] else { throw LibraryError.failed("no photo \(uuid)") }
        let url = dest.appending(path: stem + "." + (e.file as NSString).pathExtension)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: directory.appending(path: e.file), to: url)
    }

    public func importIndex() throws -> [LibraryShot] {
        live().compactMap { e in
            guard let d = e.date, Passes.waitingAlbum(in: state.withLock { $0.albums[e.uuid] ?? [] }) == nil
            else { return nil }
            return LibraryShot(id: e.uuid, date: d, width: e.width, height: e.height)
        }
    }

    public func fileNames(_ uuid: String) -> Set<String> { byUUID[uuid].map { [$0.file.lowercased()] } ?? [] }

    public func pictureKey(_ uuid: String) -> [UInt8]? {
        byUUID[uuid].flatMap {
            PhotosCleanupCore.pictureKey(CGImageSourceCreateWithURL(directory.appending(path: $0.file) as CFURL, nil))
        }
    }
}

/// Verdicts from the demo manifest: no Apple Intelligence needed.
public struct DemoJudge: Judge {
    let library: DemoLibrary

    public init(library: DemoLibrary) { self.library = library }

    public func unavailableReason() -> String? { nil }
    public func judge(_ photo: Photo) async -> Verdict? { library.verdict(photo.uuid) }
}
