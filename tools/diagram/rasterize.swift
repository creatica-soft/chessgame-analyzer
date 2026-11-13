// Renders every piece SVG (and the chess glyphs of a few system fonts) to 128×128 PNGs with alpha.
import AppKit

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let size = 128
let fm = FileManager.default

func savePNG(_ draw: (CGContext) -> Void, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for set in try fm.contentsOfDirectory(atPath: src.path).sorted() where !set.hasPrefix(".") {
    let out = dst.appendingPathComponent(set)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    for file in try fm.contentsOfDirectory(atPath: src.appendingPathComponent(set).path) where file.hasSuffix(".svg") {
        guard let image = NSImage(contentsOf: src.appendingPathComponent(set).appendingPathComponent(file)) else {
            print("cannot read \(set)/\(file)"); continue
        }
        savePNG({ _ in image.draw(in: NSRect(x: 0, y: 0, width: size, height: size)) },
                to: out.appendingPathComponent(file.replacingOccurrences(of: ".svg", with: ".png")))
    }
}

// Font glyphs: the outline (white) symbols filled white, the solid (black) ones black.
let names = ["K", "Q", "R", "B", "N", "P"]
let white = Array("♔♕♖♗♘♙"), black = Array("♚♛♜♝♞♟")
for family in ["Apple Symbols", "Arial Unicode MS", "Menlo", "STIX Two Math"] {
    let out = dst.appendingPathComponent("font-" + family.replacingOccurrences(of: " ", with: "-"))
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    for (i, n) in names.enumerated() {
        for (color, glyph) in [("w", white[i]), ("b", black[i])] {
            savePNG({ ctx in
                let font = NSFont(name: family, size: 100) ?? NSFont.systemFont(ofSize: 100)
                let s = NSAttributedString(string: String(glyph), attributes: [.font: font, .foregroundColor: NSColor.black])
                let b = s.boundingRect(with: NSSize(width: 400, height: 400), options: [.usesDeviceMetrics])
                let scale = 0.88 * Double(size) / max(b.width, b.height)
                ctx.translateBy(x: Double(size) / 2, y: Double(size) / 2)
                ctx.scaleBy(x: scale, y: scale)
                // White pieces: fill the solid glyph white, then draw the outline glyph on top.
                if color == "w" {
                    let solid = NSAttributedString(string: String(black[i]), attributes: [.font: font, .foregroundColor: NSColor.white])
                    let sb = solid.boundingRect(with: NSSize(width: 400, height: 400), options: [.usesDeviceMetrics])
                    solid.draw(at: NSPoint(x: -sb.midX, y: -sb.midY))
                }
                s.draw(at: NSPoint(x: -b.midX, y: -b.midY))
            }, to: out.appendingPathComponent("\(color)\(n).png"))
        }
    }
}
print("done")
