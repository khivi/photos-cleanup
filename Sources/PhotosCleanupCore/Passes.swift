import Accelerate
import Foundation

/// One photo or video in the user's own library (iCloud Shared Album photos are left out).
public struct Photo: Sendable, Hashable, Identifiable {
    public var id: String { uuid }
    public var uuid: String
    public var date: Date? = nil
    public var screenshot = false
    public var isMovie = false
    /// Seconds; 0 for a photo.
    public var duration: TimeInterval = 0
    public var favorite = false
    public var edited = false
    public var albums: [String] = []
    /// A Live Photo: a still with a short video. Deleting it deletes both.
    public var live = false
    public var screenRecording = false

    /// "m:ss" for a video, nil for a photo.
    public var durationLabel: String? {
        guard isMovie else { return nil }
        let s = Int(duration.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// What a candidate list holds: each photo is exactly one kind.
public enum PhotoKind: Sendable {
    case photo, screenshot, video
}

/// One photo's Vision analysis: feature print, Vision's isUtility, and its aesthetics score.
public struct VisionResult: Sendable, Equatable {
    public var print: [Float]
    public var utility: Bool
    public var score: Double
    /// Capture quality of the photo's worst face, 0 with none; nil: not checked (cached before faces were).
    public var face: Double? = nil
}

/// A Foundation Models keep/delete call. kind "picture": Vision says it isn't a utility image.
public struct Verdict: Sendable, Hashable {
    public var keep: Bool
    public var kind: String
    public var reason: String
}

/// Background work the UI shows as a progress bar.
public struct JobProgress: Sendable, Equatable {
    public var pending = 0
    public var total = 0
    public var error: String? = nil
    /// The model judging photos, not the Vision analysis.
    public var verdicts = false

    /// Done so far, from 0 to 1.
    public var fraction: Double { total == 0 ? 0 : Double(total - pending) / Double(total) }
}

/// One name per pass: the key is the UI view and the decisions.jsonl kind; the title is the
/// tab label and the album prefix. Album names are derived, never written out.
public enum Passes {
    public static let all: [(key: String, title: String)] = [
        ("screenshots", "Screenshots"),
        ("paperwork", "Paperwork"),
        ("bursts", "Bursts"),
        ("similar", "Similar"),
        ("low-quality", "Low Quality"),
        ("videos", "Videos"),
    ]

    /// Passes that need neither Vision nor verdicts: their photos and counts are known at load.
    public static let plain: Set<String> = ["videos"]

    /// Passes shown as groups of photos, with the best of each marked.
    public static let grouped: Set<String> = ["bursts", "similar"]

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
    /// What each pass finds and which photos start marked Delete, in plain words: the sidebar
    /// tooltip and the line above the grid.
    public static let about: [String: String] = [
        "screenshots":
            "Your screenshots. Apple Intelligence marks the ones that look no longer needed, like old codes, maps and confirmations.",
        "paperwork":
            "Photos of receipts, tickets, labels and documents. Apple Intelligence marks the ones that look no longer needed.",
        "bursts":
            "Several shots taken within a minute. The best one is kept: the sharpest, with the best faces. The rest are marked to delete. Photos you edited are kept.",
        "similar":
            "Shots of the same scene on the same day. The best one is kept: the sharpest, with the best faces. The rest are marked to delete. Photos you edited are kept.",
        "low-quality":
            "Shots that look blurry, dark or taken by accident. All are marked to delete, except photos you edited.",
        "videos":
            "Your videos, longest first. Clips under \(Int(accidentalVideoMax)) seconds are marked to delete: they are usually accidental.",
    ]

    /// Earlier names of a pass's album: photos in them still count as filed.
    public static let legacyAlbums: [String: Set<String>] = [
        "low-quality": ["Low Quality - Review Me"],
        "paperwork": ["Utility - Delete Me", "Utility - Keep"],
    ]
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
    /// Seconds below which a video is suggested as accidental. Set by eye, like `lowQualityMax`:
    /// shorter clips were pocket recordings and mistaken taps.
    public static let accidentalVideoMax: TimeInterval = 2
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
    defaultIgnoreAlbums.union(cleanupAlbumNames).union(userIgnoreAlbums(dir: dir))
        .union(userIgnoreAlbums(dir: dir, file: "albums_ignore.local"))
}

/// The names the user listed in `albums_ignore` (what the Settings window edits), in file order.
public func userIgnoreAlbums(dir: URL = settingsDir, file: String = "albums_ignore") -> [String] {
    guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
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

/// The months marked Done in `reviewed_months` in `dir`: "2024-03 312" lines, the month and its photo count when marked.
public func loadReviewedMonths(dir: URL = settingsDir) -> [String: Int] {
    guard let text = try? String(contentsOf: dir.appendingPathComponent("reviewed_months"), encoding: .utf8)
    else { return [:] }
    var months: [String: Int] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: " ")
        if parts.count == 2, let n = Int(parts[1]) { months[String(parts[0])] = n }
    }
    return months
}

public func saveReviewedMonths(_ months: [String: Int], dir: URL = settingsDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try months.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)\n" }.joined()
        .write(to: dir.appendingPathComponent("reviewed_months"), atomically: true, encoding: .utf8)
}

private let minDate = ISO8601DateFormatter().date(from: "2000-01-01T00:00:00Z")!

/// Photos of one `kind` a pass may suggest: not favorited, and (with `keepAlbumPhotos`, the default)
/// not in any of the user's own albums.
public func candidatePhotos(
    _ photos: [Photo], ignoring ignore: Set<String>, kind: PhotoKind = .photo,
    requireValidDate: Bool = false, keepAlbumPhotos: Bool = true
) -> [Photo] {
    photos.filter { p in
        let k: PhotoKind = p.isMovie ? .video : p.screenshot ? .screenshot : .photo
        guard k == kind, !p.favorite else { return false }
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
public func splitSimilar(_ group: [Photo], near: [String: Set<String>]) -> [[Photo]] {
    guard let first = group.first else { return [] }
    var runs: [[Photo]] = []
    var run = [first]
    for (a, b) in zip(group, group.dropFirst()) {
        if near[a.uuid]?.contains(b.uuid) == true {
            run.append(b)
        } else {
            runs.append(run)
            run = [b]
        }
    }
    runs.append(run)
    return runs.filter { $0.count >= 2 }
}

/// Group by calendar day: within a day, in time order, a photo joins the first group whose first
/// photo is near it, else starts one. Groups of one are dropped. Comparing to the first photo, not
/// any member, stops chains of slowly changing shots merging into one group. Utility images and
/// photos not yet analysed are never near anything, so never join.
/// ponytail: per-day only, so a scene shot on two days stays two groups; widen to a week if that misses real repeats.
public func groupSimilar(_ photos: [Photo], near: [String: Set<String>]) -> [[Photo]] {
    var days: [DateComponents: [Photo]] = [:]
    for p in photos.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
        guard let d = p.date, near[p.uuid] != nil else { continue }  // alike nothing: a group of one
        days[Calendar.current.dateComponents([.year, .month, .day], from: d), default: []].append(p)
    }
    var groups: [[Photo]] = []
    for shots in days.values {
        var day: [[Photo]] = []
        for s in shots {
            if let i = day.firstIndex(where: { near[$0[0].uuid]?.contains(s.uuid) == true }) {
                day[i].append(s)
            } else {
                day.append([s])
            }
        }
        groups += day.filter { $0.count >= 2 }
    }
    return groups.sorted { $0[0].date! < $1[0].date! }
}

/// Each photo's look-alikes: prints within `similarMaxDistance`, compared only where Bursts and
/// Similar would compare them, the same calendar day or within `burstWindow` (a burst across
/// midnight). With `fresh`, only pairs with a fresh photo. Shots must be dated and not utility images.
func nearPairs(_ shots: [(photo: Photo, print: [Float])], fresh: Set<String>? = nil) -> [String: Set<String>] {
    let sorted = shots.sorted { $0.photo.date! < $1.photo.date! }
    let days = sorted.map { Calendar.current.dateComponents([.year, .month, .day], from: $0.photo.date!) }
    var near: [String: Set<String>] = [:]
    for i in sorted.indices {
        for j in (i + 1)..<sorted.count {
            guard
                days[j] == days[i]
                    || sorted[j].photo.date!.timeIntervalSince(sorted[i].photo.date!) <= Passes.burstWindow
            else { break }  // sorted: every later shot is further away
            let (a, b) = (sorted[i].photo.uuid, sorted[j].photo.uuid)
            if let fresh, !fresh.contains(a), !fresh.contains(b) { continue }
            if distance(sorted[i].print, sorted[j].print) < Passes.similarMaxDistance {
                near[a, default: []].insert(b)
                near[b, default: []].insert(a)
            }
        }
    }
    return near
}

/// nearPairs' hot path: every pair of a day's photos (vDSP: ~10x the loop).
func distance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else {
        return zip(a, b).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }
    return vDSP.distanceSquared(a, b).squareRoot()
}

/// The verdict as a pass should use it. Real screenshots have their own pass, so in Paperwork
/// "screenshot" is always a misread camera photo (a hand, a dashboard); never preselect delete.
public func passVerdict(_ kind: String, _ v: Verdict?) -> Verdict? {
    guard var v else { return nil }
    if kind == "paperwork", v.kind == "screenshot", !v.keep { v.keep = true }
    return v
}
