// Vision image feature prints, for telling repeated shots from different photos.
// Reads "<uuid>\t<path>" lines from stdin; writes one line per input:
//   "<uuid>\t<elementType>\t<base64 of the raw vector>"   elementType 1 = Float32, 2 = Float64
//   "<uuid>\tUTILITY"                                     Vision isUtility: documents, receipts,
//                                                          screenshots; their pages look alike
//   "<uuid>\tERR\t<reason>"                               failure
// The server compares prints by L2 distance; its threshold was calibrated on that metric.
import Foundation
import Vision

while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { print("\(parts.first ?? "")\tERR\tbad-input"); continue }
    let request = VNGenerateImageFeaturePrintRequest()
    let aesthetics = VNCalculateImageAestheticsScoresRequest()
    do {
        try VNImageRequestHandler(url: URL(fileURLWithPath: parts[1]), options: [:])
            .perform([request, aesthetics])
        if aesthetics.results?.first?.isUtility == true { print("\(parts[0])\tUTILITY"); continue }
        guard let obs = request.results?.first else { print("\(parts[0])\tERR\tno-result"); continue }
        print("\(parts[0])\t\(obs.elementType.rawValue)\t\(obs.data.base64EncodedString())")
    } catch {
        print("\(parts[0])\tERR\t\(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
    }
}
