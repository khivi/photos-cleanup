// Reads image file paths from stdin (one per line), computes Vision's native
// image feature print for each, prints one result line per input line IN ORDER:
//   "<elementType>\t<elementCount>\t<base64 of the raw feature-vector Data>"  on success
//   "ERR\t<reason>"                                                            on failure
// elementType: 1 = Float32, 2 = Float64 (VNElementType.rawValue).
// The driver decodes the vector and computes pairwise L2 distance itself — a
// monotonic stand-in for VNFeaturePrintObservation.computeDistance, which is all
// a separation test needs.
// Run: swift featureprint_probe.swift < paths.txt
import Foundation
import Vision

while let path = readLine(strippingNewline: true) {
    if path.isEmpty { print("ERR\tempty"); continue }
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    do {
        try handler.perform([request])
        guard let obs = request.results?.first else { print("ERR\tno-result"); continue }
        print("\(obs.elementType.rawValue)\t\(obs.elementCount)\t\(obs.data.base64EncodedString())")
    } catch {
        print("ERR\t\(error.localizedDescription)")
    }
}
