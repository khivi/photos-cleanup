import Foundation
import Testing

@testable import PhotosCleanupCore

@MainActor @Test func bestFaceWinsTheBurstOverTheScore() async throws {
    let burst = dated(["x": 0, "y": 1, "z": 2])
    let vision = ["x": vr(0.9, face: 0.2), "y": vr(0.3, face: 0.8), "z": vr(0.5, face: 0.4)]
    let (c, _) = try await makeCleanup(burst, vision: vision)
    let m = ReviewModel(cleanup: c, dir: tempDir())
    await m.select(.pass("bursts"))
    #expect(m.groups.map(\.best) == ["y"])
    #expect(m.decisions == ["x": .delete, "y": .keep, "z": .delete])
    #expect(m.scoreLine("y") == "Score 0.30 · face 0.80 · ★ of 3")
    #expect(m.scoreLine("x") == "Score 0.90 · face 0.20 · ★ face 0.80")
}

@Test func facesWithinATenthTieAndTheScoreDecides() async throws {
    let burst = dated(["x": 0, "y": 1])
    let (c, _) = try await makeCleanup(burst, vision: ["x": vr(0.9, face: 0.79), "y": vr(0.3, face: 0.81)])
    #expect(try await c.pass("bursts").groups.map(\.best) == ["x"])
}

@Test func withoutFacesTheScoreDecidesAndNoFaceIsShown() async throws {
    let burst = dated(["x": 0, "y": 1])
    let (c, _) = try await makeCleanup(burst, vision: ["x": vr(0.9), "y": vr(0.3)])
    let r = try await c.pass("bursts")
    #expect(r.groups.map(\.best) == ["x"])
    #expect(r.faces.isEmpty)
}

@Test func photosCachedBeforeFacesAreAnalysedAgainOnlyInGroups() async throws {
    // "solo" is a day later, in no group.
    let photos = dated(["x": 0, "y": 1, "solo": 86_400 * 2])
    var old: [String: VisionResult?] = ["x": vr(0.9), "y": vr(0.3), "solo": vr(0.5)]
    for k in old.keys { old[k]??.face = nil }
    let lib = FakeLibrary(photos, vision: ["x": vr(0.9, face: 0.1), "y": vr(0.3, face: 0.9), "solo": vr(0.5)])
    let (c, _) = try await makeCleanup(photos, vision: old, library: lib)
    #expect(try await c.pass("bursts").groups.map(\.best) == ["x"])  // by score until faces are in
    await settle(c)
    #expect(Set(lib.visionCalls.withLock { $0 }.joined()) == ["x", "y"])
    #expect(try await c.pass("bursts").groups.map(\.best) == ["y"])
    await settle(c)
    #expect(lib.visionCalls.withLock { $0.count } == 1)  // checked once, not on every poll
}

@Test func visionCacheKeepsTheFace() {
    let url = tempDir().appendingPathComponent("v.jsonl")
    var unchecked = vr(0.1)
    unchecked.face = nil
    let lines = [Cleanup.visionLine("f", vr(0.1, face: 0.25)), Cleanup.visionLine("old", unchecked)]
    try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    let read = Cleanup.readVision(url).results
    #expect((read["f"] ?? nil)?.face == 0.25)
    #expect((read["old"] ?? nil)?.face == nil)
}

@Test func aPhotoNoLongerOnThisMacKeepsItsAnalysis() async throws {
    let photos = dated(["x": 0, "y": 1])
    var old: [String: VisionResult?] = ["x": vr(0.9), "y": vr(0.3)]
    for k in old.keys { old[k]??.face = nil }
    let lib = FakeLibrary(photos, vision: ["y": vr(0.3, face: 0.9)])  // x: no local image now
    let (c, _) = try await makeCleanup(photos, vision: old, library: lib)
    _ = try await c.pass("bursts")
    await settle(c)
    let r = try await c.pass("bursts")
    #expect(r.groups.map { Set($0.photos.map(\.uuid)) } == [["x", "y"]])
    #expect(r.scores["x"] == 0.9)
    #expect(lib.visionCalls.withLock { $0.count } == 1)
}
