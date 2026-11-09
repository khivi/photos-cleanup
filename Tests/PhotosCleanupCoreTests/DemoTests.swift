import Foundation
import Testing

@testable import PhotosCleanupCore

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "scripts/demo", directoryHint: .isDirectory)

@Test func demoManifestLoads() throws {
    let photos = try DemoLibrary(directory: fixtures).photos()
    #expect(photos.count == 46)
    let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.uuid, $0) })
    #expect(byID["demo-screenshot-1"]?.screenshot == true)
    #expect(byID["demo-video-5"]?.isMovie == true)
    #expect(byID["demo-video-5"]?.durationLabel == "2:08")
    #expect(byID["demo-burst-a4"]?.edited == true)
    #expect(byID["demo-photo-3"]?.albums == ["Family Trip"])
    #expect(byID["demo-photo-8"]?.date == nil)
    #expect(byID["demo-waiting-1"]?.albums == ["Low Quality - Delete Me"])
}

@Test func demoAlbumsAndDeletesChangePhotos() async throws {
    let lib = try DemoLibrary(directory: fixtures)
    #expect(try lib.add(album: "Keepers", uuids: ["demo-photo-1", "demo-photo-1", "nope"]) == 2)
    #expect(try lib.add(album: "Keepers", uuids: ["demo-photo-1"]) == 1)
    #expect(try lib.photos().first { $0.uuid == "demo-photo-1" }?.albums == ["Keepers"])

    #expect(try lib.delete(uuids: ["demo-photo-1", "nope"]) == 1)
    #expect(try lib.delete(uuids: ["demo-photo-1"]) == 0)
    #expect(try lib.photos().count == 45)
    #expect(try lib.photos().contains { $0.uuid == "demo-photo-1" } == false)
    #expect(try lib.exportable().count == 45)
    #expect(try lib.importIndex().contains { $0.id == "demo-photo-1" } == false)
    #expect(try lib.add(album: "Keepers", uuids: ["demo-photo-1"]) == 0)
}

@Test func demoImportIndexSkipsDeleteMePhotos() throws {
    let lib = try DemoLibrary(directory: fixtures)
    let ids = Set(try lib.importIndex().map(\.id))
    #expect(!ids.contains("demo-waiting-1"))
    #expect(!ids.contains("demo-photo-8"))  // no capture date
    let shot = try #require(try lib.importIndex().first { $0.id == "demo-burst-a1" })
    #expect((shot.width, shot.height) == (640, 480))
}

@Test func demoJudgeReturnsManifestVerdicts() async throws {
    let lib = try DemoLibrary(directory: fixtures)
    let judge = DemoJudge(library: lib)
    #expect(judge.unavailableReason() == nil)
    let v = await judge.judge(Photo(uuid: "demo-screenshot-4"))
    #expect(
        v == Verdict(keep: true, kind: "document", reason: "Wi-Fi password for the cabin"))
    #expect(await judge.judge(Photo(uuid: "demo-screenshot-1"))?.keep == false)
    #expect(await judge.judge(Photo(uuid: "demo-photo-1")) == nil)
}

@Test func demoExportCopiesTheImage() async throws {
    let src = tempDir()
    let dest = tempDir()
    try """
    {"photos":[{"uuid":"a","file":"a.jpg","date":"2025-01-01T12:00:00Z","width":4,"height":3}]}
    """.write(to: src.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
    try Data("pixels".utf8).write(to: src.appending(path: "a.jpg"))
    let lib = try DemoLibrary(directory: src)
    #expect(lib.exportName("a") == "a")
    try await lib.export("a", stem: "2025/a", to: dest)
    #expect(try Data(contentsOf: dest.appending(path: "2025/a.jpg")) == Data("pixels".utf8))
}

@Test func demoFixturesNeedTheFlagAndTheFolder() throws {
    let res = tempDir()
    #expect(demoFixtures(arguments: ["app", "--demo"], resources: res) == nil)  // a release bundle
    try FileManager.default.createDirectory(at: res.appending(path: "demo"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: res.appending(path: "demo/manifest.json"))
    #expect(demoFixtures(arguments: ["app"], resources: res) == nil)
    #expect(demoFixtures(arguments: ["app", "--demo"], resources: res)?.lastPathComponent == "demo")
    #expect(demoFixtures(arguments: ["app", "--demo"], resources: nil) == nil)
}

@Test func demoLibraryGivesEveryPassCandidates() async throws {
    let lib = try DemoLibrary(directory: fixtures)
    let c = Cleanup(
        library: lib, judge: DemoJudge(library: lib), cacheDir: tempDir(),
        ignoreAlbums: loadIgnoreAlbums(dir: tempDir()))
    try await c.load()
    for _ in 0..<2 {  // the model judges paperwork only after Vision has run
        for (key, _) in Passes.all { _ = try await c.pass(key) }
        await settle(c)
    }
    var found: [String: (photos: Int, groups: Int)] = [:]
    for (key, _) in Passes.all {
        let r = try await c.pass(key)
        found[key] = (r.photos.count, r.groups.count)
        #expect(r.photos.count + r.groups.count > 0, "\(key) has no candidates")
    }
    #expect(found["screenshots"]?.photos == 6)
    #expect(found["paperwork"]?.photos == 7)
    #expect(found["bursts"]?.groups == 2)
    #expect(found["similar"]?.groups ?? 0 >= 2)
    #expect(found["low-quality"]?.photos == 6)
    #expect(found["videos"]?.photos == 3)  // one favorite, one in an album
}
