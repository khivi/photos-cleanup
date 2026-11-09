import Foundation
import Testing

@testable import PhotosCleanupCore

let utc = TimeZone(identifier: "UTC")!

@Test func exporterCopiesOnlyNewOrChangedAndNeverDeletes() async throws {
    let lib = FakeLibrary([Photo(uuid: "a", date: t0), Photo(uuid: "b", date: t0), Photo(uuid: "c")])
    lib.names.withLock { $0 = ["a": "IMG_0001", "b": "img_0001", "c": "IMG_0002"] }
    let dest = tempDir()
    let ex = Exporter(library: lib, destination: dest, timeZone: utc)
    try await ex.refresh()
    #expect(await ex.status.pending == 3)

    await ex.run()
    #expect(Set(lib.exported.withLock { $0 }) == ["a", "b", "c"])
    let files = try FileManager.default.subpathsOfDirectory(atPath: dest.path).sorted()
    #expect(files.contains("2024/01/IMG_0001.jpg"))
    #expect(files.contains("2024/01/img_0001 (1).jpg"))
    #expect(files.contains("undated/IMG_0002.jpg"))
    var s = await ex.status
    #expect((s.exported, s.pending, s.done, s.total, s.running) == (3, 0, 3, 3, false))
    #expect(s.lastExport != nil)

    // A rerun from a fresh launch: reads the manifest, copies only the edited photo, to the same file.
    lib.exported.withLock { $0 = [] }
    lib.modified.withLock { $0 = ["b": 5] }
    let again = Exporter(library: lib, destination: dest, timeZone: utc)
    await again.run()
    #expect(lib.exported.withLock { $0 } == ["b"])
    #expect(try Data(contentsOf: dest.appending(path: "2024/01/img_0001 (1).jpg")) == Data("b".utf8))

    // A photo gone from the library keeps its files; one that fails is retried next run.
    let fewer = FakeLibrary([Photo(uuid: "a", date: t0), Photo(uuid: "d", date: t0)])
    fewer.exportFails.withLock { $0 = ["d"] }
    let third = Exporter(library: fewer, destination: dest, timeZone: utc)
    await third.run()
    s = await third.status
    #expect(s.failed.keys.sorted() == ["2024/01/d"])
    #expect(s.pending == 1)
    #expect(FileManager.default.fileExists(atPath: dest.appending(path: "undated/IMG_0002.jpg").path))
    fewer.exportFails.withLock { $0 = [] }
    await third.run()
    #expect(fewer.exported.withLock { $0 } == ["d"])
    #expect(await third.status.failed.isEmpty)
}

@Test func exporterCopiesSeveralAtOnce() async throws {
    let lib = FakeLibrary((0..<12).map { Photo(uuid: "p\($0)", date: t0) })
    lib.names.withLock { $0 = Dictionary(uniqueKeysWithValues: (0..<12).map { ("p\($0)", "IMG") }) }
    let dest = tempDir()
    let ex = Exporter(library: lib, destination: dest, timeZone: utc)
    await ex.run()
    let peak = lib.inFlight.withLock { $0.max }
    #expect(peak > 1 && peak <= 4)
    #expect(lib.exported.withLock { $0 }.sorted() == (0..<12).map { "p\($0)" }.sorted())
    let s = await ex.status
    #expect((s.exported, s.done, s.total, s.failed.count) == (12, 12, 12, 0))
    let files = try FileManager.default.subpathsOfDirectory(atPath: dest.path).filter { $0.hasSuffix(".jpg") }
    #expect(Set(files).count == 12)
}

@Test func exporterWithoutDestinationOrDiskDoesNothing() async throws {
    let lib = FakeLibrary([Photo(uuid: "a", date: t0)])
    let none = Exporter(library: lib)
    try await none.refresh()
    await none.run()
    #expect(await none.status.pending == 0)
    #expect(await none.missing(["a"]) == 0)

    let unplugged = Exporter(library: lib, destination: URL(filePath: "/Volumes/pc-test-missing-\(UUID())"))
    try await unplugged.refresh()
    await unplugged.run()
    let s = await unplugged.status
    #expect((s.connected, s.pending) == (false, 1))
    #expect(lib.exported.withLock { $0 }.isEmpty)
}

@MainActor @Test func exportSidebarLabelsAndDeleteWarning() async throws {
    let photos = [
        Photo(uuid: "a", date: t0, albums: [Passes.allDeleteAlbum]),
        Photo(uuid: "b", date: t0, albums: [Passes.allDeleteAlbum]),
        Photo(uuid: "c", date: t0),
    ]
    let (cleanup, lib) = try await makeCleanup(photos)
    let dest = tempDir()
    let ex = Exporter(library: lib, timeZone: utc)
    let model = ReviewModel(cleanup: cleanup, exporter: ex, dir: tempDir())
    await model.select(.export)
    #expect(model.exportCountsLabel == "No destination")
    #expect(!model.canExport)
    #expect(model.sidebar.first { $0.title == "Transfer" }?.items.first?.badge == nil)

    await model.setExportDestination(dest)
    #expect(model.exportCountsLabel == "0 in export · 3 to copy")
    #expect(model.exportLastLabel() == "Never exported")
    #expect(model.sidebar.first { $0.title == "Transfer" }?.items.first?.badge == 3)
    #expect(model.canExport)

    await model.select(.deleted)
    #expect(model.banner?.hasSuffix("2 of them aren’t in your export: run Export first to keep a copy.") == true)

    await ex.run()
    await model.pollExport()  // what the screen's poll does
    await model.select(.export)
    #expect(model.exportCountsLabel == "3 in export · 0 to copy")
    #expect(model.sidebar.first { $0.title == "Transfer" }?.items.first?.badge == nil)
    await model.select(.deleted)
    #expect(model.banner?.contains("export") == false)
}

@MainActor @Test func chosenExportDestinationIsSavedAndReplaced() async throws {
    let (cleanup, lib) = try await makeCleanup([])
    let defaults = freshDefaults()
    let model = ReviewModel(
        cleanup: cleanup, exporter: Exporter(library: lib, timeZone: utc), dir: tempDir(), defaults: defaults)
    let first = tempDir()
    let second = tempDir()

    await model.chooseExportDestination(first)
    await model.chooseExportDestination(second)
    #expect(loadExportDestination(defaults: defaults)?.url.canonical == second.canonical)
    #expect(model.export.destination?.canonical == second.canonical)
}
