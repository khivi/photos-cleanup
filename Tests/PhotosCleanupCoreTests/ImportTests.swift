import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosCleanupCore

private func row(_ status: ImportStatus, _ rel: String, match: String? = nil) -> ImportRow {
    let url = URL(filePath: "/root/" + rel)
    let ext = url.pathExtension.lowercased()
    return ImportRow(
        status: status, rel: rel, match: match, detail: nil,
        stem: url.deletingPathExtension().path.lowercased(), isImage: ["jpg", "heic"].contains(ext),
        isMovie: ext == "mov")
}

private func moves(_ rows: [ImportRow], skip: [String] = []) -> [String: String] {
    Dictionary(uniqueKeysWithValues: ImportScan.plan(rows, skip: skip).map { ($0.from, $0.to) })
}

@Test func importPlanSortsIntoDoneAndImport() {
    let m = moves(
        [
            row(.inLibrary, "2012/a.jpg", match: "A"),
            row(.liveVideo, "2012/a.mov"),  // goes with its still
            row(.other, "2012/aO.aae"),  // an edit's sidecar, too
            row(.new, "2012/b.jpg"),
            row(.liveVideo, "2012/Live Videos/b.mov"),  // next to its still, where Photos pairs them
            row(.copy, "copies/a.jpg", match: "2012/a.jpg"),  // its original is in the library: done
            row(.copy, "copies/b.jpg", match: "2012/b.jpg"),  // its original isn't yet: stays put
            row(.newCheckDate, "2012/c.jpg"),
            row(.newUndated, "2012/d.jpg"),
            row(.unreadable, "2012/e.jpg"),  // neither: stays
            row(.new, "Import/f.jpg"),  // already waiting
            row(.inLibrary, "Import/g.jpg", match: "G"),  // imported since
            row(.new, "Done/h.jpg"),  // deleted from the library since
            row(.skipped, "Export/i.jpg"),
        ], skip: ["Export"])
    #expect(
        m == [
            "2012/a.jpg": "Done/2012/a.jpg", "2012/a.mov": "Done/2012/a.mov", "2012/aO.aae": "Done/2012/aO.aae",
            "2012/b.jpg": "Import/2012/b.jpg", "2012/Live Videos/b.mov": "Import/2012/b.mov",
            "copies/a.jpg": "Done/copies/a.jpg",
            "2012/c.jpg": "Import/Check date/2012/c.jpg", "2012/d.jpg": "Import/Check date/2012/d.jpg",
            "Import/g.jpg": "Done/g.jpg", "Done/h.jpg": "Import/h.jpg",
        ])
}

@Test func importPlanMovesALibraryPackageOnlyWhole() {
    let lib = "Old.photoslibrary/originals/"
    #expect(
        moves([row(.inLibrary, lib + "a.jpg", match: "A"), row(.libraryCache, "Old.photoslibrary/resources/x")])
            == ["Old.photoslibrary": "Done/Old.photoslibrary"])
    #expect(moves([row(.inLibrary, lib + "a.jpg", match: "A"), row(.new, lib + "b.jpg")]).isEmpty)
}

/// A JPEG of `w`×`h` with an EXIF capture time ("2024:01:01 10:00:00"), or none.
private func jpeg(_ url: URL, _ w: Int, _ h: Int, taken: String?, gray: CGFloat = 0.5) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: 0)!
    ctx.setFillColor(gray: gray, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] =
        taken.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: $0]] } ?? [:]
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

@Test func importScanMatchesFilesAndSortsTheFolder() async throws {
    let taken = exifFormatter("yyyy:MM:dd HH:mm:ss").date(from: "2024:01:01 10:00:00")!
    let lib = FakeLibrary([Photo(uuid: "A", date: taken)])
    lib.sizes.withLock { $0 = ["A": (64, 48)] }
    let root = tempDir()
    try jpeg(root.appending(path: "2024/IMG_1.jpg"), 64, 48, taken: "2024:01:01 10:00:00")  // in the library
    try FileManager.default.createDirectory(at: root.appending(path: "backup"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: root.appending(path: "2024/IMG_1.jpg"), to: root.appending(path: "backup/IMG_1.jpg"))  // a copy
    try jpeg(root.appending(path: "2024/IMG_2.jpg"), 64, 48, taken: "2024:01:01 11:00:00", gray: 0.2)  // new
    try jpeg(root.appending(path: "2024/scan.jpg"), 32, 32, taken: nil)  // no camera date
    try Data("notes".utf8).write(to: root.appending(path: "2024/notes.txt"))

    let scan = try await Importer(library: lib).scan(root)
    let status = Dictionary(uniqueKeysWithValues: scan.rows.map { ($0.rel, $0.status) })
    #expect(status["2024/IMG_1.jpg"] == .inLibrary)
    #expect(status["backup/IMG_1.jpg"] == .copy)
    #expect(status["2024/IMG_2.jpg"] == .new)
    #expect(status["2024/scan.jpg"] == .newUndated)
    #expect(status["2024/notes.txt"] == .other)
    #expect(scan.rows.first { $0.rel == "2024/IMG_1.jpg" }?.match == "A")
    #expect((scan.toDone, scan.toImport) == (2, 2))

    #expect(scan.apply().isEmpty)
    let fm = FileManager.default
    for p in [
        "Done/2024/IMG_1.jpg", "Done/backup/IMG_1.jpg", "Import/2024/IMG_2.jpg", "Import/Check date/2024/scan.jpg",
    ] {
        #expect(fm.fileExists(atPath: root.appending(path: p).path), "\(p)")
    }
    #expect(fm.fileExists(atPath: root.appending(path: "2024/notes.txt").path))  // not a photo: stays
    #expect(!fm.fileExists(atPath: root.appending(path: "backup").path))  // emptied, dropped

    // A rerun after importing: Import/ moves to Done/; Delete Me photos count as not in the library.
    let later = FakeLibrary([
        Photo(uuid: "A", date: taken, albums: [Passes.allDeleteAlbum]),
        Photo(uuid: "B", date: taken + 3600),
    ])
    later.sizes.withLock { $0 = ["A": (64, 48), "B": (64, 48)] }
    let again = try await Importer(library: later).scan(root)
    let to = Dictionary(uniqueKeysWithValues: again.moves.map { ($0.from, $0.to) })
    #expect(to["Import/2024/IMG_2.jpg"] == "Done/2024/IMG_2.jpg")
    #expect(to["Done/2024/IMG_1.jpg"] == "Import/2024/IMG_1.jpg")
    #expect(again.fromDone == 1)
}

@MainActor @Test func importScreenChecksSortsAndRemembersFolders() async throws {
    let taken = exifFormatter("yyyy:MM:dd HH:mm:ss").date(from: "2024:01:01 10:00:00")!
    let lib = FakeLibrary([Photo(uuid: "A", date: taken)])
    lib.sizes.withLock { $0 = ["A": (64, 48)] }
    let root = tempDir()
    try jpeg(root.appending(path: "a.jpg"), 64, 48, taken: "2024:01:01 10:00:00")
    try jpeg(root.appending(path: "b.jpg"), 64, 48, taken: "2024:01:01 11:00:00", gray: 0.2)
    try jpeg(root.appending(path: "Export/c.jpg"), 64, 48, taken: "2024:01:01 12:00:00", gray: 0.8)
    let (cleanup, _) = try await makeCleanup([], library: lib)
    let settings = tempDir()
    let m = ReviewModel(cleanup: cleanup, importer: Importer(library: lib), dir: settings)
    await m.select(.importFolders)
    #expect(m.importSummary == "No folders")

    await m.addImportFolder(root)
    #expect(m.importSummary == "2 new · 3 to move")
    #expect(m.sidebar.first { $0.title == "Transfer" }?.items.map(\.badge) == [nil, 2])
    #expect(m.importSortPreview == "1 → Done\n2 → Import")
    #expect(loadImportFolders(dir: settings) == [root])

    await m.sortImportFolder()
    #expect(m.status == "Moved 3 of 3 files.")
    #expect(m.importInbox?.lastPathComponent == "Import")
    #expect(m.importSummary == "2 new · 0 to move")
    #expect(!m.canSortImport)

    m.removeImportFolder(root)
    #expect(m.importFolder == nil && loadImportFolders(dir: settings).isEmpty)
}

@Test func importMatchesHoldWhenFilesMove() async throws {
    // Two frames of one second, same size: each is its own library photo, by name, wherever it sits.
    let taken = exifFormatter("yyyy:MM:dd HH:mm:ss").date(from: "2024:01:01 10:00:00")!
    let lib = FakeLibrary([Photo(uuid: "A", date: taken), Photo(uuid: "B", date: taken)])
    lib.sizes.withLock { $0 = ["A": (64, 48), "B": (64, 48)] }
    lib.files.withLock { $0 = ["A": ["img_2.jpg"], "B": ["img_1.jpg"]] }
    let root = tempDir()
    try jpeg(root.appending(path: "trip/IMG_1.jpg"), 64, 48, taken: "2024:01:01 10:00:00")
    try jpeg(root.appending(path: "trip/IMG_2.jpg"), 64, 48, taken: "2024:01:01 10:00:00", gray: 0.2)
    let first = try await Importer(library: lib).scan(root)
    let match = Dictionary(uniqueKeysWithValues: first.rows.map { ($0.rel, $0.match) })
    #expect(match["trip/IMG_1.jpg"] == "B" && match["trip/IMG_2.jpg"] == "A")
    #expect(first.apply().isEmpty)

    let again = try await Importer(library: lib).scan(root)
    #expect(again.moves.isEmpty)
    let moved = Dictionary(uniqueKeysWithValues: again.rows.map { ($0.rel, $0.match) })
    #expect(moved["Done/trip/IMG_1.jpg"] == "B" && moved["Done/trip/IMG_2.jpg"] == "A")
}

@Test func importManifestRecordsWhatDoneStandsFor() {
    let rows = [
        row(.inLibrary, "2012/a.jpg", match: "A"),
        row(.liveVideo, "2012/a.mov"),  // follows its still: no row of its own
        row(.copy, "copies/a.jpg", match: "2012/a.jpg"),  // its original's photo
        row(.new, "2012/b.jpg"),
        row(.inLibrary, "Import/g.jpg", match: "G"),
        row(.new, "Done/h.jpg"),  // leaving Done/
        row(.inLibrary, "Old.photoslibrary/originals/p.jpg", match: "P"),  // its package moves whole
    ]
    #expect(
        ImportScan.manifest(rows, moves: ImportScan.plan(rows, skip: [])) == [
            "2012/a.jpg": "A", "copies/a.jpg": "A", "g.jpg": "G", "Old.photoslibrary/originals/p.jpg": "P",
        ])
}

@Test func importDecisionsHoldUntilTheirPhotoLeavesTheLibrary() async throws {
    let taken = exifFormatter("yyyy:MM:dd HH:mm:ss").date(from: "2024:01:01 10:00:00")!
    let lib = FakeLibrary([Photo(uuid: "A", date: taken), Photo(uuid: "B", date: taken)])
    lib.sizes.withLock { $0 = ["A": (64, 48), "B": (64, 48)] }
    lib.files.withLock { $0 = ["A": ["img_2.jpg"], "B": ["img_1.jpg"]] }
    let root = tempDir()
    try jpeg(root.appending(path: "trip/IMG_1.jpg"), 64, 48, taken: "2024:01:01 10:00:00")
    try jpeg(root.appending(path: "trip/IMG_2.jpg"), 64, 48, taken: "2024:01:01 10:00:00", gray: 0.2)
    #expect(try await Importer(library: lib).scan(root).apply().isEmpty)
    let manifest = root.appending(path: "Done/manifest.tsv")
    #expect(try String(contentsOf: manifest, encoding: .utf8) == "trip/IMG_1.jpg\tB\ntrip/IMG_2.jpg\tA\n")

    // Names that would now pair the frames the other way: the recorded decisions stand.
    lib.files.withLock { $0 = ["A": ["img_1.jpg"], "B": ["img_2.jpg"]] }
    let again = try await Importer(library: lib).scan(root)
    #expect(again.moves.isEmpty)
    let match = Dictionary(uniqueKeysWithValues: again.rows.map { ($0.rel, $0.match) })
    #expect(match["Done/trip/IMG_1.jpg"] == "B" && match["Done/trip/IMG_2.jpg"] == "A")

    // B deleted from the library: its file goes back to Import/, and its row goes.
    let later = FakeLibrary([Photo(uuid: "A", date: taken)])
    later.sizes.withLock { $0 = ["A": (64, 48)] }
    later.files.withLock { $0 = ["A": ["img_2.jpg"]] }
    let after = try await Importer(library: later).scan(root)
    #expect(after.moves == [ImportMove(from: "Done/trip/IMG_1.jpg", to: "Import/trip/IMG_1.jpg")])
    #expect(after.apply().isEmpty)
    #expect(try String(contentsOf: manifest, encoding: .utf8) == "trip/IMG_2.jpg\tA\n")
}
