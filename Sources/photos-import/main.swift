import Foundation
import PhotosCleanupCore

// The app's Import from a terminal: Photos access goes to the terminal. `--skip <subdir>` marks a
// library export: never moved, never new, nor are its photos' copies elsewhere.

let arguments = CommandLine.arguments.dropFirst()
guard let rootArg = arguments.first, !rootArg.hasPrefix("--") else {
    print("usage: photos-import <dir> [--skip <subdir>]... [--dry-run]")
    exit(64)
}
let options = zip(arguments, arguments.dropFirst())
let skip = options.filter { $0.0 == "--skip" }.map { $0.1 }
let report = URL(filePath: "/tmp/photos-import.tsv")

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let library = PhotoKitLibrary()
let access = await library.authorize()
guard access == "authorized" else {
    log("Photos access: \(access). Allow your terminal in System Settings → Privacy & Security → Photos.")
    exit(1)
}

let importer = Importer(library: library)
let progress = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        log("\(await importer.done)/\(await importer.total)")
    }
}
let scan: ImportScan
do {
    scan = try await importer.scan(URL(filePath: (rootArg as NSString).expandingTildeInPath), skip: skip)
} catch {
    log("\(error)")
    exit(66)
}
progress.cancel()

try scan.rows.map(\.tsv).joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
let folder = { (rel: String) in rel.split(separator: "/").dropLast().prefix(2).joined(separator: "/") }
print((["folder"] + ImportStatus.allCases.map(\.rawValue)).joined(separator: "\t"))
for (name, rows) in Dictionary(grouping: scan.rows, by: { folder($0.rel) }).sorted(by: { $0.key < $1.key })
    + [("TOTAL", scan.rows)]
{
    print(
        ([name.isEmpty ? "." : name] + ImportStatus.allCases.map { s in String(rows.count { $0.status == s }) })
            .joined(separator: "\t"))
}
log("report: \(report.path)")

let dryRun = arguments.contains("--dry-run")
log(
    "\(dryRun ? "would move" : "moving"): \(scan.toDone) to Done, \(scan.toImport) to Import"
        + " (\(scan.fromDone) of them from Done/, not in the library), \(scan.toRemoved) to Removed")
if dryRun { exit(0) }
let failed = scan.apply()
for (from, why) in failed.sorted(by: { $0.key < $1.key }) { log("not moved: \(from): \(why)") }
log("moved: \(scan.moves.count - failed.count); not moved: \(failed.count)")
