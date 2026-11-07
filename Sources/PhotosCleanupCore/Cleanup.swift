import Foundation

/// What a pass shows: its photos (or, for bursts, groups with the best shot) and progress.
public struct PassResult: Sendable {
    public var photos: [PassPhoto] = []
    public var groups: [BurstGroup] = []
    /// Vision aesthetics score of each analysed photo in the pass.
    public var scores: [String: Double] = [:]
    public var progress = JobProgress()
}

/// A photo in a pass, with the model's verdict where the pass has one.
public struct PassPhoto: Sendable, Hashable, Identifiable {
    public var photo: Photo
    public var verdict: Verdict?
    public var id: String { photo.uuid }

    public init(photo: Photo, verdict: Verdict? = nil) {
        self.photo = photo
        self.verdict = verdict
    }
}

/// Shots of one burst; `best` is the uuid of the one to keep.
public struct BurstGroup: Sendable, Hashable {
    public var photos: [Photo]
    public var best: String
}

public enum CleanupError: Error, Equatable {
    case unknownPass
    case noMatchingPhotos
}

extension CleanupError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownPass: "Unknown pass."
        case .noMatchingPhotos: "Those photos are no longer in the library."
        }
    }
}

/// The app's state and background work: the photo list, the Vision analysis, the verdict
/// queue, commits and the on-disk caches.
public actor Cleanup {
    let library: any PhotoLibrary
    let judge: any Judge
    let cacheDir: URL
    let ignoreAlbums: Set<String>
    /// False: photos in the user's own albums can be candidates too.
    let keepAlbumPhotos: Bool
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
    /// The subset of `committed` filed into a Delete Me album.
    var filedDelete: Set<String> = []

    /// nil: no local image. Prints are dropped once paired into `near`: 3 KB each, ~600 MB at 200k photos.
    var vision: [String: VisionResult?] = [:]
    /// Each analysed photo's look-alikes (`nearPairs`), all grouping asks of a print.
    var near: [String: Set<String>] = [:]
    /// Each photo's line in the Vision cache, to read its print back when a photo it may pair with is analysed.
    var visionLines: [String: Range<Int>] = [:]
    /// Bumped whenever a grouped pass's inputs change (photo list, commits, Vision results), so
    /// Bursts and Similar regroup only then: Similar takes ~0.5 s at 200k photos.
    var generation = 0
    var groupCache: [String: (generation: Int, groups: [[Photo]])] = [:]
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
        keepAlbumPhotos: Bool = true, verdictsOff: String? = nil
    ) {
        self.library = library
        self.judge = judge
        self.cacheDir = cacheDir
        self.ignoreAlbums = ignoreAlbums
        self.keepAlbumPhotos = keepAlbumPhotos
        self.verdictsOff = verdictsOff
    }

    /// Reads the photo list and the disk caches. Call once at startup. Off the actor, side by side:
    /// the Vision cache alone takes ~3.6 s for 38k photos, and in init it froze the window.
    public func load() async throws {
        let library = library
        let (visionURL, verdictURL) = (
            cacheDir.appendingPathComponent(Self.visionCache), cacheDir.appendingPathComponent(Self.verdictCache)
        )
        async let caches = offload { (Self.readVision(visionURL), Self.readVerdicts(verdictURL)) }
        let all = try await offload { try library.photos() }
        let ((read, lines), verdicts) = try await caches
        photos = all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        byUUID = Dictionary(photos.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let photos = photos
        near = try await offload { Self.pairAll(photos, read, lines, visionURL) }
        (vision, visionLines, self.verdicts) = (read, lines, verdicts)
        generation += 1
    }

    // MARK: Passes

    /// A pass's photos, before any model judgement, minus those already filed.
    func candidates(_ kind: String) throws -> [Photo] {
        let found: [Photo]
        switch kind {
        case "screenshots":
            found = candidatePhotos(
                photos, ignoring: ignoreAlbums, kind: .screenshot, keepAlbumPhotos: keepAlbumPhotos)
        case "videos":
            found = candidatePhotos(photos, ignoring: ignoreAlbums, kind: .video, keepAlbumPhotos: keepAlbumPhotos)
        case "live-photos":
            found = candidatePhotos(photos, ignoring: ignoreAlbums, keepAlbumPhotos: keepAlbumPhotos).filter(\.live)
        case "selfies":
            found = candidatePhotos(photos, ignoring: ignoreAlbums, keepAlbumPhotos: keepAlbumPhotos).filter(\.selfie)
        case "paperwork", "low-quality":
            found = candidatePhotos(photos, ignoring: ignoreAlbums, keepAlbumPhotos: keepAlbumPhotos)
        case "bursts", "similar":
            found = candidatePhotos(
                photos, ignoring: ignoreAlbums, requireValidDate: true, keepAlbumPhotos: keepAlbumPhotos)
        default: throw CleanupError.unknownPass
        }
        // Similar also skips photos Bursts already filed: they are the same kind of decision.
        let owners = kind == "similar" ? ["similar", "bursts"] : [kind]
        let filed = Set(owners.flatMap { [Passes.deleteAlbum($0)!, Passes.keepAlbum($0)!] } + [Passes.allDeleteAlbum])
            .union(owners.flatMap { Passes.legacyAlbums[$0] ?? [] })
        return found.filter { !committed.contains($0.uuid) && filed.isDisjoint(with: $0.albums) }
    }

    /// Narrow Paperwork and Low Quality by the Vision analysis done so far, and its progress.
    func analysed(_ kind: String, _ photos: [Photo], threshold: Double) -> ([Photo], JobProgress) {
        let progress = startVision(photos)
        let narrowed: [Photo]
        switch kind {
        case "paperwork": narrowed = photos.filter { (vision[$0.uuid] ?? nil)?.utility == true }
        case "low-quality":
            narrowed = photos.filter { ((vision[$0.uuid] ?? nil)?.score).map { $0 <= threshold } ?? false }
        default: narrowed = photos
        }
        return (narrowed, progress)
    }

    func bursts(_ photos: [Photo]) -> [[Photo]] {
        let dated = photos.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return groupByTime(dated, window: Passes.burstWindow, minSize: 2).flatMap { splitSimilar($0, near: near) }
    }

    /// Same-scene groups across a day, leaving out photos already in a Bursts group.
    func similar(_ photos: [Photo]) -> [[Photo]] {
        let inBursts = Set(groups("bursts", (try? candidates("bursts")) ?? []).joined().map(\.uuid))
        return groupSimilar(photos.filter { !inBursts.contains($0.uuid) }, near: near)
    }

    /// The groups of a grouped pass, oldest first. `photos` is always the pass's candidates.
    func groups(_ kind: String, _ photos: [Photo]) -> [[Photo]] {
        if let c = groupCache[kind], c.generation == generation { return c.groups }
        let g = kind == "bursts" ? bursts(photos) : similar(photos)
        groupCache[kind] = (generation, g)
        return g
    }

    func score(_ p: Photo) -> Double { (vision[p.uuid] ?? nil)?.score ?? -2 }  // unanalysed sort last

    public func pass(_ kind: String, threshold: Double = Passes.lowQualityMax) throws -> PassResult {
        var photos = try candidates(kind)
        var result = PassResult()
        if Passes.plain.contains(kind) {  // no Vision, no verdicts; newest first, Videos longest first
            if kind == "videos" { photos.sort { $0.duration > $1.duration } }
            result.photos = photos.map { PassPhoto(photo: $0) }
            return result
        }
        if kind != "screenshots" { (photos, result.progress) = analysed(kind, photos, threshold: threshold) }
        for p in photos { if let s = (vision[p.uuid] ?? nil)?.score { result.scores[p.uuid] = s } }
        if kind == "low-quality" { photos.sort { score($0) < score($1) } }  // surest deletes first
        if Passes.grouped.contains(kind) {
            result.groups = groups(kind, photos).reversed().map { g in  // newest group first
                // An edited shot wins, then the highest score; first max wins ties: the earliest shot.
                let pool = g.contains(where: \.edited) ? g.filter(\.edited) : g
                return BurstGroup(photos: g, best: pool.reduce(pool[0]) { score($1) > score($0) ? $1 : $0 }.uuid)
            }
            return result
        }
        if Passes.verdictKinds.contains(kind) {
            startClassifier(photos)
            if result.progress.pending == 0 { result.progress = classify }  // Vision first, then the model
        }
        if kind == "paperwork" {
            // Unjudged photos appear once classified; "picture" means the model's own Vision
            // check said it isn't a utility image after all.
            photos = photos.filter { (verdicts[$0.uuid]?.kind ?? "picture") != "picture" }
        }
        result.photos = photos.map {
            PassPhoto(
                photo: $0, verdict: Passes.verdictKinds.contains(kind) ? passVerdict(kind, verdicts[$0.uuid]) : nil)
        }
        return result
    }

    /// Photos per pass, or nil where knowing it needs work not done yet.
    public func counts() -> [String: Int?] {
        var out: [String: Int?] = ["all": photos.count]
        for (kind, _) in Passes.all {
            guard let found = try? candidates(kind) else { continue }
            if kind == "screenshots" || Passes.plain.contains(kind) {
                out[kind] = found.count
                continue
            }
            let done = found.allSatisfy { vision.keys.contains($0.uuid) }
            let (narrowed, _) = analysed(kind, found, threshold: Passes.lowQualityMax)
            if !done {
                out[kind] = .some(nil)  // the background Vision analysis is still running
            } else if kind == "paperwork" {
                let judged = narrowed.compactMap { verdicts[$0.uuid] }
                out[kind] = judged.count == narrowed.count ? judged.filter { $0.kind != "picture" }.count : nil
            } else if Passes.grouped.contains(kind) {
                out[kind] = groups(kind, narrowed).reduce(0) { $0 + $1.count }
            } else {
                out[kind] = narrowed.count
            }
        }
        return out
    }

    // MARK: Vision analysis

    /// The Vision analysis, whichever pass started it: the sidebar shows it until counts are known.
    public func visionStatus() -> JobProgress { visionProgress }

    /// The verdict queue, and the passes with photos in it (a screenshot is Screenshots', the rest
    /// Paperwork's): the sidebar shows the job on those rows.
    public func verdictStatus() -> (progress: JobProgress, passes: Set<String>) {
        (classify, Set(inflight.compactMap { byUUID[$0].map { $0.screenshot ? "screenshots" : "paperwork" } }))
    }

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
        let start = ContinuousClock.now
        var done = 0
        // Batches stay queued until saved, so a request meanwhile doesn't queue them again.
        while let batch = nextVisionBatch() {
            guard let results = try? await offload({ library.vision(batch) }) else { return finishVision() }
            record(results, count: batch.count)
            done += batch.count
        }
        print(
            "Vision: \(done) photos in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))), \(memoryLabel())"
        )
        fflush(stdout)
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
        let lines = results.map { ($0.key, Self.visionLine($0.key, $0.value)) }
        if var at = appendLines(Self.visionCache, lines.map(\.1)) {
            for (uuid, line) in lines {
                visionLines[uuid] = at..<(at + line.utf8.count)
                at += line.utf8.count + 1
            }
        }
        pairFresh(results)
        vision.merge(results.mapValues { $0.map(\.withoutPrint) }) { $1 }
        generation += 1
        visionQueue.removeFirst(min(count, visionQueue.count))
        visionProgress.pending = visionQueue.count
    }

    /// Pairs newly analysed photos with each other and with analysed photos they may pair with:
    /// the same day or within `burstWindow`, their prints read back from the cache.
    func pairFresh(_ results: [String: VisionResult?]) {
        let fresh = Self.shots(results.keys.compactMap { byUUID[$0] }, results)
        guard !fresh.isEmpty else { return }
        let cal = Calendar.current
        let spans = fresh.map { s in
            let (from, to) = (s.photo.date! - Passes.burstWindow, s.photo.date! + Passes.burstWindow)
            return cal.startOfDay(for: from)..<cal.dateInterval(of: .day, for: to)!.end
        }
        let old = photos.filter { p in
            guard results[p.uuid] == nil, let d = p.date, let v = vision[p.uuid] ?? nil, !v.utility else {
                return false
            }
            return spans.contains { $0.contains(d) }
        }
        let prints = Self.readPrints(
            cacheDir.appendingPathComponent(Self.visionCache),
            old.compactMap { p in visionLines[p.uuid].map { (p.uuid, $0) } })
        let shots = fresh + old.compactMap { p in prints[p.uuid].map { (p, $0) } }
        near.merge(nearPairs(shots, fresh: Set(fresh.map(\.photo.uuid)))) { $0.union($1) }
    }

    /// The dated, analysed photos that aren't utility images, with their prints: what `nearPairs` compares.
    static func shots(_ photos: [Photo], _ vision: [String: VisionResult?]) -> [(photo: Photo, print: [Float])] {
        photos.compactMap { p in
            guard p.date != nil, let v = vision[p.uuid] ?? nil, !v.utility else { return nil }
            return (p, v.print)
        }
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
        classify = JobProgress(pending: inflight.count, total: total, verdicts: true)
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

    /// File photos into the pass's Delete Me (`delete`) and Keep (`keep`) albums.
    /// `Passes.allKey` is the All view: only `delete` is filed, into "All - Delete Me"; `keep` is ignored
    /// and nothing is logged, since All has no verdicts.
    public func commit(_ kind: String, delete: [String], keep: [String]) async throws -> Committed {
        let isAll = kind == Passes.allKey
        guard let album = isAll ? Passes.allDeleteAlbum : Passes.deleteAlbum(kind),
            let keepAlbum = isAll ? "" : Passes.keepAlbum(kind)
        else { throw CleanupError.unknownPass }
        let keep = isAll ? [] : keep
        let doomed = delete.filter { byUUID[$0] != nil }
        let kept = keep.filter { byUUID[$0] != nil }
        guard !doomed.isEmpty || !kept.isEmpty else { throw CleanupError.noMatchingPhotos }
        let library = library
        for (uuids, name) in [(doomed, album), (kept, keepAlbum)] where !uuids.isEmpty {
            _ = try await offload { try library.add(album: name, uuids: uuids) }
        }
        committed.formUnion(doomed + kept)
        filedDelete.formUnion(doomed)
        generation += 1
        if Passes.verdictKinds.contains(kind) {
            logDecisions(kind, doomed.map { ($0, "delete") } + kept.map { ($0, "keep") })
        }
        return Committed(added: doomed.count, album: album, kept: kept.count, keepAlbum: keepAlbum)
    }

    /// Deletes the photos of `uuids` that sit in a Delete Me album, after macOS confirms; they stay in
    /// Recently Deleted for 30 days. Returns the uuids deleted: none when the user cancels.
    public func delete(_ uuids: [String]) async throws -> [String] {
        let waiting = Set(photos.filter { Passes.waitingAlbum(in: $0.albums) != nil }.map(\.uuid)).union(filedDelete)
        let doomed = uuids.filter { waiting.contains($0) && byUUID[$0] != nil }
        guard !doomed.isEmpty else { return [] }
        let library = library
        let n = try await offload { try library.delete(uuids: doomed) }
        guard n > 0 else { return [] }
        let gone = Set(doomed)
        photos.removeAll { gone.contains($0.uuid) }
        for u in gone { byUUID[u] = nil }
        filedDelete.subtract(gone)
        committed.subtract(gone)
        generation += 1
        return doomed
    }

    /// One line per committed photo that has a verdict, to measure the model's accuracy.
    func logDecisions(_ kind: String, _ decided: [(String, String)]) {
        let now = ISO8601DateFormatter().string(from: .now)
        appendLines(
            Self.decisionsLog,
            decided.compactMap { uuid, decision in
                passVerdict(kind, verdicts[uuid]).map { v in
                    jsonLine([
                        "uuid": uuid, "kind": kind, "verdict_kind": v.kind, "verdict_keep": v.keep,
                        "decision": decision, "ts": now,
                    ])
                }
            })
    }

    // MARK: Cache files (JSON lines)

    /// Returns the byte offset the first line was written at, nil when nothing was written.
    @discardableResult
    func appendLines(_ name: String, _ lines: [String]) -> Int? {
        guard !lines.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent(name)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            guard let end = try? h.seekToEnd(), (try? h.write(contentsOf: data)) != nil else { return nil }
            return Int(end)
        }
        return (try? data.write(to: url)) != nil ? 0 : nil
    }

    static func visionLine(_ uuid: String, _ v: VisionResult?) -> String {
        guard let v else { return jsonLine(["uuid": uuid, "error": "no local image"]) }
        let data = v.print.withUnsafeBufferPointer { Data(buffer: $0) }
        return jsonLine([
            "uuid": uuid, "print": data.base64EncodedString(), "ptype": 1,
            "utility": v.utility, "score": v.score,
        ])
    }

    /// Each photo's analysis without its print (nil: none possible) and the byte range of its line;
    /// a later line wins. Prints stay on disk: `readPrints` reads them back.
    static func readVision(_ url: URL) -> (results: [String: VisionResult?], lines: [String: Range<Int>]) {
        var out: [String: VisionResult?] = [:]
        var lines: [String: Range<Int>] = [:]
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return (out, lines) }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            autoreleasepool {  // JSONSerialization's objects otherwise pile up until the read ends
                if let row = (try? JSONSerialization.jsonObject(with: data[start..<end])) as? [String: Any],
                    let uuid = row["uuid"] as? String
                {
                    out[uuid] = .some(visionRow(row, print: false))
                    lines[uuid] = start..<end
                }
            }
            start = end + 1
        }
        return (out, lines)
    }

    /// The prints on these lines of the Vision cache.
    static func readPrints(_ url: URL, _ lines: [(uuid: String, range: Range<Int>)]) -> [String: [Float]] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? h.close() }
        var out: [String: [Float]] = [:]
        for (uuid, range) in lines {
            autoreleasepool {
                guard (try? h.seek(toOffset: UInt64(range.lowerBound))) != nil,
                    let data = try? h.read(upToCount: range.count),
                    let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    let v = visionRow(row)
                else { return }
                out[uuid] = v.print
            }
        }
        return out
    }

    /// Pairs every analysed photo a run of days at a time, so only those days' prints are in RAM:
    /// all at once peaked at 544 MB for 38k photos. A run breaks where `nearPairs` never compares
    /// across: a new day more than `burstWindow` after the last photo.
    static func pairAll(_ photos: [Photo], _ vision: [String: VisionResult?], _ lines: [String: Range<Int>], _ url: URL)
        -> [String: Set<String>]
    {
        let analysed = photos.filter { p in
            p.date != nil && lines[p.uuid] != nil && (vision[p.uuid] ?? nil).map { !$0.utility } == true
        }.sorted { $0.date! < $1.date! }
        var near: [String: Set<String>] = [:]
        var run: [Photo] = []
        func pairRun() {
            let prints = readPrints(url, run.map { ($0.uuid, lines[$0.uuid]!) })
            near.merge(nearPairs(run.compactMap { p in prints[p.uuid].map { (p, $0) } })) { $0.union($1) }
            run.removeAll(keepingCapacity: true)
        }
        for p in analysed {
            if let last = run.last?.date, !Calendar.current.isDate(last, inSameDayAs: p.date!),
                p.date!.timeIntervalSince(last) > Passes.burstWindow
            {
                pairRun()
            }
            run.append(p)
        }
        pairRun()
        return near
    }

    /// One cache line's analysis; `print: false` skips decoding the print, leaving it empty.
    static func visionRow(_ row: [String: Any], print: Bool = true) -> VisionResult? {
        guard row["error"] == nil, let b64 = row["print"] as? String,
            let utility = row["utility"] as? Bool, let score = row["score"] as? Double
        else { return nil }
        guard print else { return VisionResult(print: [], utility: utility, score: score) }
        guard let data = Data(base64Encoded: b64) else { return nil }
        let floats = floats(data, elementType: (row["ptype"] as? Int) == 2 ? .double : .float)
        return VisionResult(print: floats, utility: utility, score: score)
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

extension VisionResult {
    var withoutPrint: VisionResult { VisionResult(print: [], utility: utility, score: score) }
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
