import Foundation

/// One photo or video in the user's own library (iCloud Shared Album photos are left out).
public struct Photo: Sendable, Hashable, Identifiable {
    public var id: String { uuid }
    public var uuid: String
    public var date: Date?
    public var width: Int
    public var height: Int
    public var screenshot: Bool
    public var livePhoto: Bool
    public var isMovie: Bool
    public var favorite: Bool
    public var albums: [String]

    public init(
        uuid: String, date: Date? = nil, width: Int = 0, height: Int = 0, screenshot: Bool = false,
        livePhoto: Bool = false, isMovie: Bool = false, favorite: Bool = false, albums: [String] = []
    ) {
        self.uuid = uuid
        self.date = date
        self.width = width
        self.height = height
        self.screenshot = screenshot
        self.livePhoto = livePhoto
        self.isMovie = isMovie
        self.favorite = favorite
        self.albums = albums
    }
}

/// One photo's Vision analysis: feature print, Vision's isUtility, and its aesthetics score.
public struct VisionResult: Sendable, Equatable {
    public var print: [Float]
    public var utility: Bool
    public var score: Double

    public init(print: [Float], utility: Bool, score: Double) {
        self.print = print
        self.utility = utility
        self.score = score
    }
}

/// A Foundation Models keep/delete call. kind "picture": Vision says it isn't a utility image.
public struct Verdict: Sendable, Hashable {
    public var keep: Bool
    public var kind: String
    public var reason: String

    public init(keep: Bool, kind: String, reason: String) {
        self.keep = keep
        self.kind = kind
        self.reason = reason
    }
}

/// Background work the UI shows as a progress bar.
public struct JobProgress: Sendable, Equatable {
    public var pending = 0
    public var total = 0
    public var error: String?

    public init(pending: Int = 0, total: Int = 0, error: String? = nil) {
        self.pending = pending
        self.total = total
        self.error = error
    }
}

/// One name per pass: the key is the URL (/cleanup/<key>) and the UI view; the title is the
/// tab label and the album prefix. Album names are derived, never written out.
public enum Passes {
    public static let all: [(key: String, title: String)] = [
        ("screenshots", "Screenshots"),
        ("paperwork", "Paperwork"),
        ("bursts", "Bursts"),
        ("low-quality", "Low Quality"),
    ]

    /// The All view is not a pass, but it has a title and one Delete Me album, derived like a pass's.
    public static let allKey = "all"
    public static let allTitle = "All"
    public static let allDeleteAlbum = "\(allTitle) - Delete Me"

    public static func title(_ key: String) -> String? { all.first { $0.key == key }?.title }
    public static func deleteAlbum(_ key: String) -> String? { title(key).map { "\($0) - Delete Me" } }
    // Not in cleanupAlbumNames, so they count as user albums and the candidate filter skips
    // their photos on every later run.
    public static func keepAlbum(_ key: String) -> String? { title(key).map { "\($0) - Keep" } }

    /// The Delete Me album among a photo's albums (a pass's own, All's, or a legacy one), if any.
    public static func waitingAlbum(in albums: [String]) -> String? {
        let names = Set(all.compactMap { deleteAlbum($0.key) }).union([allDeleteAlbum]).union(
            legacyAlbums.values.joined().filter { $0.hasSuffix(" - Delete Me") })
        return albums.sorted().first(where: names.contains)
    }

    /// What each pass finds and how its photos start; the tab's tooltip.
    public static let about: [String: String] = [
        "screenshots": "Screenshots. The on-device model preselects the ones not worth keeping.",
        "paperwork":
            "Receipts, tickets, tracking, promos, documents, notes and labels. The on-device model preselects the ones not worth keeping.",
        "bursts":
            "Near-identical shots taken within a minute. The best of each group starts as Keep, the rest as Delete.",
        "low-quality": "Blurry, dark or accidental shots, by Vision's aesthetics score. All start as Delete.",
    ]

    /// Earlier names of a pass's album: photos in them still count as filed.
    public static let legacyAlbums: [String: Set<String>] = [
        "low-quality": ["Low Quality - Review Me"],
        "paperwork": ["Utility - Delete Me", "Utility - Keep"],
    ]
    /// Earlier pass keys, as written in decisions.jsonl.
    public static let legacyKeys = ["utility": "paperwork"]
    /// Passes judged by Foundation Models.
    public static let verdictKinds: Set<String> = ["screenshots", "paperwork"]

    public static let burstWindow: TimeInterval = 60
    /// Feature-print L2 distance below which two neighbouring shots count as repeats. Set by eye
    /// on 40 real bursts: pairs <= 0.44 were the same shot; from 0.46 they were different photos
    /// (report pages, a different person, different medicine labels).
    public static let similarMaxDistance: Float = 0.45
    /// Vision aesthetics score at or below which a photo is suggested as low quality. Set by eye
    /// on the real library: <= -0.75 was almost all accidental shots (black frames, pocket blur,
    /// a finger over the lens); from about -0.7 up, dark or soft photos of people creep in.
    public static let lowQualityMax = -0.75
}

/// Apple's smart albums: membership doesn't mean the user organised the photo.
public let defaultIgnoreAlbums: Set<String> = [
    "Screenshots", "Selfies", "Portrait", "Panoramas", "Live Photos", "Videos", "Slo-mo", "Bursts",
    "Time-lapse", "Recently Deleted", "Recents", "Hidden", "Imports", "Animated", "Long Exposure",
    "RAW", "Cinematic", "Spatial",
]

/// Review albums, so a photo in one still counts as a candidate. The last five come from the
/// photo-cleanup command-line tool and may exist in libraries it was run on.
public let cleanupAlbumNames: Set<String> = [
    "Screenshots - Delete Me", "Low Quality - Delete Me", "Low Quality - Review Me",
    "Cluster Extras - Review Me", "Cluster Keepers", "Similar Photos - Keepers",
    "Similar Photos - Review Me", "Documents - Review Me",
]

public let settingsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/photos-cleanup")

/// Albums whose membership doesn't protect a photo: the defaults, review albums, and any listed
/// in albums_ignore or albums_ignore.local in `dir` (one per line, '#' comments).
public func loadIgnoreAlbums(dir: URL = settingsDir) -> Set<String> {
    var albums = defaultIgnoreAlbums.union(cleanupAlbumNames)
    for name in ["albums_ignore", "albums_ignore.local"] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else {
            continue
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let album = line.trimmingCharacters(in: .whitespaces)
            if !album.isEmpty, !album.hasPrefix("#") { albums.insert(album) }
        }
    }
    return albums
}

/// The names the user listed in `albums_ignore` (what the Settings window edits), in file order.
public func userIgnoreAlbums(dir: URL = settingsDir) -> [String] {
    guard let text = try? String(contentsOf: dir.appendingPathComponent("albums_ignore"), encoding: .utf8)
    else { return [] }
    return text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Rewrites the names in `albums_ignore`, keeping its '#' comment lines. `albums_ignore.local` is untouched.
public func saveIgnoreAlbums(_ names: [String], dir: URL = settingsDir) throws {
    let file = dir.appendingPathComponent("albums_ignore")
    let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let comments = old.split(whereSeparator: \.isNewline).map(String.init).filter {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try (comments + names).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
}

private let minDate = ISO8601DateFormatter().date(from: "2000-01-01T00:00:00Z")!

/// Photos a pass may suggest: not favorited, not videos, and (with `keepAlbumPhotos`, the default)
/// not in any of the user's own albums.
/// Screenshots appear only with onlyScreenshots, which returns nothing else.
public func candidatePhotos(
    _ photos: [Photo], ignoring ignore: Set<String>, onlyScreenshots: Bool = false,
    requireValidDate: Bool = false, keepAlbumPhotos: Bool = true
) -> [Photo] {
    photos.filter { p in
        guard p.screenshot == onlyScreenshots, !p.isMovie, !p.favorite else { return false }
        guard !keepAlbumPhotos || Set(p.albums).subtracting(ignore).isEmpty else { return false }
        if requireValidDate {
            guard let d = p.date, d >= minDate else { return false }
        }
        return true
    }
}

/// Group date-sorted photos: one joins the current group if taken within `window` seconds of
/// the previous photo. Groups smaller than minSize are dropped.
public func groupByTime(_ photos: [Photo], window: TimeInterval, minSize: Int) -> [[Photo]] {
    guard let first = photos.first else { return [] }
    var groups: [[Photo]] = []
    var current = [first]
    for p in photos.dropFirst() {
        if let a = current.last?.date, let b = p.date, b.timeIntervalSince(a) <= window {
            current.append(p)
        } else {
            if current.count >= minSize { groups.append(current) }
            current = [p]
        }
    }
    if current.count >= minSize { groups.append(current) }
    return groups
}

/// Split a time-sorted burst wherever neighbouring shots stop looking alike. Utility images
/// (documents, labels) and photos not yet analysed never join: document pages look alike.
public func splitSimilar(_ group: [Photo], vision: [String: VisionResult?]) -> [[Photo]] {
    func vec(_ p: Photo) -> [Float]? {
        guard let v = vision[p.uuid] ?? nil, !v.utility else { return nil }
        return v.print
    }
    guard let first = group.first else { return [] }
    var runs: [[Photo]] = []
    var run = [first]
    for (a, b) in zip(group, group.dropFirst()) {
        if let pa = vec(a), let pb = vec(b), distance(pa, pb) < Passes.similarMaxDistance {
            run.append(b)
        } else {
            runs.append(run)
            run = [b]
        }
    }
    runs.append(run)
    return runs.filter { $0.count >= 2 }
}

func distance(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for (x, y) in zip(a, b) { sum += (x - y) * (x - y) }
    return sum.squareRoot()
}

/// The verdict as a pass should use it. Real screenshots have their own pass, so in Paperwork
/// "screenshot" is always a misread camera photo (a hand, a dashboard); never preselect delete.
public func passVerdict(_ kind: String, _ v: Verdict?) -> Verdict? {
    guard var v else { return nil }
    if kind == "paperwork", v.kind == "screenshot", !v.keep { v.keep = true }
    return v
}
