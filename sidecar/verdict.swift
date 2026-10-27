// Keep/delete verdicts for screenshots, from the on-device Foundation Models.
// Reads "<uuid>\t<path>\t<YYYY-MM-DD>" lines from stdin; writes one line per input:
//   "<uuid>\t<kind>\t<0|1 keep>\t<summary>"   verdict ("picture" = not a utility image)
//   "<uuid>\tERR\t<reason>"                   failure
// Exits 1 if Foundation Models is unavailable (macOS 27+, Apple Intelligence on).
// ponytail: serial, fresh session per photo — ~1-3s each; the server caches verdicts by uuid.
import Foundation
import FoundationModels
import Vision

@Generable
enum Kind: String {
    case receipt, ticket, tracking, promo, document, notes, screenshot, meme, label, other
}

// Field order is generation order: describing the image first keeps the decision from
// being made before the model has looked, and the reason from being a rationalisation.
@Generable
struct Verdict {
    @Guide(description: "What the image is")
    var kind: Kind
    @Guide(description: "What the image shows, under 15 words. Do not say keep or delete.")
    var summary: String
    @Guide(description: "true if the owner would still want this photo today")
    var keep: Bool
}

let instructions = """
    You review utility photos (receipts, tickets, screenshots, documents) in someone's \
    photo library and decide whether each is still worth keeping. Expired tickets, \
    paid receipts for small purchases, memes and stale chat or app screenshots are \
    usually not worth keeping. Warranties, IDs, serial numbers, passwords, handwritten \
    notes and anything still in the future usually are.
    """
let today = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
// Spike (d3de461): deletes were only reliable on these kinds; labels, notes and documents
// are often keepsakes the model calls "expired".
let deletable: Set<Kind> = [.receipt, .ticket, .tracking, .promo, .screenshot, .meme]

guard case .available = SystemLanguageModel.default.availability else {
    FileHandle.standardError.write("Foundation Models unavailable: \(SystemLanguageModel.default.availability)\n".data(using: .utf8)!)
    exit(1)
}
// The server reads verdicts as they arrive; a pipe would otherwise block-buffer them.
setvbuf(stdout, nil, _IOLBF, 0)

func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
}

while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { print("\(parts.first ?? "")\tERR\tbad-input"); continue }
    let (uuid, url, date) = (parts[0], URL(fileURLWithPath: parts[1]), parts[2])
    do {
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        try VNImageRequestHandler(url: url, options: [:]).perform([aesthetics])
        guard aesthetics.results?.first?.isUtility == true else {
            print("\(uuid)\tpicture\t1\tNot a utility image")
            continue
        }

        let session = LanguageModelSession(instructions: instructions)
        let v = try await session.respond(
            generating: Verdict.self, options: GenerationOptions(samplingMode: .greedy)
        ) {
            "Today is \(today). This photo was taken on \(date)."
            Attachment(imageURL: url)
        }.content
        let keep = v.keep || !deletable.contains(v.kind)
        print("\(uuid)\t\(v.kind.rawValue)\t\(keep ? 1 : 0)\t\(clean(v.summary))")
    } catch {
        print("\(uuid)\tERR\t\(clean(error.localizedDescription))")
    }
}
