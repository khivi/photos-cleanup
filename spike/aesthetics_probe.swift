// Reads image file paths from stdin (one per line), scores each with Vision's
// native aesthetics model, prints one result line per input line IN ORDER:
//   "<overallScore>\t<0|1 isUtility>"   on success
//   "ERR\t<reason>"                      on failure
// Run: swift aesthetics_probe.swift < paths.txt
// ponytail: serial scoring — ~50-200ms/image; parallelize with concurrentPerform
// only if the spike sample grows past a few thousand.
import Foundation
import Vision

while let path = readLine(strippingNewline: true) {
    if path.isEmpty { print("ERR\tempty"); continue }
    let request = VNCalculateImageAestheticsScoresRequest()
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    do {
        try handler.perform([request])
        guard let obs = request.results?.first else { print("ERR\tno-result"); continue }
        print("\(obs.overallScore)\t\(obs.isUtility ? 1 : 0)")
    } catch {
        print("ERR\t\(error.localizedDescription)")
    }
}
