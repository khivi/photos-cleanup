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

    /// EXIF times carry no time zone: a match may be off by whole quarter hours, up to 14 hours.
    public func match(date: Date, width: Int, height: Int) -> String? {
        let s = Self.seconds(date)
        return byKey[Self.key(s, width, height)]?.first {
            abs(s - $0.seconds) <= 14 * 3600 && (s - $0.seconds) % 900 == 0
        }?.id
    }

    static func seconds(_ d: Date) -> Int { Int(d.timeIntervalSince1970.rounded(.down)) }

    static func key(_ seconds: Int, _ w: Int, _ h: Int) -> Key {
        Key(long: max(w, h), short: min(w, h), second: ((seconds % 60) + 60) % 60)
    }
}
