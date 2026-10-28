import Foundation

/// What a pass shows: its photos (or, for bursts, groups with the best shot) and progress.
public struct PassResult: Sendable {
    public var photos: [(photo: Photo, verdict: Verdict?)] = []
    public var groups: [(photos: [Photo], best: String)] = []
    public var progress = JobProgress()
}

public enum CleanupError: Error, Equatable {
    case unknownPass
    case noMatchingPhotos
    case accessDenied
    case failed(String)
}

/// The app's state and background work: the photo list, the Vision analysis, the verdict
/// queue, commits and the on-disk caches. Pure Swift; the HTTP layer is a thin shell over it.
public actor Cleanup {
    let library: any PhotoLibrary
    let judge: any Judge
    let cacheDir: URL
    let ignoreAlbums: Set<String>
    /// Set at startup when verdicts can't run here; shown in the UI instead of verdicts.
    public let verdictsOff: String?

    // Cache names keep the hashes the Python version derived from its helpers' sources, so
    // existing caches carry over. Change a name to recompute: vision when image sizes or
    // requests change, verdicts when the prompt or kinds change.
    static let visionCache = "vision-38db2b8a.jsonl"
    static let verdictCache = "verdicts-66bf2472.jsonl"
    static let decisionsLog = "decisions.jsonl"

    public private(set) var photos: [Photo] = []  // newest first
    var byUUID: [String: Photo] = [:]
    /// The photo list is read once and never sees album changes, so commits are tracked here.
    var committed: Set<String> = []

    var vision: [String: VisionResult?] = [:]  // nil: no local image
    var visionQueue: [String] = []
    var visionProgress = JobProgress()
    var visionRunning = false

    var verdicts: [String: Verdict] = [:]
    var verdictQueue: [Photo] = []
    var inflight: Set<String> = []  // queued or being judged; "pending" is its size
    /// Photos the model couldn't judge (e.g. its safety guardrails refused); retried after a
    /// restart, not on every poll, or the progress bar never finishes.
    var unjudgeable: Set<String> = []
    var classify = JobProgress()
    var classifierRunning = false

    public init(
        library: any PhotoLibrary, judge: any Judge, cacheDir: URL, ignoreAlbums: Set<String>,
        verdictsOff: String? = nil
    ) {
        self.library = library
        self.judge = judge
        self.cacheDir = cacheDir
        self.ignoreAlbums = ignoreAlbums
        self.verdictsOff = verdictsOff
        vision = Self.readVision(cacheDir.appendingPathComponent(Self.visionCache))
        verdicts = Self.readVerdicts(cacheDir.appendingPathComponent(Self.verdictCache))
    }

    /// Reads the photo list. Call once at startup.
    public func load() async throws {
        let library = library
        let all = try await offload { try library.photos() }
        photos = all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        byUUID = Dictionary(photos.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func photo(_ uuid: String) -> Photo? { byUUID[uuid] }

    // MARK: Passes

    /// A pass's photos, before any model judgement, minus those already filed.
    func candidates(_ kind: String) throws -> [Photo] {
        let found: [Photo]
        switch kind {
        case "screenshots": found = candidatePhotos(photos, ignoring: ignoreAlbums, onlyScreenshots: true)
        case "utility", "low-quality": found = candidatePhotos(photos, ignoring: ignoreAlbums)
        case "bursts": found = candidatePhotos(photos, ignoring: ignoreAlbums, requireValidDate: true)
        default: throw CleanupError.unknownPass
        }
        let filed = Set([Passes.deleteAlbum(kind)!, Passes.keepAlbum(kind)!])
            .union(Passes.legacyAlbums[kind] ?? [])
        return found.filter { !committed.contains($0.uuid) && filed.isDisjoint(with: $0.albums) }
    }

    /// Narrow Utility and Low Quality by the Vision analysis done so far, and its progress.
    func analysed(_ kind: String, _ photos: [Photo], threshold: Double) -> ([Photo], JobProgress) {
        let progress = startVision(photos)
        let narrowed: [Photo]
        switch kind {
        case "utility": narrowed = photos.filter { (vision[$0.uuid] ?? nil)?.utility == true }
        case "low-quality":
            narrowed = photos.filter { ((vision[$0.uuid] ?? nil)?.score).map { $0 <= threshold } ?? false }
        default: narrowed = photos
        }
        return (narrowed, progress)
    }

    func bursts(_ photos: [Photo]) -> [[Photo]] {
        let dated = photos.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return groupByTime(dated, window: Passes.burstWindow, minSize: 2).flatMap { splitSimilar($0, vision: vision) }
    }

    func score(_ p: Photo) -> Double { (vision[p.uuid] ?? nil)?.score ?? -2 }  // unanalysed sort last

    public func pass(_ kind: String, threshold: Double = Passes.lowQualityMax) throws -> PassResult {
        var photos = try candidates(kind)
        var result = PassResult()
        if kind != "screenshots" { (photos, result.progress) = analysed(kind, photos, threshold: threshold) }
        if kind == "bursts" {
            result.groups = bursts(photos).reversed().map { g in  // newest group first
                // First max wins ties: the earliest shot.
                (g, g.reduce(g[0]) { score($1) > score($0) ? $1 : $0 }.uuid)
            }
            return result
        }
        if Passes.verdictKinds.contains(kind) {
            startClassifier(photos)
            if result.progress.pending == 0 { result.progress = classify }  // Vision first, then the model
        }
        if kind == "utility" {
            // Unjudged photos appear once classified; "picture" means the model's own Vision
            // check said it isn't a utility image after all.
            photos = photos.filter { (verdicts[$0.uuid]?.kind ?? "picture") != "picture" }
        }
        result.photos = photos.map { ($0, Passes.verdictKinds.contains(kind) ? passVerdict(kind, verdicts[$0.uuid]) : nil) }
        return result
    }

    /// Photos per pass, or nil where knowing it needs work not done yet.
    public func counts() -> [String: Int?] {
        var out: [String: Int?] = ["all": photos.count]
        for (kind, _) in Passes.all {
            guard let found = try? candidates(kind) else { continue }
            if kind == "screenshots" {
                out[kind] = found.count
                continue
            }
            let done = found.allSatisfy { vision.keys.contains($0.uuid) }
            let (narrowed, _) = analysed(kind, found, threshold: Passes.lowQualityMax)
            if !done {
                out[kind] = .some(nil)  // the background Vision analysis is still running
            } else if kind == "utility" {
                let judged = narrowed.compactMap { verdicts[$0.uuid] }
                out[kind] = judged.count == narrowed.count ? judged.filter { $0.kind != "picture" }.count : nil
            } else if kind == "bursts" {
                out[kind] = bursts(narrowed).reduce(0) { $0 + $1.count }
            } else {
                out[kind] = narrowed.count
            }
        }
        return out
    }

    // MARK: Vision analysis

    /// Queue photos not yet analysed; returns the analysis progress.
    @discardableResult
    public func startVision(_ photos: [Photo]) -> JobProgress {
        let queued = Set(visionQueue)
        let todo = photos.map(\.uuid).filter { !vision.keys.contains($0) && !queued.contains($0) }
        if !todo.isEmpty {
            let total = todo.count + (visionQueue.isEmpty ? 0 : visionProgress.total)
            visionQueue += todo
            visionProgress = JobProgress(pending: visionQueue.count, total: total)
            if !visionRunning {
                visionRunning = true
                Task.detached { await self.drainVision() }
            }
        }
        return visionProgress
    }

    func drainVision() async {
        let library = library
        // Batches stay queued until saved, so a request meanwhile doesn't queue them again.
        while let batch = nextVisionBatch() {
            guard let results = try? await offload({ library.vision(batch) }) else { return finishVision() }
            record(results, count: batch.count)
        }
    }

    func nextVisionBatch() -> [String]? {
        guard !visionQueue.isEmpty else {
            visionRunning = false
            return nil
        }
        return Array(visionQueue.prefix(20))
    }

    func finishVision() {
        visionQueue.removeAll()
        visionProgress = JobProgress(error: "Vision analysis failed")
        visionRunning = false
    }

    func record(_ results: [String: VisionResult?], count: Int) {
        appendLines(Self.visionCache, results.map { Self.visionLine($0.key, $0.value) })
        vision.merge(results) { $1 }
        visionQueue.removeFirst(min(count, visionQueue.count))
        visionProgress.pending = visionQueue.count
    }

    // MARK: Verdicts

    /// Queue unjudged photos; one task judges them in order, whichever pass asked.
    func startClassifier(_ photos: [Photo]) {
        if let verdictsOff {
            classify = JobProgress(error: verdictsOff)
            return
        }
        let todo = photos.filter {
            verdicts[$0.uuid] == nil && !inflight.contains($0.uuid) && !unjudgeable.contains($0.uuid)
        }
        guard !todo.isEmpty else { return }
        let total = todo.count + (inflight.isEmpty ? 0 : classify.total)
        verdictQueue += todo
        inflight.formUnion(todo.map(\.uuid))
        classify = JobProgress(pending: inflight.count, total: total)
        if !classifierRunning {
            classifierRunning = true
            Task.detached { await self.drainClassifier() }
        }
    }

    func drainClassifier() async {
        let judge = judge
        while let photo = nextToJudge() {
            let verdict = await judge.judge(photo)
            recordVerdict(photo.uuid, verdict)
        }
    }

    func nextToJudge() -> Photo? {
        guard !verdictQueue.isEmpty else {
            classifierRunning = false
            return nil
        }
        return verdictQueue.removeFirst()
    }

    func recordVerdict(_ uuid: String, _ verdict: Verdict?) {
        if let verdict {
            verdicts[uuid] = verdict
            appendLines(Self.verdictCache, [Self.verdictLine(uuid, verdict)])
        } else {
            unjudgeable.insert(uuid)
        }
        inflight.remove(uuid)
        classify.pending = inflight.count
    }

    // MARK: Commit

    public struct Committed: Sendable, Equatable {
        public var added: Int
        public var album: String
        public var kept: Int
        public var keepAlbum: String
    }

    /// File photos into the pass's Delete Me (`delete`) and Keep (`keep`) albums. Never deletes.
    public func commit(_ kind: String, delete: [String], keep: [String]) async throws -> Committed {
        guard let album = Passes.deleteAlbum(kind), let keepAlbum = Passes.keepAlbum(kind) else {
            throw CleanupError.unknownPass
        }
        let doomed = delete.filter { byUUID[$0] != nil }
        let kept = keep.filter { byUUID[$0] != nil }
        guard !doomed.isEmpty || !kept.isEmpty else { throw CleanupError.noMatchingPhotos }
        let library = library
        for (uuids, name) in [(doomed, album), (kept, keepAlbum)] where !uuids.isEmpty {
            do {
                _ = try await offload { try library.add(album: name, uuids: uuids) }
            } catch LibraryError.accessDenied {
                throw CleanupError.accessDenied
            } catch {
                throw CleanupError.failed("\(error)")
            }
        }
        committed.formUnion(doomed + kept)
        if Passes.verdictKinds.contains(kind) {
            logDecisions(kind, doomed.map { ($0, "delete") } + kept.map { ($0, "keep") })
        }
        return Committed(added: doomed.count, album: album, kept: kept.count, keepAlbum: keepAlbum)
    }

    /// One line per committed photo that has a verdict, to measure the model's accuracy.
    func logDecisions(_ kind: String, _ decided: [(String, String)]) {
        let now = ISO8601DateFormatter().string(from: .now)
        appendLines(Self.decisionsLog, decided.compactMap { uuid, decision in
            passVerdict(kind, verdicts[uuid]).map { v in
                jsonLine(["uuid": uuid, "kind": kind, "verdict_kind": v.kind, "verdict_keep": v.keep,
                          "decision": decision, "ts": now])
            }
        })
    }

    /// Per pass: how many committed photos matched the model's verdict.
    public func verdictStats() -> [String: (agree: Int, total: Int)] {
        var out: [String: (agree: Int, total: Int)] = [:]
        for row in readJSONLines(cacheDir.appendingPathComponent(Self.decisionsLog)) {
            guard let kind = row["kind"] as? String, let keep = row["verdict_keep"] as? Bool,
                let decision = row["decision"] as? String
            else { continue }
            var s = out[kind] ?? (0, 0)
            s.total += 1
            s.agree += keep == (decision == "keep") ? 1 : 0
            out[kind] = s
        }
        return out
    }

    // MARK: Thumbnails

    /// A 340px JPEG (the 170px grid cell on a 2x display), made once and cached on disk.
    public func thumbnail(_ uuid: String) async -> URL? {
        guard byUUID[uuid] != nil else { return nil }  // only known ids reach the file path
        let dir = cacheDir.appendingPathComponent("thumbs")
        let file = dir.appendingPathComponent("\(uuid).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let library = library
        guard let jpeg = try? await offload({ library.jpeg(uuid, maxSide: 340) }) ?? nil else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? jpeg.write(to: file)) != nil ? file : nil
    }

    // MARK: Cache files (JSON lines)

    func appendLines(_ name: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent(name)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static func visionLine(_ uuid: String, _ v: VisionResult?) -> String {
        guard let v else { return jsonLine(["uuid": uuid, "error": "no local image"]) }
        let data = v.print.withUnsafeBufferPointer { Data(buffer: $0) }
        return jsonLine(["uuid": uuid, "print": data.base64EncodedString(), "ptype": 1,
                         "utility": v.utility, "score": v.score])
    }

    static func readVision(_ url: URL) -> [String: VisionResult?] {
        var out: [String: VisionResult?] = [:]
        for row in readJSONLines(url) {
            guard let uuid = row["uuid"] as? String else { continue }
            guard row["error"] == nil, let b64 = row["print"] as? String, let data = Data(base64Encoded: b64),
                let utility = row["utility"] as? Bool, let score = row["score"] as? Double
            else {
                out[uuid] = .some(nil)
                continue
            }
            let print = floats(data, elementType: (row["ptype"] as? Int) == 2 ? .double : .float)
            out[uuid] = VisionResult(print: print, utility: utility, score: score)
        }
        return out
    }

    static func verdictLine(_ uuid: String, _ v: Verdict) -> String {
        jsonLine(["uuid": uuid, "keep": v.keep, "kind": v.kind, "reason": v.reason])
    }

    static func readVerdicts(_ url: URL) -> [String: Verdict] {
        var out: [String: Verdict] = [:]
        for row in readJSONLines(url) {
            if let uuid = row["uuid"] as? String, let keep = row["keep"] as? Bool, let kind = row["kind"] as? String {
                out[uuid] = Verdict(keep: keep, kind: kind, reason: row["reason"] as? String ?? "")
            }
        }
        return out
    }
}

func jsonLine(_ obj: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

func readJSONLines(_ url: URL) -> [[String: Any]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}
