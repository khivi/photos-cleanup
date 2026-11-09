// Renders the demo library's images from manifest.json.
//   swift scripts/demo/generate.swift <manifest.json> <fixtures dir> <import sample dir>
// <fixtures dir> gets the manifest and one JPEG per photo; <import sample dir> gets a folder for the Import screen.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Scene: Decodable {
    var kind: String
    var hue: Double?
    var shift: Int?
    var lines: [String]?
}

struct Entry: Decodable {
    var file: String
    var date: String?
    var width: Int
    var height: Int
    var scene: Scene
}

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("usage: generate.swift <manifest.json> <fixtures dir> <import sample dir>") }
let manifest = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2], isDirectory: true)
let sample = URL(fileURLWithPath: args[3], isDirectory: true)
let entries = try JSONDecoder().decode([String: [Entry]].self, from: Data(contentsOf: manifest))["photos"]!

func hsb(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    let h = h - h.rounded(.down)
    let i = Int(h * 6)
    let f = h * 6 - Double(i)
    let (p, q, t) = (b * (1 - s), b * (1 - f * s), b * (1 - (1 - f) * s))
    let rgb = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i % 6]
    return CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: a)
}

func draw(_ s: Scene, _ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let (W, H) = (Double(w), Double(h))
    let hue = s.hue ?? 0.5
    let shift = Double(s.shift ?? 0)
    func fill(_ c: CGColor, _ r: CGRect, round: Double = 0) {
        ctx.setFillColor(c)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: round, cornerHeight: round, transform: nil))
        ctx.fillPath()
    }
    func disc(_ c: CGColor, _ x: Double, _ y: Double, _ r: Double) {
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    func text(_ t: String, _ x: Double, _ y: Double, _ size: Double, _ c: CGColor = hsb(0, 0, 0.1), bold: Bool = false)
    {
        let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo") as CFString, size, nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: c] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, t as CFString, attrs))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
    func scenery(people: Bool = false, food: Bool = false) {
        let g = CGGradient(
            colorsSpace: nil, colors: [hsb(hue, 0.35, 1), hsb(hue + 0.08, 0.7, 0.8)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
        disc(hsb(0.12, 0.5, 1), W * (0.2 + 0.05 * shift), H * 0.78, H * 0.09)
        fill(
            hsb(hue + 0.3, 0.5, 0.45), CGRect(x: -W * 0.2, y: -H * 0.35, width: W * 0.9, height: H * 0.7),
            round: W * 0.4)
        fill(
            hsb(hue + 0.33, 0.6, 0.35), CGRect(x: W * 0.3, y: -H * 0.45, width: W * 0.9, height: H * 0.75),
            round: W * 0.4)
        if people {
            for (i, x) in [0.4, 0.58].enumerated() {
                let cx = W * (x + 0.02 * shift)
                fill(
                    hsb(0.02 + 0.1 * Double(i), 0.6, 0.8),
                    CGRect(x: cx - W * 0.06, y: H * 0.12, width: W * 0.12, height: H * 0.28), round: W * 0.05)
                disc(hsb(0.07, 0.4, 0.95), cx, H * 0.47, H * 0.07)
            }
        }
        if food {
            disc(hsb(0, 0, 0.95), W * (0.5 + 0.03 * shift), H * 0.4, H * 0.3)
            disc(hsb(hue, 0.8, 0.85), W * (0.5 + 0.03 * shift), H * 0.4, H * 0.18)
        }
    }
    func paper(_ title: String) {
        fill(hsb(0.1, 0.1, 0.55), CGRect(x: 0, y: 0, width: W, height: H))
        fill(hsb(0, 0, 0.98), CGRect(x: W * 0.08, y: H * 0.04, width: W * 0.84, height: H * 0.92), round: 6)
        fill(hsb(hue, 0.6, 0.85), CGRect(x: W * 0.08, y: H * 0.86, width: W * 0.84, height: H * 0.1), round: 6)
        text(title, W * 0.12, H * 0.9, W * 0.05, hsb(0, 0, 1), bold: true)
    }
    switch s.kind {
    case "screenshot":
        fill(hsb(hue, 0.08, 0.96), CGRect(x: 0, y: 0, width: W, height: H))
        fill(hsb(hue, 0.7, 0.8), CGRect(x: 0, y: H * 0.88, width: W, height: H * 0.12))
        text("9:41", W * 0.06, H * 0.935, W * 0.045, hsb(0, 0, 1), bold: true)
        for (i, l) in (s.lines ?? []).enumerated() {
            fill(
                hsb(0, 0, 1), CGRect(x: W * 0.06, y: H * (0.68 - 0.2 * Double(i)), width: W * 0.88, height: H * 0.15),
                round: 14)
            text(l, W * 0.1, H * (0.73 - 0.2 * Double(i)), W * 0.06)
        }
    case "receipt", "ticket", "label", "document":
        paper(s.kind.uppercased())
        for (i, l) in (s.lines ?? []).enumerated() {
            text(l, W * 0.12, H * (0.74 - 0.12 * Double(i)), W * 0.05, bold: i == 2)
        }
        for i in 0..<5 {
            fill(
                hsb(0, 0, 0.85),
                CGRect(
                    x: W * 0.12, y: H * (0.34 - 0.05 * Double(i)), width: W * (0.76 - 0.1 * Double(i % 3)), height: 4))
        }
    case "people": scenery(people: true)
    case "food": scenery(food: true)
    case "video":
        scenery()
        disc(hsb(0, 0, 0, 0.55), W / 2, H / 2, H * 0.14)
        ctx.setFillColor(hsb(0, 0, 1))
        ctx.move(to: CGPoint(x: W / 2 - H * 0.05, y: H / 2 - H * 0.08))
        ctx.addLine(to: CGPoint(x: W / 2 - H * 0.05, y: H / 2 + H * 0.08))
        ctx.addLine(to: CGPoint(x: W / 2 + H * 0.09, y: H / 2))
        ctx.fillPath()
    case "dark":
        scenery()
        fill(hsb(0, 0, 0, 0.9), CGRect(x: 0, y: 0, width: W, height: H))
    case "blur":
        // Drawn small and scaled up: the interpolation is the blur.
        let tiny = draw(Scene(kind: "landscape", hue: s.hue, shift: s.shift), max(w / 24, 2), max(h / 24, 2))
        ctx.interpolationQuality = .high
        ctx.draw(tiny, in: CGRect(x: 0, y: 0, width: W, height: H))
    default: scenery()  // landscape, beach, mountain
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL, date: Date?) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
    if let date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"  // the Mac's time zone, as Import reads it
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: f.string(from: date)]
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let iso = ISO8601DateFormatter()
func date(_ e: Entry) -> Date? { e.date.flatMap(iso.date(from:)) }

try? FileManager.default.removeItem(at: out)
try? FileManager.default.removeItem(at: sample)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: manifest, to: out.appending(path: "manifest.json"))
for e in entries { try write(draw(e.scene, e.width, e.height), to: out.appending(path: e.file), date: date(e)) }

// Import sample: copies of library photos (Done), photos the library lacks (Import), one without a camera date (Check date).
let copies = entries.filter { $0.scene.kind == "landscape" && $0.date != nil }
for (i, e) in copies.prefix(2).enumerated() {
    try write(draw(e.scene, e.width, e.height), to: sample.appending(path: "Trip/IMG_\(4001 + i).jpg"), date: date(e))
}
let fresh = [
    ("Trip/IMG_5001.jpg", Scene(kind: "mountain", hue: 0.7, shift: 2), "2019-07-04T10:00:00Z"),
    ("Trip/IMG_5002.jpg", Scene(kind: "beach", hue: 0.45, shift: 1), "2019-07-04T10:05:00Z"),
    ("Scans/old-print.jpg", Scene(kind: "people", hue: 0.9, shift: 1), nil),
]
for (path, scene, d) in fresh {
    try write(draw(scene, 640, 480), to: sample.appending(path: path), date: d.flatMap(iso.date(from:)))
}
try Data("not a photo".utf8).write(to: sample.appending(path: "notes.txt"))
print("demo fixtures: \(entries.count) photos in \(out.path); import sample in \(sample.path)")
