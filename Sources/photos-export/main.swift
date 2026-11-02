import Foundation
import PhotosCleanupCore

// The app's Export from a terminal: Photos access goes to the terminal.

let arguments = CommandLine.arguments.dropFirst()
guard let destArg = arguments.first, !destArg.hasPrefix("--") else {
    print("usage: photos-export <dest> [--dry-run]")
    exit(64)
}
let dest = URL(filePath: (destArg as NSString).expandingTildeInPath).standardizedFileURL

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let library = PhotoKitLibrary()
let access = await library.authorize()
guard access == "authorized" else {
    log("Photos access: \(access). Allow your terminal in System Settings → Privacy & Security → Photos.")
    exit(1)
}

try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
let exporter = Exporter(library: library, destination: dest)
try await exporter.refresh()
let before = await exporter.status
log("library: \(before.exported + before.pending); in export: \(before.exported); to copy: \(before.pending)")
if arguments.contains("--dry-run") { exit(0) }

let progress = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        let s = await exporter.status
        log("\(s.done)/\(s.total) \(s.current ?? "")")
    }
}
await exporter.run()
progress.cancel()
let after = await exporter.status
for (stem, why) in after.failed.sorted(by: { $0.key < $1.key }) { log("failed: \(stem): \(why)") }
log("exported: \(after.done - after.failed.count); failed: \(after.failed.count) (a rerun retries them); \(dest.path)")
exit(after.failed.isEmpty ? 0 : 1)
