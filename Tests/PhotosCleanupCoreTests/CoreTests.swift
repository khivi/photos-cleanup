import Foundation
import Testing

@testable import PhotosCleanupCore

// MARK: Pure rules

@Test func candidateFilter() {
    let year = { (y: Int) in ISO8601DateFormatter().date(from: "\(y)-01-01T00:00:00Z") }
    let photos = [
        Photo(uuid: "plain", date: year(2024)),
        Photo(uuid: "shot", date: year(2024), screenshot: true),
        Photo(uuid: "movie", date: year(2024), isMovie: true),
        Photo(uuid: "fav", date: year(2024), favorite: true),
        Photo(uuid: "mine", date: year(2024), albums: ["Trip to Goa"]),  // the user's own album protects it
        Photo(uuid: "smart", date: year(2024), albums: ["Selfies"]),  // Apple's smart album doesn't
        Photo(uuid: "filed", date: year(2024), albums: ["Screenshots - Delete Me"]),  // nor a review album
        Photo(uuid: "undated"),
        Photo(uuid: "old", date: year(1990)),
    ]
    let ignore = loadIgnoreAlbums(dir: tempDir())
    #expect(candidatePhotos(photos, ignoring: ignore).map(\.uuid) == ["plain", "smart", "filed", "undated", "old"])
    #expect(candidatePhotos(photos, ignoring: ignore, onlyScreenshots: true).map(\.uuid) == ["shot"])
    #expect(candidatePhotos(photos, ignoring: ignore, requireValidDate: true).map(\.uuid) == ["plain", "smart", "filed"])
}

@Test func ignoreFilesAddAlbums() throws {
    let dir = tempDir()
    try "# a comment\nFamily\n\n".write(to: dir.appendingPathComponent("albums_ignore"), atomically: true, encoding: .utf8)
    try "Work\n".write(to: dir.appendingPathComponent("albums_ignore.local"), atomically: true, encoding: .utf8)
    let ignore = loadIgnoreAlbums(dir: dir)
    #expect(ignore.isSuperset(of: ["Family", "Work", "Selfies", "Screenshots - Delete Me"]))
    #expect(!ignore.contains("# a comment"))
}

@Test func ignoreAlbumsRoundTrip() throws {
    let dir = tempDir()
    try "# mine\nFamily\n".write(to: dir.appendingPathComponent("albums_ignore"), atomically: true, encoding: .utf8)
    #expect(userIgnoreAlbums(dir: dir) == ["Family"])
    try saveIgnoreAlbums(["Work", "Trips"], dir: dir)
    #expect(userIgnoreAlbums(dir: dir) == ["Work", "Trips"])
    #expect(try String(contentsOf: dir.appendingPathComponent("albums_ignore"), encoding: .utf8).hasPrefix("# mine\n"))
    #expect(loadIgnoreAlbums(dir: dir).isSuperset(of: ["Work", "Trips"]))
    #expect(!loadIgnoreAlbums(dir: dir).contains("Family"))
}

@Test func keepAlbumPhotosToggle() async throws {
    let photos = [
        Photo(uuid: "plain"), Photo(uuid: "mine", albums: ["Trip to Goa"]), Photo(uuid: "fav", favorite: true, albums: ["Trip to Goa"]),
        Photo(uuid: "filed", albums: ["Trip to Goa", "Paperwork - Delete Me"]),
        Photo(uuid: "legacy", albums: ["Trip to Goa", "Utility - Keep"]),
    ]
    let ignore = loadIgnoreAlbums(dir: tempDir())
    #expect(candidatePhotos(photos, ignoring: ignore).map(\.uuid) == ["plain"])
    #expect(candidatePhotos(photos, ignoring: ignore, keepAlbumPhotos: false).map(\.uuid) == ["plain", "mine", "filed", "legacy"])
    let (on, _) = try await makeCleanup(photos)
    #expect(Set(try await on.candidates("paperwork").map(\.uuid)) == ["plain"])
    let (off, _) = try await makeCleanup(photos, keepAlbumPhotos: false)
    #expect(Set(try await off.candidates("paperwork").map(\.uuid)) == ["plain", "mine"])
}

@MainActor @Test func everyPassHasOneName() {
    for (key, title) in Passes.all {
        #expect(Passes.deleteAlbum(key) == "\(title) - Delete Me")
        #expect(Passes.keepAlbum(key) == "\(title) - Keep")
        #expect(Passes.about[key]?.isEmpty == false, "\(key) needs a tooltip")
    }
    // The app's tabs read exactly the pass titles.
    for (key, title) in Passes.all {
        #expect(ReviewModel.tabs.contains { $0.view == .pass(key) && $0.title == title })
    }
}

@Test func paperworkNeverPreselectsAMisreadScreenshotForDelete() {
    let shot = Verdict(keep: false, kind: "screenshot", reason: "A hand with a ring")
    #expect(passVerdict("paperwork", shot)?.keep == true)
    #expect(passVerdict("screenshots", shot)?.keep == false)  // the Screenshots pass is untouched
    #expect(passVerdict("paperwork", Verdict(keep: false, kind: "receipt", reason: ""))?.keep == false)
}

// MARK: Passes over a Cleanup

@Test func screenshotsAttachVerdicts() async throws {
    let v = Verdict(keep: false, kind: "receipt", reason: "Paid coffee receipt")
    let photos = [Photo(uuid: "a", screenshot: true), Photo(uuid: "b", screenshot: true)]
    let (c, _) = try await makeCleanup(photos, verdicts: ["a": v], judge: FakeJudge(off: "off"))
    let r = try await c.pass("screenshots")
    #expect(r.photos.map(\.photo.uuid).sorted() == ["a", "b"])
    #expect(r.photos.first { $0.photo.uuid == "a" }?.verdict == v)
}

@Test func paperworkShowsOnlyVisionUtilityPhotosTheModelKeptAsUtility() async throws {
    let receipt = Verdict(keep: false, kind: "receipt", reason: "Paid")
    let picture = Verdict(keep: true, kind: "picture", reason: "Not a utility image")
    // c: not judged yet; d: Vision says not utility.
    let (c, _) = try await makeCleanup(
        "abcd".map { Photo(uuid: String($0)) },
        vision: ["a": V(utility: true), "b": V(utility: true), "c": V(utility: true), "d": V()],
        verdicts: ["a": receipt, "b": picture], judge: FakeJudge(off: "off"))
    let r = try await c.pass("paperwork")
    #expect(r.photos.map(\.photo.uuid) == ["a"])
    #expect(r.photos[0].verdict == receipt)
}

@Test func burstsGroupWithBestAndNewestFirst() async throws {
    var photos = dated(["a": 0, "b": 10, "c": 20, "far": 500, "d": 1000, "e": 1010, "f": 1020])
    photos.append(Photo(uuid: "filed", date: t0.addingTimeInterval(1020), albums: ["Bursts - Keep"]))
    let scores: [String: Double] = ["a": 0.1, "b": 0.9, "c": 0.5, "far": 0.5, "d": 0.2, "e": 0.3, "f": 0.8]
    let (c, _) = try await makeCleanup(photos, vision: scores.mapValues { V($0) })
    let r = try await c.pass("bursts")
    #expect(r.groups.map { [$0.best] + $0.photos.map(\.uuid) } == [["f", "d", "e", "f"], ["b", "a", "b", "c"]])
}

@Test func burstsSplitWhereShotsLookDifferent() async throws {
    // One burst: two repeats of a shot, two of another, a one-off (e), two utility images
    // (f, g: document pages look alike to prints) and one not analysed (h).
    let photos = dated(["a": 0, "b": 10, "c": 20, "d": 30, "e": 40, "f": 50, "g": 60, "h": 70])
    let vision: [String: VisionResult?] = [
        "a": V(0.5, [0]), "b": V(0.5, [0.1]), "c": V(0.5, [2]), "d": V(0.5, [2.1]), "e": V(0.5, [5]),
        "f": V(0.5, utility: true, [9]), "g": V(0.5, utility: true, [9]),
    ]
    let (c, _) = try await makeCleanup(photos, vision: vision)
    #expect(try await c.pass("bursts").groups.map { $0.photos.map(\.uuid) } == [["c", "d"], ["a", "b"]])
}

@Test func lowQualityFiltersByVisionScore() async throws {
    let vision: [String: VisionResult?] = ["a": V(-0.9), "b": V(0.5), "edge": V(Passes.lowQualityMax), "c": nil]
    let (c, _) = try await makeCleanup(["a", "b", "c", "edge"].map { Photo(uuid: $0) }, vision: vision)
    #expect(Set(try await c.pass("low-quality").photos.map(\.photo.uuid)) == ["a", "edge"])
    #expect(Set(try await c.pass("low-quality", threshold: 0.6).photos.map(\.photo.uuid)) == ["a", "b", "edge"])
}

@Test func passesSkipPhotosAlreadyFiled() async throws {
    let photos = [
        Photo(uuid: "a", screenshot: true),
        Photo(uuid: "b", screenshot: true, albums: ["Screenshots - Delete Me"]),
        Photo(uuid: "c", screenshot: true, albums: ["Screenshots - Keep"]),
        Photo(uuid: "d", screenshot: true, albums: ["Low Quality - Delete Me"]),  // another pass's album
    ]
    let (c, _) = try await makeCleanup(photos, judge: FakeJudge(off: "off"))
    #expect(Set(try await c.pass("screenshots").photos.map(\.photo.uuid)) == ["a", "d"])
}

@Test func lowQualityOldAlbumStillCountsAsFiled() async throws {
    let photos = [
        Photo(uuid: "old", albums: ["Low Quality - Review Me"]),  // filed before the rename
        Photo(uuid: "new", albums: ["Low Quality - Delete Me"]),
        Photo(uuid: "a"),
    ]
    let (c, _) = try await makeCleanup(photos, vision: ["old": V(-0.9), "new": V(-0.9), "a": V(-0.9)])
    #expect(try await c.pass("low-quality").photos.map(\.photo.uuid) == ["a"])
}

@Test func unknownPassThrows() async throws {
    let (c, _) = try await makeCleanup([])
    await #expect(throws: CleanupError.unknownPass) { try await c.pass("bogus") }
}

@Test func countsOnlyWhereKnown() async throws {
    let photos = dated(["a": 0, "b": 1, "c": 2])
    let dir = tempDir()
    let judge = FakeJudge(off: "off")
    var (c, lib) = try await makeCleanup(photos, judge: judge, cacheDir: dir)
    lib.gate.close()  // hold the Vision job so its results don't land yet
    var counts = await c.counts()
    #expect(counts["all"] == 3 && counts["screenshots"] == 0)
    #expect(counts["low-quality"] == .some(nil) && counts["bursts"] == .some(nil) && counts["paperwork"] == .some(nil))
    lib.gate.open()
    await settle(c)

    let pic = Verdict(keep: true, kind: "picture", reason: "")
    let doc = Verdict(keep: false, kind: "receipt", reason: "")
    let vision: [String: VisionResult?] = ["a": V(-0.9, utility: true, [0]), "b": V(0.5, [0.1]), "c": V(0.5, [0.2])]
    (c, lib) = try await makeCleanup(photos, vision: vision, verdicts: ["a": doc, "b": pic, "c": pic], judge: judge, cacheDir: tempDir())
    counts = await c.counts()
    #expect(counts["paperwork"] == 1 && counts["bursts"] == 2 && counts["low-quality"] == 1)
}

// MARK: Background jobs

@Test func visionJobAnalysesCachesAndReportsProgress() async throws {
    let dir = tempDir()
    let lib = FakeLibrary([Photo(uuid: "a"), Photo(uuid: "b")], vision: ["a": V(-0.9)])
    let (c, _) = try await makeCleanup([], library: lib, cacheDir: dir)
    lib.gate.close()
    #expect(await c.startVision(lib.all) == JobProgress(pending: 2, total: 2))
    #expect(await c.startVision([lib.all[0]]).pending == 2)  // in progress: not queued twice
    lib.gate.open()
    await settle(c)
    #expect(lib.visionCalls.withLock { $0 } == [["a", "b"]])
    let vision = await c.vision
    #expect(vision["a"]??.score == -0.9)
    #expect(vision["b"] == .some(nil))  // no local image: recorded, not retried
    // A restart reads the disk cache: nothing analysed again.
    let restarted = Cleanup(library: lib, judge: FakeJudge(), cacheDir: dir, ignoreAlbums: [])
    #expect(await restarted.startVision(lib.all).pending == 0)
}

@Test func secondPassQueuesBehindARunningClassifier() async throws {
    let shots = [Photo(uuid: "s1"), Photo(uuid: "s2")]
    let judge = FakeJudge(["s1": Verdict(keep: true, kind: "notes", reason: ""),
                           "s2": Verdict(keep: true, kind: "notes", reason: ""),
                           "u1": Verdict(keep: true, kind: "notes", reason: "")])
    let (c, _) = try await makeCleanup([], judge: judge)
    judge.gate.close()
    await c.startClassifier(shots)  // Screenshots tab
    await c.startClassifier([Photo(uuid: "u1")])  // Paperwork tab, mid-run
    await c.startClassifier(shots)  // Screenshots reopened: already in flight, not re-queued
    #expect(await c.classify == JobProgress(pending: 3, total: 3))
    judge.gate.open()
    await settle(c)
    #expect(judge.judged.withLock { $0 } == ["s1", "s2", "u1"])
    await c.startClassifier([Photo(uuid: "u2")])  // a new run starts from idle
    #expect(await c.classify.total == 1)
}

@Test func photosTheModelCantJudgeAreNotRequeuedEveryPoll() async throws {
    let judge = FakeJudge()  // judges nothing: every answer is nil
    let (c, _) = try await makeCleanup([], judge: judge)
    await c.startClassifier([Photo(uuid: "x")])
    await settle(c)
    await c.startClassifier([Photo(uuid: "x")])  // the UI's next poll
    #expect(await c.classify.pending == 0)
    #expect(judge.judged.withLock { $0 } == ["x"])
}

@Test func verdictsOffReportedWithoutJudging() async throws {
    let judge = FakeJudge(off: "needs macOS 27")
    let (c, _) = try await makeCleanup([], judge: judge)
    await c.startClassifier([Photo(uuid: "a")])
    #expect(await c.classify == JobProgress(error: "needs macOS 27"))
    #expect(judge.judged.withLock { $0 }.isEmpty)
}

// MARK: Commit and decisions

@Test func commitFilesDeleteAndKeepThenHidesThem() async throws {
    let photos = "abc".map { Photo(uuid: String($0), screenshot: true) }
    let (c, lib) = try await makeCleanup(photos, judge: FakeJudge(off: "off"))
    let done = try await c.commit("screenshots", delete: ["a"], keep: ["b"])
    #expect(done == .init(added: 1, album: "Screenshots - Delete Me", kept: 1, keepAlbum: "Screenshots - Keep"))
    #expect(lib.adds.withLock { $0.map { "\($0.album):\($0.uuids)" } }
            == ["Screenshots - Delete Me:[\"a\"]", "Screenshots - Keep:[\"b\"]"])
    #expect(try await c.pass("screenshots").photos.map(\.photo.uuid) == ["c"])
}

@Test func commitErrors() async throws {
    let (c, _) = try await makeCleanup([Photo(uuid: "a")])
    await #expect(throws: CleanupError.unknownPass) { try await c.commit("bogus", delete: ["a"], keep: []) }
    await #expect(throws: CleanupError.noMatchingPhotos) { try await c.commit("screenshots", delete: ["x"], keep: ["y"]) }
    let denied = FakeLibrary([Photo(uuid: "a")], status: "denied")
    let (d, _) = try await makeCleanup([], library: denied)
    await #expect(throws: CleanupError.accessDenied) { try await d.commit("screenshots", delete: ["a"], keep: []) }
}

@Test func commitLogsDecisionsAndVerdictStats() async throws {
    let verdicts = [
        "a": Verdict(keep: false, kind: "receipt", reason: ""),  // user deletes: agree
        "b": Verdict(keep: false, kind: "ticket", reason: ""),  // user keeps: override
    ]  // c has no verdict: not logged
    let (c, _) = try await makeCleanup("abc".map { Photo(uuid: String($0)) }, verdicts: verdicts, judge: FakeJudge(off: "off"))
    #expect(await c.verdictStats().isEmpty)
    _ = try await c.commit("screenshots", delete: ["a", "c"], keep: ["b"])
    _ = try await c.commit("low-quality", delete: ["a"], keep: [])  // not a verdict pass
    let stats = await c.verdictStats()
    #expect(stats.count == 1 && stats["screenshots"]?.agree == 1 && stats["screenshots"]?.total == 2)
}

@Test func visionCacheRoundTrips() {
    let line = Cleanup.visionLine("u", V(-0.25, utility: true, [0.5, -1]))
    let url = tempDir().appendingPathComponent("v.jsonl")
    try? (line + "\n" + Cleanup.visionLine("gone", nil) + "\n").write(to: url, atomically: true, encoding: .utf8)
    let read = Cleanup.readVision(url)
    #expect(read["u"] == V(-0.25, utility: true, [0.5, -1]))
    #expect(read["gone"] == .some(nil))
}
