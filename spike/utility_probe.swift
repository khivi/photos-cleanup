// Reads "<path>\t<YYYY-MM-DD>" lines from stdin. Vision's isUtility gates each
// photo; utility ones go to the on-device Foundation Models with the image
// attached. One output line per input line, IN ORDER:
//   "SKIP"                                   not a utility photo
//   "<kind>\t<0|1 keep>\t<reason>"           verdict
//   "ERR\t<reason>"                          failure
// Run: swift utility_probe.swift < lines.txt   (macOS 27+, Apple Intelligence on)
// ponytail: serial, fresh session per photo — ~1-3s each; fine for a spike sample.
import Foundation
import FoundationModels
import Vision

@Generable
enum Kind: String {
    case receipt, ticket, document, notes, screenshotOfChat, screenshotOfApp, meme, label, other
}

@Generable
struct Verdict {
    @Guide(description: "What the image is")
    var kind: Kind
    @Guide(description: "true if the owner would still want this photo today")
    var keep: Bool
    @Guide(description: "One short sentence, under 15 words")
    var reason: String
}

let instructions = """
    You review utility photos (receipts, tickets, screenshots, documents) in someone's \
    photo library and decide whether each is still worth keeping. Expired tickets, \
    paid receipts for small purchases, memes and stale chat or app screenshots are \
    usually not worth keeping. Warranties, IDs, serial numbers, passwords, handwritten \
    notes and anything still in the future usually are.
    """
let today = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])

guard case .available = SystemLanguageModel.default.availability else {
    FileHandle.standardError.write("Foundation Models unavailable: \(SystemLanguageModel.default.availability)\n".data(using: .utf8)!)
    exit(1)
}

func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
}

while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { print("ERR\tbad-input"); continue }
    let url = URL(fileURLWithPath: parts[0])
    do {
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        try VNImageRequestHandler(url: url, options: [:]).perform([aesthetics])
        guard aesthetics.results?.first?.isUtility == true else { print("SKIP"); continue }

        let session = LanguageModelSession(instructions: instructions)
        let v = try await session.respond(generating: Verdict.self) {
            "Today is \(today). This photo was taken on \(parts[1])."
            Attachment(imageURL: url)
        }.content
        // Only these kinds got reliable delete calls; on labels, notes and "other" (ordinary
        // photos isUtility lets through) the model parrots "expired" at keepsakes.
        let keep = v.keep || ![.receipt, .ticket, .screenshotOfApp, .screenshotOfChat, .meme].contains(v.kind)
        print("\(v.kind.rawValue)\t\(keep ? 1 : 0)\t\(clean(v.reason))")
    } catch {
        print("ERR\t\(clean(error.localizedDescription))")
    }
}
