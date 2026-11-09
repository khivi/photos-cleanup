import Foundation

/// A user-picked folder kept as a security-scoped bookmark, so it survives the App Sandbox.
public struct FolderBookmark: Equatable, Sendable {
    public var url: URL
    public var data: Data
    /// The bookmark no longer resolves (folder deleted, drive unplugged). `url` is its last known path.
    public var missing: Bool

    /// Starts access to `url` until `release()`.
    public init(_ url: URL) throws {
        data = try Self.bookmark(url)
        self.url = url
        missing = false
        _ = url.startAccessingSecurityScopedResource()
    }

    /// Resolves `data` and starts access. A stale bookmark is renewed: `data` then differs, and the caller saves it.
    init(data: Data) {
        self.data = data
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        {
            self.url = url
            missing = false
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? Self.bookmark(url) { self.data = fresh }
        } else {
            let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
            url = URL(filePath: path ?? "/unreadable-bookmark")
            missing = true
        }
    }

    /// Balances the access `init` started.
    public func release() {
        if !missing { url.stopAccessingSecurityScopedResource() }
    }

    static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

public let importFoldersKey = "importFolderBookmarks"
public let exportDestinationKey = "exportDestinationBookmark"
/// The folders Import checks.
public func loadImportFolders(defaults: UserDefaults = .standard) -> [FolderBookmark] {
    let stored = defaults.array(forKey: importFoldersKey) as? [Data] ?? []
    let folders = stored.map { FolderBookmark(data: $0) }
    if folders.map(\.data) != stored { saveImportFolders(folders, defaults: defaults) }
    return folders
}

public func saveImportFolders(_ folders: [FolderBookmark], defaults: UserDefaults = .standard) {
    defaults.set(folders.map(\.data), forKey: importFoldersKey)
}

public func loadExportDestination(defaults: UserDefaults = .standard) -> FolderBookmark? {
    guard let data = defaults.data(forKey: exportDestinationKey) else { return nil }
    let folder = FolderBookmark(data: data)
    if folder.data != data { saveExportDestination(folder, defaults: defaults) }
    return folder
}

public func saveExportDestination(_ folder: FolderBookmark, defaults: UserDefaults = .standard) {
    defaults.set(folder.data, forKey: exportDestinationKey)
}
