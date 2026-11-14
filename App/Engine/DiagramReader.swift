import CoreImage
import CoreML
import UIKit
import Vision

/// Reads a chess diagram from a picture: a printed book diagram, or a board on a screen.
///
/// The board is found as a rectangle, straightened, and cut into 64 squares, each classified by a
/// small network (SquareClassifier) trained on synthetic diagrams in many piece styles. The cut
/// must match the training data's exactly; see `Geometry` and tools/diagram/gen.py.
enum DiagramReader {
    /// How the straightened board is cut, shared with the training data.
    enum Geometry {
        /// Pixels per square on the straightened board.
        static let square = 24.0
        /// Board margin kept around the board when straightening, in squares.
        static let margin = 0.25
        /// Extra around each square when cutting it out, in squares.
        static let cellMargin = 0.15
        /// The classifier's input: cell x cell grey pixels.
        static let cell = 32
        static var boardPixels: Int { Int(((8 + 2 * margin) * square).rounded()) }
    }

    /// The board's corners in the upright image, in pixels from the top left.
    struct Quad: Sendable, Equatable {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomRight: CGPoint
        var bottomLeft: CGPoint

        var center: CGPoint {
            CGPoint(x: (topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4,
                    y: (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4)
        }

        /// The same four points named by where they are: clockwise round their centre (on screen,
        /// y down), starting from the one nearest the top left. Corners set by hand may have been
        /// dragged past one another, which would read the board mirrored.
        var ordered: Quad {
            let c = center
            let points = [topLeft, topRight, bottomRight, bottomLeft]
                .sorted { atan2($0.y - c.y, $0.x - c.x) < atan2($1.y - c.y, $1.x - c.x) }
            let first = points.indices.min { points[$0].x + points[$0].y < points[$1].x + points[$1].y }!
            let p = (0..<4).map { points[(first + $0) % 4] }
            return Quad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
        }

        /// Scaled about its centre.
        func scaled(_ f: Double) -> Quad {
            let c = center
            func s(_ p: CGPoint) -> CGPoint { CGPoint(x: c.x + (p.x - c.x) * f, y: c.y + (p.y - c.y) * f) }
            return Quad(topLeft: s(topLeft), topRight: s(topRight), bottomRight: s(bottomRight), bottomLeft: s(bottomLeft))
        }
    }

    struct Reading: @unchecked Sendable {
        /// libchess order: a1 = 0, h8 = 63.
        var pieces: [Piece?]
        /// Whether the classifier was unsure of each square, same order.
        var uncertain: [Bool]
        /// The straightened board as it was read, top row first, for comparing with the result.
        var board: CGImage
        var quad: Quad
        /// Black was at the bottom of the diagram; the pieces are already turned round.
        var flipped: Bool
        /// The whole picture, upright, that `quad` is in: for setting the corners by hand.
        var photo: CGImage? = nil
        /// A printed or screen diagram, or a photo of a real board (see `BoardReader`).
        var kind: Kind = .diagram

        enum Kind: Sendable { case diagram, board }

        /// Squares the classifier was unsure of, for the user to check.
        var doubtful: [Square] { uncertain.indices.filter { uncertain[$0] } }
    }

    /// Whether a square's reading needs checking: another reading is a real rival to the best, or
    /// the best is under even odds. Not a low best alone: on photos of screens, an empty square
    /// often comes out at 75% empty with the rest spread thinly over every piece, which is no
    /// doubt about what it holds. (On synthetic boards this outlines a sixth fewer squares than
    /// "best under 80%" and still catches 78% of the mistakes, against 82%.)
    static func isDoubtful(_ p: [Double]) -> Bool {
        var first = 0.0, second = 0.0
        for v in p {
            if v > first { second = first; first = v } else if v > second { second = v }
        }
        return first < 0.5 || second > 0.1 * first
    }

    enum ReadError: LocalizedError {
        case noImage, noBoard, model(String)

        var errorDescription: String? {
            switch self {
            case .noImage: "The picture could not be read."
            case .noBoard: "No chess board was found in the picture. Try a closer picture with the whole board in it, straight on."
            case .model(let message): "The diagram could not be read: \(message)"
            }
        }
    }

    /// The order of the classifier's outputs.
    static let classes: [Piece?] = [nil,
        Piece(.white, .pawn), Piece(.white, .knight), Piece(.white, .bishop), Piece(.white, .rook), Piece(.white, .queen), Piece(.white, .king),
        Piece(.black, .pawn), Piece(.black, .knight), Piece(.black, .bishop), Piece(.black, .rook), Piece(.black, .queen), Piece(.black, .king)]

    static func read(_ image: UIImage) async throws -> Reading {
        guard let upright = upright(image) else { throw ReadError.noImage }
        return try await Task.detached(priority: .userInitiated) { try read(upright) }.value
    }

    /// The board inside corners set by hand, in an upright picture.
    static func read(_ image: CGImage, corners: Quad) async throws -> Reading {
        let quad = corners.ordered
        return try await Task.detached(priority: .userInitiated) { try read(image, quad: quad) }.value
    }

    /// Where the corners start when no board was found: a square in the middle of the picture.
    static func defaultCorners(in image: CGImage) -> Quad {
        let w = Double(image.width), h = Double(image.height), side = min(w, h) * 0.7
        let x = (w - side) / 2, y = (h - side) / 2
        return Quad(topLeft: CGPoint(x: x, y: y), topRight: CGPoint(x: x + side, y: y),
                    bottomRight: CGPoint(x: x + side, y: y + side), bottomLeft: CGPoint(x: x, y: y + side))
    }

    /// The whole reading, on an upright image.
    static func read(_ image: CGImage, quad given: Quad? = nil) throws -> Reading {
        let candidates = given.map { [$0] } ?? findBoards(in: image)
        let model = try classifier()
        var best: (board: Board, cells: MLMultiArray, probabilities: [[Double]], quad: Quad, score: Double)?
        // A cut is scored by how sure the classifier is of its squares and by how much it looks
        // like a board: light and dark squares alternating.
        func consider(_ quads: [Quad], fit: Bool = true) throws {
            for quad in quads {
                // The rectangle found may be a frame or a panel around the board: fit the board's
                // grid inside it, and keep the rectangle itself as a fallback.
                let tries = given != nil || !fit ? [quad] : [fitGrid(image, quad), quad].compactMap { $0 }
                for q in tries {
                    guard let board = straighten(image, q) else { continue }
                    let squares = cells(of: board)
                    let probabilities = try classify(squares, model: model)
                    let confidence = probabilities.map { $0.max() ?? 0 }.reduce(0, +) / 64
                    let score = confidence + 2 * max(0, alternation(squares, probabilities))
                    if best == nil || score > best!.score {
                        best = (board, squares, probabilities, q, score)
                    }
                }
            }
        }
        try consider(candidates)
        // No rectangle read well: the board's outline may be too faint to find, or the rectangle
        // was another board, cut off by the edge of the picture. Look for the pattern instead.
        let doubtful = best.map { $0.probabilities.filter { ($0.max() ?? 0) < 0.8 }.count } ?? 64
        if given == nil, doubtful >= 4, let found = findCheckerboard(in: image) {
            try consider([found])
        }
        // A box found by its pattern can be a whole square off: the light and dark squares carry
        // on into a margin, or a row of coordinates is taken for a rank. Try it moved a square
        // each way: the board itself reads best.
        if given == nil, let found = best {
            let h = Homography(found.quad)
            let shifts = [(-1, 0), (1, 0), (0, -1), (0, 1)].map { (dx, dy) -> Quad in
                let u = Double(dx) / 8, v = Double(dy) / 8
                return Quad(topLeft: h.map(u, v), topRight: h.map(1 + u, v),
                            bottomRight: h.map(1 + u, 1 + v), bottomLeft: h.map(u, 1 + v))
            }
            try consider(shifts, fit: false)
        }
        guard let best else { throw ReadError.noBoard }
        var reading = assemble(refine(best.probabilities, cells: best.cells), board: best.board.image, quad: best.quad)
        reading.photo = image
        return reading
    }

    // MARK: - Finding the board

    /// The picture drawn upright, at most 2000 pixels on its longer side.
    static func upright(_ image: UIImage) -> CGImage? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        let scale = min(1, 2000 / max(longest, 1))
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(),
                          height: (image.size.height * image.scale * scale).rounded())
        guard size.width >= 64, size.height >= 64 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Square-ish rectangles in the picture, the likeliest board first.
    static func findBoards(in image: CGImage) -> [Quad] {
        let request = VNDetectRectanglesRequest()
        // Loose: a board photographed at an angle is a trapezoid, far from square in the picture.
        // Which candidate is the board is decided by reading them (see `read`).
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1
        request.quadratureTolerance = 45
        request.minimumConfidence = 0.3
        request.maximumObservations = 12
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let w = Double(image.width), h = Double(image.height)
        let quads = (request.results ?? []).map { o -> (Quad, Double) in
            // Vision: normalised, origin at the bottom left.
            func p(_ v: CGPoint) -> CGPoint { CGPoint(x: v.x * w, y: (1 - v.y) * h) }
            let q = Quad(topLeft: p(o.topLeft), topRight: p(o.topRight), bottomRight: p(o.bottomRight), bottomLeft: p(o.bottomLeft))
            let width = hypot(q.topRight.x - q.topLeft.x, q.topRight.y - q.topLeft.y)
            let height = hypot(q.bottomLeft.x - q.topLeft.x, q.bottomLeft.y - q.topLeft.y)
            let squareness = min(width, height) / max(width, height, 1)
            return (q, width * height * squareness.squareRoot() * Double(o.confidence))
        }
        // The likeliest few: a frame and the board inside it are often both found, and at an
        // angle the board may not be the likeliest-looking rectangle.
        var found = quads.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
        // A picture cropped to the board (a screenshot, or a scan cropped to it) has its edges at
        // the picture's edges, where no rectangle is found: try the whole picture too.
        if min(w, h) / max(w, h) > 0.8 {
            found.append(Quad(topLeft: .zero, topRight: CGPoint(x: w, y: 0),
                              bottomRight: CGPoint(x: w, y: h), bottomLeft: CGPoint(x: 0, y: h)))
        }
        return found
    }

    // MARK: - Fitting the grid

    /// Scores square boxes in a grey picture by how strongly they look like an 8x8 board: light
    /// and dark squares alternating. A square's colour shows in its corners, where pieces rarely
    /// reach: each square is valued by the median of four small patches near its corners, and
    /// light and dark squares are compared by medians, so a piece in a corner here and there does
    /// not count. Only a box on the real squares alternates: one that takes in a frame or panel,
    /// is a fraction of a square off, or runs past the edge of a board, mixes light and dark.
    struct CheckerSearch {
        let width: Int, height: Int
        private var integral: [Double]
        private var light = [Double](repeating: 0, count: 32), dark = [Double](repeating: 0, count: 32)
        var patchFrom = 0.08, patchTo = 0.26

        init(pixels: [UInt8], width: Int, height: Int) {
            self.width = width
            self.height = height
            var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
            pixels.withUnsafeBufferPointer { px in
                for y in 0..<height {
                    var row = 0.0
                    for x in 0..<width {
                        row += Double(px[y * width + x])
                        integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + row
                    }
                }
            }
            self.integral = integral
        }

        mutating func score(_ bx: Double, _ by: Double, _ size: Double) -> Double {
            let cell = size / 8
            let p0 = cell * patchFrom, p1 = cell * patchTo
            guard bx >= 0, by >= 0, bx + size <= Double(width), by + size <= Double(height), p1 - p0 >= 1 else { return 0 }
            let stride = width + 1
            var nl = 0, nd = 0
            let w = Double(width), h = Double(height)
            // The value of the square at row r, column c of the box (outside it too); nil when
            // that square is not wholly in the picture.
            func square(_ ii: UnsafeBufferPointer<Double>, _ r: Int, _ c: Int) -> Double? {
                let x = bx + Double(c) * cell, y = by + Double(r) * cell
                guard x >= 0, y >= 0, x + cell <= w, y + cell <= h else { return nil }
                @inline(__always) func patch(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
                    let a0 = Int(x0), a1 = max(Int(x1), a0 + 1), b0 = Int(y0), b1 = max(Int(y1), b0 + 1)
                    let sum = ii[b1 * stride + a1] - ii[b0 * stride + a1] - ii[b1 * stride + a0] + ii[b0 * stride + a0]
                    return sum / Double((a1 - a0) * (b1 - b0))
                }
                let a = patch(x + p0, y + p0, x + p1, y + p1)
                let b = patch(x + cell - p1, y + p0, x + cell - p0, y + p1)
                let d = patch(x + p0, y + cell - p1, x + p1, y + cell - p0)
                let e = patch(x + cell - p1, y + cell - p1, x + cell - p0, y + cell - p0)
                // The median of four: drop the largest and smallest.
                return (a + b + d + e - max(max(a, b), max(d, e)) - min(min(a, b), min(d, e))) / 2
            }
            var continuation = 0.0
            integral.withUnsafeBufferPointer { ii in
                for r in 0..<8 {
                    for c in 0..<8 {
                        let m = square(ii, r, c)!
                        if (r + c) % 2 == 0 { light[nl] = m; nl += 1 } else { dark[nd] = m; nd += 1 }
                    }
                }
                light.sort(); dark.sort()
                let ml = (light[15] + light[16]) / 2, md = (dark[15] + dark[16]) / 2
                // A real board's pattern stops at its edges. A box cut through a board, or across
                // two boards close together, has the pattern carry on past a side: measure how
                // far it does, side by side, in the squares beyond the box. Only next to the box:
                // boards printed or shown close together are often less than a square apart, and
                // the far half of the square beyond a real board's edge is then the next board.
                let mid = (ml + md) / 2, half = (ml - md) / 2
                guard abs(half) > 1 else { return }
                @inline(__always) func patch(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
                    let a0 = Int(x0), a1 = max(Int(x1), a0 + 1), b0 = Int(y0), b1 = max(Int(y1), b0 + 1)
                    let sum = ii[b1 * stride + a1] - ii[b0 * stride + a1] - ii[b1 * stride + a0] + ii[b0 * stride + a0]
                    return sum / Double((a1 - a0) * (b1 - b0))
                }
                // The square beyond `side` at row r, column c, by its two corners next to the box.
                func beyond(_ side: Int, _ r: Int, _ c: Int) -> Double? {
                    let x = bx + Double(c) * cell, y = by + Double(r) * cell
                    guard x >= 0, y >= 0, x + cell <= w, y + cell <= h else { return nil }
                    let near0 = p0, near1 = p1, far0 = cell - p1, far1 = cell - p0
                    switch side {
                    case 0:  // above: its bottom corners
                        return (patch(x + near0, y + far0, x + near1, y + far1) + patch(x + far0, y + far0, x + far1, y + far1)) / 2
                    case 1:  // below: its top corners
                        return (patch(x + near0, y + near0, x + near1, y + near1) + patch(x + far0, y + near0, x + far1, y + near1)) / 2
                    case 2:  // left: its right corners
                        return (patch(x + far0, y + near0, x + far1, y + near1) + patch(x + far0, y + far0, x + far1, y + far1)) / 2
                    default: // right: its left corners
                        return (patch(x + near0, y + near0, x + near1, y + near1) + patch(x + near0, y + far0, x + near1, y + far1)) / 2
                    }
                }
                for side in 0..<4 {
                    var sum = 0.0, count = 0
                    for k in 0..<8 {
                        let (r, c) = [(-1, k), (8, k), (k, -1), (k, 8)][side]
                        guard let v = beyond(side, r, c) else { continue }
                        let expectedLight = (r + c + 16) % 2 == 0
                        sum += max(-1.5, min(1.5, (v - mid) / half * (expectedLight ? 1 : -1)))
                        count += 1
                    }
                    if count >= 4 { continuation = max(continuation, sum / Double(count)) }
                }
            }
            let ml = (light[15] + light[16]) / 2, md = (dark[15] + dark[16]) / 2
            // Spread: the mean distance from the median.
            var sl = 0.0, sd = 0.0
            for i in 0..<32 { sl += abs(light[i] - ml); sd += abs(dark[i] - md) }
            return abs(ml - md) / ((sl + sd) / 32 + 5) * max(0, 1 - continuation)
        }

        /// The best square box with a side from `minSize` to `maxSize`: every `step` pixels, then
        /// finer round the best.
        mutating func best(minSize: Double, maxSize: Double, step: Double) -> (score: Double, x: Double, y: Double, size: Double) {
            var best = (score: 0.0, x: 0.0, y: 0.0, size: 0.0)
            var size = minSize
            while size <= maxSize {
                var y = 0.0
                while y + size <= Double(height) {
                    var x = 0.0
                    while x + size <= Double(width) {
                        let s = score(x, y, size)
                        if s > best.score { best = (s, x, y, size) }
                        x += step
                    }
                    y += step
                }
                size += step
            }
            var reach = step
            while reach >= 1 {
                let fine = max(1, reach / 4)
                let centre = best
                for ds in Swift.stride(from: -reach, through: reach, by: fine) {
                    for dy in Swift.stride(from: -reach, through: reach, by: fine) {
                        for dx in Swift.stride(from: -reach, through: reach, by: fine) {
                            let s = score(centre.x + dx, centre.y + dy, centre.size + ds)
                            if s > best.score { best = (s, centre.x + dx, centre.y + dy, centre.size + ds) }
                        }
                    }
                }
                reach = fine == 1 && reach == 1 ? 0 : fine
            }
            return best
        }
    }

    /// Light and dark squares must differ for a box to be taken for a board. Faintly: in a photo of
    /// a screen, finely hatched dark squares come out barely darker than the light ones (about
    /// 0.75 to 0.9), while pictures of text without a board stay under 0.6. Whichever boxes pass
    /// are then compared by how they read (see `read`).
    static let boardLikeScore = 0.7

    /// The board inside `quad`: the square box in it (straightened) that alternates most
    /// strongly. nil when nothing alternates, as on a board without shaded squares.
    static func fitGrid(_ image: CGImage, _ quad: Quad) -> Quad? {
        // Straighten the rectangle with a little extra round it, in case the board is larger.
        let outer = quad.scaled(1.06)
        let n = 320
        guard let picture = straightenRaw(image, outer, size: n) else { return nil }
        var search = CheckerSearch(pixels: picture, width: n, height: n)
        let best = search.best(minSize: Double(n) * 0.6, maxSize: Double(n), step: 8)
        guard best.score > boardLikeScore else { return nil }
        let h = Homography(outer)
        let k = Double(n)
        let u0 = best.x / k, v0 = best.y / k, u1 = (best.x + best.size) / k, v1 = (best.y + best.size) / k
        return Quad(topLeft: h.map(u0, v0), topRight: h.map(u1, v0), bottomRight: h.map(u1, v1), bottomLeft: h.map(u0, v1))
    }

    /// A board found by its pattern alone, anywhere in the picture: the square box in the whole
    /// picture (shrunk) that alternates most strongly. For when no rectangle found is the board:
    /// its outline faint, or another board's taken for it.
    static func findCheckerboard(in image: CGImage) -> Quad? {
        let longest = 360.0
        let k = longest / Double(max(image.width, image.height))
        let w = Int((Double(image.width) * k).rounded()), h = Int((Double(image.height) * k).rounded())
        guard w >= 64, h >= 64 else { return nil }
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(CIImage(cgImage: image).clampedToExtent(), forKey: kCIInputImageKey)
        lanczos.setValue(k, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let small = lanczos.outputImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            // Core Image's origin is the bottom left; this renders the rows top first.
            context.render(small, toBitmap: buffer.baseAddress!, rowBytes: w,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        var search = CheckerSearch(pixels: pixels, width: w, height: h)
        let side = Double(min(w, h))
        let best = search.best(minSize: side * 0.25, maxSize: side, step: 6)
        guard best.score > boardLikeScore else { return nil }
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / k, y: y / k) }
        return Quad(topLeft: p(best.x, best.y), topRight: p(best.x + best.size, best.y),
                    bottomRight: p(best.x + best.size, best.y + best.size), bottomLeft: p(best.x, best.y + best.size))
    }

    /// The projective map from the unit square to a quad: (0,0) to its top left, (1,0) to its top
    /// right, (1,1) to its bottom right, (0,1) to its bottom left.
    struct Homography {
        let a, b, c, d, e, f, g, h: Double

        init(_ q: Quad) {
            let (x0, y0) = (q.topLeft.x, q.topLeft.y), (x1, y1) = (q.topRight.x, q.topRight.y)
            let (x2, y2) = (q.bottomRight.x, q.bottomRight.y), (x3, y3) = (q.bottomLeft.x, q.bottomLeft.y)
            let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
            let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
            let den = dx1 * dy2 - dx2 * dy1
            let g = abs(den) < 1e-9 ? 0 : (dx3 * dy2 - dx2 * dy3) / den
            let h = abs(den) < 1e-9 ? 0 : (dx1 * dy3 - dx3 * dy1) / den
            self.g = g; self.h = h
            a = x1 - x0 + g * x1; b = x3 - x0 + h * x3; c = x0
            d = y1 - y0 + g * y1; e = y3 - y0 + h * y3; f = y0
        }

        func map(_ u: Double, _ v: Double) -> CGPoint {
            let w = g * u + h * v + 1
            return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
        }
    }

    // MARK: - Cutting

    /// The straightened board in grey, `Geometry.boardPixels` square, top row first.
    struct Board {
        var pixels: [UInt8]
        var size: Int
        var image: CGImage
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func straighten(_ image: CGImage, _ quad: Quad) -> Board? {
        let n = Geometry.boardPixels
        guard let pixels = straightenRaw(image, quad.scaled((8 + 2 * Geometry.margin) / 8), size: n) else { return nil }
        let grey = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                               space: grey, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return Board(pixels: pixels, size: n, image: cg)
    }

    /// The picture inside `q`, straightened to size x size grey pixels, top row first.
    static func straightenRaw(_ image: CGImage, _ q: Quad, size n: Int) -> [UInt8]? {
        let h = Double(image.height)
        // Core Image's origin is the bottom left.
        func ci(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: h - p.y) }
        let filter = CIFilter(name: "CIPerspectiveCorrection")!
        // The margin around a board cropped exactly lies outside the picture: continue the edge
        // pixels outwards rather than leave it black, which no diagram looks like.
        filter.setValue(CIImage(cgImage: image).clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(ci(q.topLeft), forKey: "inputTopLeft")
        filter.setValue(ci(q.topRight), forKey: "inputTopRight")
        filter.setValue(ci(q.bottomRight), forKey: "inputBottomRight")
        filter.setValue(ci(q.bottomLeft), forKey: "inputBottomLeft")
        guard let corrected = filter.outputImage, corrected.extent.width > 8, corrected.extent.height > 8,
              corrected.extent.width.isFinite, corrected.extent.height.isFinite else { return nil }
        // Shrinking a photo several times over without filtering folds fine regular texture (a
        // screen's pixel grid, paper grain) into coarse false stripes. Lanczos filters as it
        // scales. The edges are extended first so the filter does not darken the border.
        let width = corrected.extent.width, height = corrected.extent.height
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(corrected.transformed(by: CGAffineTransform(translationX: -corrected.extent.minX,
                                                                      y: -corrected.extent.minY)).clampedToExtent(),
                         forKey: kCIInputImageKey)
        lanczos.setValue(Double(n) / height, forKey: kCIInputScaleKey)
        lanczos.setValue(height / width, forKey: kCIInputAspectRatioKey)
        guard let scaled = lanczos.outputImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: n * n)
        let grey = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buffer in
            context.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: n,
                           bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .L8, colorSpace: grey)
        }
        return pixels
    }

    /// The 64 squares, top row first and left to right, as the classifier's input: each square
    /// with a margin, resampled bilinearly to cell x cell, values 0...255.
    static func cells(of board: Board) -> MLMultiArray {
        let c = Geometry.cell
        let array = try! MLMultiArray(shape: [64, 1, NSNumber(value: c), NSNumber(value: c)], dataType: .float32)
        let out = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let n = board.size
        let span = (1 + 2 * Geometry.cellMargin) * Geometry.square
        let step = span / Double(c)
        board.pixels.withUnsafeBufferPointer { px in
            func at(_ x: Int, _ y: Int) -> Double {
                Double(px[min(max(y, 0), n - 1) * n + min(max(x, 0), n - 1)])
            }
            for row in 0..<8 {
                for col in 0..<8 {
                    let left = (Geometry.margin + Double(col) - Geometry.cellMargin) * Geometry.square
                    let top = (Geometry.margin + Double(row) - Geometry.cellMargin) * Geometry.square
                    let base = (row * 8 + col) * c * c
                    for v in 0..<c {
                        // Pixel centres, as PIL's resize maps them.
                        let sy = top + (Double(v) + 0.5) * step - 0.5
                        let y0 = Int(sy.rounded(.down)), fy = sy - Double(y0)
                        for u in 0..<c {
                            let sx = left + (Double(u) + 0.5) * step - 0.5
                            let x0 = Int(sx.rounded(.down)), fx = sx - Double(x0)
                            let value = at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy)
                                + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy
                            out[base + v * c + u] = Float32(value)
                        }
                    }
                }
            }
        }
        return array
    }

    // MARK: - Classifying

    nonisolated(unsafe) private static var cachedModel: MLModel?
    private static let modelLock = NSLock()

    static func classifier() throws -> MLModel {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cachedModel { return cachedModel }
        guard let url = Bundle.main.url(forResource: "SquareClassifier", withExtension: "mlmodelc") else {
            throw ReadError.model("the classifier is missing from the app")
        }
        do {
            let model = try MLModel(contentsOf: url)
            cachedModel = model
            return model
        } catch {
            throw ReadError.model(error.localizedDescription)
        }
    }

    /// Per square (top row first), the probability of each class.
    static func classify(_ cells: MLMultiArray, model: MLModel) throws -> [[Double]] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["squares": MLFeatureValue(multiArray: cells)])
        guard let out = try model.prediction(from: input).featureValue(for: "probabilities")?.multiArrayValue else {
            throw ReadError.model("no output")
        }
        let k = classes.count
        return (0..<64).map { i in (0..<k).map { out[[NSNumber(value: i), NSNumber(value: $0)]].doubleValue } }
    }

    /// How much the cut looks like a chessboard: the light squares' centres brighter than the
    /// dark squares', 0...1 of the grey range. Empty squares show it best; a cut that is too
    /// small or misaligned shows none.
    static func alternation(_ cells: MLMultiArray, _ probabilities: [[Double]]) -> Double {
        let c = Geometry.cell
        let data = cells.dataPointer.assumingMemoryBound(to: Float32.self)
        let lo = c / 2 - c / 6, hi = c / 2 + c / 6
        func centre(_ i: Int) -> Double {
            var sum = 0.0
            for y in lo..<hi { for x in lo..<hi { sum += Double(data[i * c * c + y * c + x]) } }
            return sum / Double((hi - lo) * (hi - lo))
        }
        let empty = Set((0..<64).filter { i in
            let p = probabilities[i]
            return (p.indices.max { p[$0] < p[$1] } ?? 0) == 0
        })
        func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
        let use = { (light: Bool) -> [Int] in
            let squares = (0..<64).filter { ($0 / 8 + $0 % 8) % 2 == (light ? 0 : 1) }
            let emptyOnes = squares.filter(empty.contains)
            return emptyOnes.count >= 4 ? emptyOnes : squares
        }
        guard let light = median(use(true).map(centre)), let dark = median(use(false).map(centre)) else { return 0 }
        return (light - dark) / 255
    }

    // MARK: - What a diagram must be

    /// Corrects the classifier with what is known about diagrams: the same piece on the same
    /// square colour is printed identically, so squares that look the same get the same answer;
    /// no pawn stands on the first or last rank; each side has exactly one king.
    static func refine(_ probabilities: [[Double]], cells: MLMultiArray) -> [[Double]] {
        var p = probabilities
        // Identical squares: the same picture read several times, so the readings add up (their
        // probabilities multiply). A mean would let one unsure reading pull a sure one down.
        for group in identicalGroups(cells) where group.count > 1 {
            var logs = [Double](repeating: 0, count: classes.count)
            for i in group { for k in logs.indices { logs[k] += log(max(p[i][k], 1e-6)) } }
            let top = logs.max() ?? 0
            let combined = logs.map { exp($0 - top) }
            let sum = combined.reduce(0, +)
            for i in group { p[i] = combined.map { $0 / sum } }
        }
        return constrain(p)
    }

    /// Corrects any reading of a board, printed or real, with the rules of the position: no pawn
    /// stands on the first or last rank; each side has exactly one king. Rows of 8 squares, the
    /// first and last being the edge ranks (either side at the bottom).
    static func constrain(_ probabilities: [[Double]]) -> [[Double]] {
        var p = probabilities
        // No pawns on the top or bottom row, whichever side is at the bottom.
        for i in 0..<64 where i / 8 == 0 || i / 8 == 7 {
            for k in classes.indices where classes[k]?.kind == .pawn { p[i][k] = 0 }
        }
        // One king each.
        for color in [PieceColor.white, .black] {
            guard let king = classes.firstIndex(of: Piece(color, .king)) else { continue }
            let best = { (i: Int) in p[i].indices.max { p[i][$0] < p[i][$1] } ?? 0 }
            let kings = (0..<64).filter { best($0) == king }
            if kings.isEmpty {
                // The likeliest king among the squares that hold some piece.
                if let i = (0..<64).filter({ best($0) != 0 }).max(by: { p[$0][king] < p[$1][king] }), p[i][king] > 0.01 {
                    // The king, with what the square was read as kept as a rival: it was a guess,
                    // and is shown as doubtful.
                    let read = best(i)
                    p[i] = p[i].indices.map { $0 == king ? 0.79 : $0 == read ? 0.21 : 0 }
                }
            } else if kings.count > 1 {
                let keep = kings.max { p[$0][king] < p[$1][king] }!
                for i in kings where i != keep { p[i][king] = 0 }
            }
        }
        // Renormalise what was zeroed.
        return p.map { row in
            let sum = row.reduce(0, +)
            return sum > 0 ? row.map { $0 / sum } : row
        }
    }

    /// Groups of squares on the same square colour whose pictures are practically identical.
    static func identicalGroups(_ cells: MLMultiArray) -> [[Int]] {
        let c = Geometry.cell
        let data = cells.dataPointer.assumingMemoryBound(to: Float32.self)
        // The square itself, without the margin that shows its neighbours.
        let inset = Int((Double(c) * Geometry.cellMargin / (1 + 2 * Geometry.cellMargin)).rounded()) + 1
        func difference(_ a: Int, _ b: Int) -> Double {
            var best = Double.infinity
            for dy in -1...1 {
                for dx in -1...1 {
                    var sum = 0.0, n = 0
                    for y in inset..<(c - inset) {
                        for x in inset..<(c - inset) {
                            let va = Double(data[a * c * c + y * c + x])
                            let vb = Double(data[b * c * c + (y + dy) * c + (x + dx)])
                            sum += abs(va - vb); n += 1
                        }
                    }
                    best = min(best, sum / Double(n))
                }
            }
            return best
        }
        // Union-find over pairs that match.
        var parent = Array(0..<64)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        for a in 0..<64 {
            for b in (a + 1)..<64 where (a / 8 + a % 8) % 2 == (b / 8 + b % 8) % 2 {
                if difference(a, b) < 7 { parent[root(b)] = root(a) }
            }
        }
        return Dictionary(grouping: 0..<64, by: root).values.map { $0.sorted() }
    }

    // MARK: - The position

    static func assemble(_ probabilities: [[Double]], board: CGImage, quad: Quad) -> Reading {
        var pieces = [Piece?](repeating: nil, count: 64)
        var uncertain = [Bool](repeating: false, count: 64)
        // Top row first, as printed: with White at the bottom, the top row is the 8th rank.
        for i in 0..<64 {
            let p = probabilities[i]
            let best = p.indices.max { p[$0] < p[$1] } ?? 0
            let square = Square.at(file: i % 8, rank: 7 - i / 8)
            pieces[square] = classes[best]
            uncertain[square] = isDoubtful(p)
        }
        var reading = Reading(pieces: pieces, uncertain: uncertain, board: board, quad: quad, flipped: false)
        if looksFlipped(pieces) { reading.turnRound() }
        return reading
    }

    /// Black at the bottom: books print a diagram from Black's side now and then. White's pawns
    /// and king then stand on the upper ranks and Black's on the lower.
    static func looksFlipped(_ pieces: [Piece?]) -> Bool {
        func meanRank(_ color: PieceColor) -> Double? {
            let ranks = pieces.indices.filter {
                guard let p = pieces[$0] else { return false }
                return p.color == color && (p.kind == .pawn || p.kind == .king)
            }.map { Double($0.rank) }
            return ranks.isEmpty ? nil : ranks.reduce(0, +) / Double(ranks.count)
        }
        guard let white = meanRank(.white), let black = meanRank(.black) else { return false }
        return white - black > 2
    }
}

extension DiagramReader.Reading {
    /// The board turned round: the diagram's bottom was Black's side, or was not.
    mutating func turnRound() {
        pieces.reverse()
        uncertain.reverse()
        flipped.toggle()
    }

    /// Castling rights the diagram allows: king and rook on their starting squares. Whether they
    /// have moved and come back, a diagram cannot show.
    var possibleCastling: CastlingRights {
        var rights: CastlingRights = []
        for c in CastlingRights.ordered where pieces[c.king] == Piece(c.piece, .king) && pieces[c.rook] == Piece(c.piece, .rook) {
            rights.insert(c.right)
        }
        return rights
    }

    /// En passant squares the diagram allows with `sideToMove` to play: behind an enemy pawn that
    /// could just have advanced two squares, when a pawn of `sideToMove` stands beside it.
    func possibleEnPassant(sideToMove: PieceColor) -> [Square] {
        let them = sideToMove.opposite
        // The rank the pawn reached, the square it passed, and where it came from.
        let (rank, passed, from) = them == .black ? (4, 5, 6) : (3, 2, 1)
        return (0..<8).compactMap { file -> Square? in
            guard pieces[Square.at(file: file, rank: rank)] == Piece(them, .pawn),
                  pieces[Square.at(file: file, rank: passed)] == nil,
                  pieces[Square.at(file: file, rank: from)] == nil,
                  [file - 1, file + 1].contains(where: { (0..<8).contains($0) && pieces[Square.at(file: $0, rank: rank)] == Piece(sideToMove, .pawn) })
            else { return nil }
            return Square.at(file: file, rank: passed)
        }
    }

    /// The position as the diagram shows it, with what a diagram cannot show given: who is to
    /// move, which castling is still allowed, and the en passant square if the last move was a
    /// pawn's double step. Move counters are unknown and start at 0 and 1.
    func position(sideToMove: PieceColor, castling: CastlingRights? = nil, enPassant: Square? = nil) -> Position {
        var position = Position()
        position.edit { $0 = pieces }
        position.sideToMove = sideToMove
        position.castling = (castling ?? possibleCastling).intersection(possibleCastling)
        if let enPassant, possibleEnPassant(sideToMove: sideToMove).contains(enPassant) {
            position.enPassant = enPassant
        }
        return position
    }
}
