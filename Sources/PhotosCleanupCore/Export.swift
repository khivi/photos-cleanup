import Foundation

/// What the export has written: per photo uuid, the modification date it exported and the
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

/// One photo or video as the export sees it.
public struct ExportItem: Sendable, Equatable {
    public let uuid: String
    /// Seconds since 1970; any change in Photos (an edit, a favorite) moves it.
    public let modified: Double
    public let date: Date?

    public init(uuid: String, modified: Double, date: Date?) {
        self.uuid = uuid
        self.modified = modified
        self.date = date
    }
}

public struct ExportStatus: Sendable, Equatable {
    public var destination: URL?
    /// The destination folder is there: a disk may be unplugged.
    public var connected = false
    /// Photos in the export and unchanged since.
    public var exported = 0
    /// Photos new or changed since the last export.
    public var pending = 0
    public var running = false
    /// This run: photos done of `total`, and the one being written.
    public var done = 0
    public var total = 0
    public var current: String?
    /// The last run's failures, by stem: a rerun retries them.
    public var failed: [String: String] = [:]
    public var lastExport: Date?
    public var freeBytes: Int64?

    public init() {}
}

/// Copies the library's originals, edits and Live Photo videos into `<dest>/YYYY/MM`. A rerun
/// copies only photos new or changed since. Never deletes: a backup keeps photos deleted from the library.
public actor Exporter {
    public static let manifestName = ".photos-export.tsv"
    /// Exports in flight at once: iCloud originals download, and 4 keeps PhotoKit from queuing too much.
    static let parallel = 4

    let library: PhotoLibrary
    let calendar: Calendar
    private(set) var destination: URL?
    var manifest = ExportManifest()
    var items: [ExportItem] = []
    var running = false
    var done = 0
    var total = 0
    var current: String?
    var failed: [String: String] = [:]
    var task: Task<Void, Never>?

    public init(library: PhotoLibrary, destination: URL? = nil, timeZone: TimeZone = .current) {
        self.library = library
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        calendar = cal
        self.destination = destination
        manifest = Self.readManifest(destination)
    }

    static func readManifest(_ dest: URL?) -> ExportManifest {
        ExportManifest(
            tsv: dest.flatMap { try? String(contentsOf: $0.appending(path: manifestName), encoding: .utf8) } ?? "")
    }

    var manifestURL: URL? { destination?.appending(path: Self.manifestName) }

    public func setDestination(_ url: URL) {
        guard !running else { return }
        destination = url
        manifest = Self.readManifest(url)
        failed = [:]
    }

    /// Rereads the library's photo list: what `status` counts against.
    public func refresh() async throws {
        guard destination != nil else {
            items = []
            return
        }
        let lib = library
        items = try await offload { try lib.exportable() }
    }

    public var status: ExportStatus {
        var s = ExportStatus()
        s.destination = destination
        if let destination {
            s.connected = FileManager.default.fileExists(atPath: destination.path)
            s.exported = items.count { manifest.isCurrent(id: $0.uuid, modified: $0.modified) }
            s.pending = items.count - s.exported
            if s.connected {
                s.lastExport =
                    manifestURL.flatMap {
                        try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]
                    }
                    as? Date
                s.freeBytes = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
            }
        }
        s.running = running
        s.done = done
        s.total = total
        s.current = current
        s.failed = failed
        return s
    }

    /// How many of these photos the export doesn't hold yet, in any version.
    public func missing(_ uuids: [String]) -> Int {
        destination == nil ? 0 : uuids.count { manifest.entries[$0] == nil }
    }

    /// Runs `run()` in the background; `stop()` ends it once the photos in flight finish.
    public func start() {
        guard !running else { return }
        task = Task { await run() }
    }

    public func stop() { task?.cancel() }

    public func run() async {
        guard !running, let dest = destination, FileManager.default.fileExists(atPath: dest.path) else { return }
        running = true
        failed = [:]
        defer {
            running = false
            current = nil
            task = nil
        }
        do { try await refresh() } catch {
            failed["library"] = "\(error)"
            return
        }
        let todo = items.filter { !manifest.isCurrent(id: $0.uuid, modified: $0.modified) }
        (done, total) = (0, todo.count)
        let lib = library
        await withTaskGroup(of: (ExportItem, String, String?).self) { group in
            var queue = todo[...]
            var inFlight = 0
            while true {
                while inFlight < Self.parallel, !Task.isCancelled, let item = queue.popFirst() {
                    guard let name = lib.exportName(item.uuid) else {  // gone since the refresh
                        done += 1
                        continue
                    }
                    let stem = manifest.stem(for: item.uuid, dir: month(item.date), name: name)
                    current = stem
                    inFlight += 1
                    group.addTask {
                        do {
                            try await lib.export(item.uuid, stem: stem, to: dest)
                            return (item, stem, nil)
                        } catch { return (item, stem, error.localizedDescription) }
                    }
                }
                guard let (item, stem, error) = await group.next() else { break }
                inFlight -= 1
                if let error {
                    failed[stem] = error
                } else {
                    manifest.record(id: item.uuid, modified: item.modified, stem: stem)
                }
                done += 1
                if done % 100 == 0 { save() }
            }
        }
        save()
    }

    func save() {
        guard let url = manifestURL else { return }
        do { try manifest.tsv.write(to: url, atomically: true, encoding: .utf8) } catch {
            failed[Self.manifestName] = error.localizedDescription
        }
    }

    func month(_ date: Date?) -> String {
        guard let date else { return "undated" }
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d/%02d", c.year!, c.month!)
    }
}
