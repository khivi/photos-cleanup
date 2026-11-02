import Foundation
import Synchronization

@testable import PhotosCleanupCore

/// An in-memory library: fixed photos and Vision results; records album adds.
final class FakeLibrary: PhotoLibrary {
    let all: [Photo]
    let analysis: [String: VisionResult?]
    let status: String
    let adds = Mutex<[(album: String, uuids: [String])]>([])
    let deletes = Mutex<[[String]]>([])
    /// Makes delete() act as if the user cancelled macOS's confirmation.
    let cancelsDelete = Mutex(false)
    let visionCalls = Mutex<[[String]]>([])
    /// Blocks vision() until released, to observe a job mid-run.
    let gate = Gate()

    init(_ photos: [Photo] = [], vision: [String: VisionResult?] = [:], status: String = "authorized") {
        all = photos
        analysis = vision
        self.status = status
    }

    func authorize() async -> String { status }
    func photos() throws -> [Photo] { all }

    func vision(_ uuids: [String]) -> [String: VisionResult?] {
        gate.wait()
        visionCalls.withLock { $0.append(uuids) }
        return Dictionary(uniqueKeysWithValues: uuids.map { ($0, analysis[$0] ?? nil) })
    }

    func add(album: String, uuids: [String]) throws -> Int {
        guard status == "authorized" else { throw LibraryError.accessDenied }
        adds.withLock { $0.append((album, uuids)) }
        return uuids.count
    }

    func delete(uuids: [String]) throws -> Int {
        guard status == "authorized" else { throw LibraryError.accessDenied }
        if cancelsDelete.withLock({ $0 }) { return 0 }
        deletes.withLock { $0.append(uuids) }
        return uuids.count
    }

    /// Per uuid: the modification date `exportable()` reports (0 if unset).
    let modified = Mutex<[String: Double]>([:])
    /// Per uuid: the original file name `exportName` reports (the uuid if unset).
    let names = Mutex<[String: String]>([:])
    /// uuids whose `export` throws.
    let exportFails = Mutex<Set<String>>([])
    let exported = Mutex<[String]>([])
    /// Exports running now, and the most at once.
    let inFlight = Mutex((now: 0, max: 0))

    func exportable() throws -> [ExportItem] {
        let m = modified.withLock { $0 }
        return all.map { ExportItem(uuid: $0.uuid, modified: m[$0.uuid] ?? 0, date: $0.date) }
    }

    func exportName(_ uuid: String) -> String? {
        all.contains { $0.uuid == uuid } ? names.withLock { $0[uuid] } ?? uuid : nil
    }

    /// Per uuid: the file names `fileNames` reports (`<uuid>.jpg` if unset).
    let files = Mutex<[String: Set<String>]>([:])
    /// Per uuid: the pixel size `importIndex` reports (4032x3024 if unset).
    let sizes = Mutex<[String: (Int, Int)]>([:])

    func importIndex() throws -> [LibraryShot] {
        let s = sizes.withLock { $0 }
        return all.compactMap { p in
            guard let d = p.date, Passes.waitingAlbum(in: p.albums) == nil else { return nil }
            let (w, h) = s[p.uuid] ?? (4032, 3024)
            return LibraryShot(id: p.uuid, date: d, width: w, height: h)
        }
    }

    func fileNames(_ uuid: String) -> Set<String> { files.withLock { $0[uuid] } ?? [uuid.lowercased() + ".jpg"] }
    func pictureKey(_ uuid: String) -> [UInt8]? { nil }

    /// Writes `<stem>.jpg` holding the uuid.
    func export(_ uuid: String, stem: String, to dest: URL) async throws {
        inFlight.withLock {
            $0.now += 1
            $0.max = max($0.max, $0.now)
        }
        defer { inFlight.withLock { $0.now -= 1 } }
        try await Task.sleep(for: .milliseconds(20))
        if exportFails.withLock({ $0.contains(uuid) }) { throw LibraryError.failed("offline") }
        let url = dest.appending(path: stem + ".jpg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(uuid.utf8).write(to: url)
        exported.withLock { $0.append(uuid) }
    }
}

/// A judge with fixed answers; nil means "couldn't judge".
final class FakeJudge: Judge {
    let answers: [String: Verdict]
    let off: String?
    let judged = Mutex<[String]>([])
    let gate = Gate()

    init(_ answers: [String: Verdict] = [:], off: String? = nil) {
        self.answers = answers
        self.off = off
    }

    func unavailableReason() -> String? { off }
    func judge(_ photo: Photo) async -> Verdict? {
        gate.wait()
        judged.withLock { $0.append(photo.uuid) }
        return answers[photo.uuid]
    }
}

/// Open by default; close() makes callers wait until open().
final class Gate: Sendable {
    let closed = Mutex(false)
    func close() { closed.withLock { $0 = true } }
    func open() { closed.withLock { $0 = false } }
    func wait() { while closed.withLock({ $0 }) { usleep(2000) } }
}

func vr(_ score: Double = 0.5, utility: Bool = false, _ vec: [Float] = [0]) -> VisionResult {
    VisionResult(print: vec, utility: utility, score: score)
}

let t0 = Date(timeIntervalSince1970: 1_704_067_200)  // 2024-01-01

func dated(_ secs: KeyValuePairs<String, Double>) -> [Photo] {
    secs.map { Photo(uuid: $0.key, date: t0.addingTimeInterval($0.value)) }
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A Cleanup over fakes with every photo a candidate (no albums to ignore beyond the defaults).
func makeCleanup(
    _ photos: [Photo], vision: [String: VisionResult?] = [:], verdicts: [String: Verdict] = [:],
    judge: FakeJudge = FakeJudge(), library: FakeLibrary? = nil, cacheDir: URL = tempDir(),
    keepAlbumPhotos: Bool = true
) async throws -> (Cleanup, FakeLibrary) {
    let lib = library ?? FakeLibrary(photos, vision: vision)
    if !vision.isEmpty {  // as if analysed in an earlier run
        let lines = vision.map { Cleanup.visionLine($0.key, $0.value) }.joined(separator: "\n") + "\n"
        try lines.write(to: cacheDir.appendingPathComponent(Cleanup.visionCache), atomically: true, encoding: .utf8)
    }
    if !verdicts.isEmpty {
        let lines = verdicts.map { Cleanup.verdictLine($0.key, $0.value) }.joined(separator: "\n") + "\n"
        try lines.write(to: cacheDir.appendingPathComponent(Cleanup.verdictCache), atomically: true, encoding: .utf8)
    }
    let c = Cleanup(
        library: lib, judge: judge, cacheDir: cacheDir, ignoreAlbums: loadIgnoreAlbums(dir: cacheDir),
        keepAlbumPhotos: keepAlbumPhotos, verdictsOff: judge.off)
    try await c.load()
    return (c, lib)
}

/// Waits until the Vision job and the classifier have nothing pending.
func settle(_ c: Cleanup) async {
    for _ in 0..<500 {
        let vision = await c.visionRunning
        let classifier = await c.classifierRunning
        let busy = vision || classifier
        if !busy { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
