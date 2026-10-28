import Foundation
import Photos
import Vision

// Image attachments arrived with FoundationModels 2 (the macOS 27 SDK). Older SDKs, like CI
// runners', still build: verdicts then report themselves unavailable.
#if canImport(FoundationModels, _version: 2.0)
    import FoundationModels
#endif

/// Keep/delete verdicts for photos.
public protocol Judge: Sendable {
    /// Why verdicts can't run on this Mac, or nil. Checked once at startup.
    func unavailableReason() -> String?
    /// nil: couldn't judge (no local image, a model error); retried after a restart.
    func judge(_ photo: Photo) async -> Verdict?
}

/// Apple's on-device Foundation Models, given the photo and its date. Vision's isUtility gates
/// it first: anything else gets kind "picture" (keep) without asking the model.
public struct FoundationModelsJudge: Judge {
    let library: PhotoKitLibrary

    public init(library: PhotoKitLibrary) { self.library = library }

    public func unavailableReason() -> String? {
        #if !canImport(FoundationModels, _version: 2.0)
            return "screenshot verdicts need a build made with the macOS 27 SDK"
        #else
        guard #available(macOS 27.0, *) else { return "screenshot verdicts need macOS 27 or later with Apple Intelligence on" }
        guard case .available = SystemLanguageModel.default.availability else {
            return "Foundation Models unavailable: \(SystemLanguageModel.default.availability)"
        }
        return nil
        #endif
    }

    public func judge(_ photo: Photo) async -> Verdict? {
        #if !canImport(FoundationModels, _version: 2.0)
            return nil
        #else
        guard #available(macOS 27.0, *) else { return nil }
        guard let asset = library.assets([photo.uuid])[photo.uuid],
            let img = try? await offload({ library.cgImage(asset, maxSide: 1024) }) ?? nil
        else { return nil }
        guard let vision = analyse(img) else { return nil }
        guard vision.utility else { return Verdict(keep: true, kind: "picture", reason: "Not a utility image") }
        return try? await Model.verdict(image: img, taken: photo.date)
        #endif
    }
}

#if canImport(FoundationModels, _version: 2.0)
@available(macOS 27.0, *)
enum Model {
    @Generable
    enum Kind: String {
        case receipt, ticket, tracking, promo, document, notes, screenshot, meme, label, other
    }

    // Field order is generation order: describing the image first keeps the decision from
    // being made before the model has looked, and the reason from being a rationalisation.
    @Generable
    struct Answer {
        @Guide(description: "What the image is")
        var kind: Kind
        @Guide(description: "What the image shows, under 15 words. Do not say keep or delete.")
        var summary: String
        @Guide(description: "true if the owner would still want this photo today")
        var keep: Bool
    }

    static let instructions = """
        You review utility photos (receipts, tickets, screenshots, documents) in someone's \
        photo library and decide whether each is still worth keeping. Expired tickets, \
        paid receipts for small purchases, memes and stale chat or app screenshots are \
        usually not worth keeping. Warranties, IDs, serial numbers, passwords, handwritten \
        notes and anything still in the future usually are.
        """
    // Spike (d3de461): deletes were only reliable on these kinds; labels, notes and documents
    // are often keepsakes the model calls "expired".
    static let deletable: Set<Kind> = [.receipt, .ticket, .tracking, .promo, .screenshot, .meme]

    static func day(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }

    static func verdict(image: CGImage, taken: Date?) async throws -> Verdict {
        let session = LanguageModelSession(instructions: instructions)
        let today = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
        let a = try await session.respond(
            generating: Answer.self, options: GenerationOptions(samplingMode: .greedy)
        ) {
            "Today is \(today). This photo was taken on \(day(taken))."
            Attachment(image)
        }.content
        return Verdict(keep: a.keep || !deletable.contains(a.kind), kind: a.kind.rawValue, reason: a.summary)
    }
}
#endif
