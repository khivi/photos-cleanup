import Foundation

/// What `photos-export` has written: per library id, the modification date it exported and the
/// path stem (`2024/05/IMG_0001`) its files share. A TSV, one photo per line.
public struct ExportManifest {
    public var entries: [String: (modified: Double, stem: String)] = [:]
    var taken: Set<String> = []

    public init(tsv: String = "") {
        for line in tsv.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3, let m = Double(f[1]) else { continue }
            record(id: String(f[0]), modified: m, stem: String(f[2]))
        }
    }

    public var tsv: String {
        entries.sorted { $0.value.stem < $1.value.stem }.map { "\($0.key)\t\($0.value.modified)\t\($0.value.stem)\n" }
            .joined()
    }

    /// Exported, and unchanged since.
    public func isCurrent(id: String, modified: Double) -> Bool { entries[id]?.modified == modified }

    /// The photo's stem: the one it has, else `dir/name`, numbered past another photo's.
    /// Case-insensitive, as APFS is.
    public mutating func stem(for id: String, dir: String, name: String) -> String {
        if let s = entries[id]?.stem { return s }
        var s = "\(dir)/\(name)"
        var n = 1
        while taken.contains(s.lowercased()) {
            s = "\(dir)/\(name) (\(n))"
            n += 1
        }
        taken.insert(s.lowercased())
        return s
    }

    public mutating func record(id: String, modified: Double, stem: String) {
        entries[id] = (modified, stem)
        taken.insert(stem.lowercased())
    }
}
