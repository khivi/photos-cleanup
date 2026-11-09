import Foundation
import Testing

@testable import PhotosCleanupCore

@Test func importFoldersRoundTripThroughBookmarks() throws {
    let defaults = freshDefaults()
    let a = tempDir()
    let b = tempDir()
    try saveImportFolders([FolderBookmark(a), FolderBookmark(b)], defaults: defaults)
    let loaded = loadImportFolders(defaults: defaults)
    #expect(loaded.map(\.url.canonical) == [a.canonical, b.canonical])
    #expect(loaded.allSatisfy { !$0.missing })
}

@Test func unresolvableBookmarkIsKeptAsMissing() throws {
    let defaults = freshDefaults()
    let gone = tempDir()
    let kept = tempDir()
    try saveImportFolders([FolderBookmark(gone), FolderBookmark(kept)], defaults: defaults)
    try FileManager.default.removeItem(at: gone)

    let loaded = loadImportFolders(defaults: defaults)
    #expect(loaded.map(\.missing) == [true, false])
    #expect(loaded[0].url.lastPathComponent == gone.lastPathComponent)
    #expect(defaults.array(forKey: importFoldersKey)?.count == 2)
}

@Test func exportDestinationRoundTrips() throws {
    let defaults = freshDefaults()
    #expect(loadExportDestination(defaults: defaults) == nil)

    let new = tempDir()
    try saveExportDestination(FolderBookmark(new), defaults: defaults)
    #expect(loadExportDestination(defaults: defaults)?.url.canonical == new.canonical)

    try FileManager.default.removeItem(at: new)
    let missing = loadExportDestination(defaults: defaults)
    #expect(missing?.missing == true && missing?.url.lastPathComponent == new.lastPathComponent)
}
