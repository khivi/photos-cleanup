import Foundation

/// Photos keyed by pixel size and capture time. Size ignores orientation: EXIF sizes are
/// unrotated, PhotoKit's are rotated.
public struct LibraryIndex {
    struct Key: Hashable { let long: Int, short: Int, second: Int }
    var byKey: [Key: [(seconds: Int, id: String)]] = [:]

    public init(_ photos: [(id: String, date: Date, width: Int, height: Int)] = []) {
        for p in photos { add(id: p.id, date: p.date, width: p.width, height: p.height) }
    }

    public mutating func add(id: String, date: Date, width: Int, height: Int) {
        let s = Self.seconds(date)
        byKey[Self.key(s, width, height), default: []].append((s, id))
    }

    /// The same time wins. Without one, Photos may have placed the photo in the zone where it was
    /// taken, a whole quarter-hour offset up to 14 hours: nearest first, and only if `confirm`
    /// (same name or same picture) agrees. A busy day of one camera has a photo at the same second
    /// of many offsets: unconfirmed, 55 of 124 offset matches in one folder were other photos.
    /// `excluding`: photos already matched, e.g. by an earlier frame of the same second.
    public func match(
        date: Date, width: Int, height: Int, excluding: Set<String> = [], confirm: (String) -> Bool = { _ in false }
    ) -> String? {
        let s = Self.seconds(date)
        let candidates = (byKey[Self.key(s, width, height)] ?? []).filter { !excluding.contains($0.id) }
        if let exact = candidates.first(where: { $0.seconds == s }) { return exact.id }
        return candidates.filter { abs(s - $0.seconds) <= 14 * 3600 && (s - $0.seconds) % 900 == 0 }
            .sorted { abs(s - $0.seconds) < abs(s - $1.seconds) }
            .first { confirm($0.id) }?.id
    }

    static func seconds(_ d: Date) -> Int { Int(d.timeIntervalSince1970.rounded(.down)) }

    static func key(_ seconds: Int, _ w: Int, _ h: Int) -> Key {
        Key(long: max(w, h), short: min(w, h), second: ((seconds % 60) + 60) % 60)
    }
}
