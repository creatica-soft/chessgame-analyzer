import CoreImage
import CoreML
import UIKit

/// Reads a photo of a real chess board: finds the board, then names the piece on each square.
///
/// The board is found by its grid (see `BoardFinder`). Each square is cut out as a tall crop, as
/// wide as the square and reaching about two squares' widths up the picture from its front edge,
/// where a piece standing on it shows; a small network (PieceClassifier, trained in tools/board3d
/// on video of a board) names the piece at the bottom of each crop. The camera is taken to be on
/// White's side: rank 1 is the board edge nearest it, the a-file on its left.
enum BoardReader {
    /// The crops are cut from the photo scaled to this longer side, as the training frames were.
    static let cropSource = 1280.0
    static let cropWidth = 48, cropHeight = 96
    /// Crop width and height, in widths of the square's front edge; and how far below the front
    /// edge it starts. Must match tools/board3d/crops.py.
    static let wide = 1.25, tall = 2.4, below = 0.08

    /// Reads a photo of a board; the board is found automatically.
    static func read(_ image: UIImage) async throws -> DiagramReader.Reading {
        guard let photo = DiagramReader.upright(image) else { throw DiagramReader.ReadError.noImage }
        return try await Task.detached(priority: .userInitiated) { try read(photo) }.value
    }

    /// Reads the board inside corners set by hand (top left, top right, bottom right, bottom left
    /// as seen: a8, h8, h1, a1 from White's side).
    static func read(_ photo: CGImage, corners: DiagramReader.Quad) async throws -> DiagramReader.Reading {
        let quad = corners.ordered
        return try await Task.detached(priority: .userInitiated) { try read(photo, quad: quad) }.value
    }

    static func read(_ photo: CGImage, quad given: DiagramReader.Quad? = nil) throws -> DiagramReader.Reading {
        let scale = cropSource / Double(max(photo.width, photo.height))
        guard let source = RGBImage(photo, scale: min(1, scale)) else { throw DiagramReader.ReadError.noImage }
        let k = Double(source.width) / Double(photo.width)        // photo pixels to source pixels
        // a1, h1, h8, a8 in the photo.
        let corners: [CGPoint]
        if let given {
            corners = [given.bottomLeft, given.bottomRight, given.topRight, given.topLeft]
        } else {
            guard let found = BoardFinder.find(photo) else { throw DiagramReader.ReadError.noBoard }
            corners = found
        }
        let model = try classifier()
        // The board as found, and the same grid a square off each way: a grid placed a square out
        // reads as nonsense (many unsure squares), which the board itself does not.
        let base = Projective(board: corners.map { CGPoint(x: $0.x * k, y: $0.y * k) })
        var best: (probabilities: [[Double]], board: Projective, score: Double)?
        func consider(_ h: Projective) throws {
            let p = try classify(crops(source, h), model: model)
            let score = p.map { $0.max() ?? 0 }.reduce(0, +) / 64
            #if DEBUG
            if ProcessInfo.processInfo.environment["BOARD_DEBUG"] != nil || ProcessInfo.processInfo.arguments.contains("-boardDebug") {
                print("board grid: score \(score) doubtful \(p.filter(DiagramReader.isDoubtful).count) a1 at \(h.map(0, 0))")
            }
            #endif
            if best == nil || score > best!.score { best = (p, h, score) }
        }
        try consider(base)
        let doubtful = best!.probabilities.filter(DiagramReader.isDoubtful).count
        if given == nil, doubtful >= 6 {
            for dx in -1...1 {
                for dy in -1...1 where dx != 0 || dy != 0 {
                    try consider(base.shifted(Double(dx), Double(dy)))
                }
            }
        }
        var probabilities = best!.probabilities
        var board = best!.board
        // The finder named the corners so that a1 is a dark square; a grid it placed a square off
        // has the colours the other way, and was named a quarter turn round. Named again on the
        // grid chosen.
        if given == nil {
            let grey = source.grey()
            let c = [board.map(0, 0), board.map(8, 0), board.map(8, 8), board.map(0, 8)]
            if BoardFinder.coloursAgree(grey, source.width, source.height, board) == false,
               BoardFinder.coloursAgree(grey, source.width, source.height, Projective(board: [c[1], c[2], c[3], c[0]])) == true {
                board = Projective(board: [c[1], c[2], c[3], c[0]])
                probabilities = try classify(crops(source, board), model: model)
            }
        }
        // Which way round: a1 is dark, but a board turned half round looks the same. The pieces
        // decide: White's pawns and king stand nearer rank 1 than Black's in nearly every position.
        if given == nil, whiteStandsHigh(probabilities) {
            probabilities = Array(probabilities.reversed())
            board = board * Projective(m: [-1, 0, 8, 0, -1, 8, 0, 0, 1])
        }
        let p = DiagramReader.constrain(probabilities)
        var pieces = [Piece?](repeating: nil, count: 64)
        var uncertain = [Bool](repeating: false, count: 64)
        for sq in 0..<64 {
            let row = p[sq]
            let k = row.indices.max { row[$0] < row[$1] } ?? 0
            pieces[sq] = DiagramReader.classes[k]
            uncertain[sq] = DiagramReader.isDoubtful(row)
        }
        // The board's corners in the photo: a8 top left, h8 top right, h1, a1.
        let h = board
        func photoPoint(_ f: Double, _ r: Double) -> CGPoint {
            let q = h.map(f, r)
            return CGPoint(x: q.x / k, y: q.y / k)
        }
        let quad = DiagramReader.Quad(topLeft: photoPoint(0, 8), topRight: photoPoint(8, 8),
                                      bottomRight: photoPoint(8, 0), bottomLeft: photoPoint(0, 0))
        // The board seen from above, to compare with: the pieces lean, but the squares line up.
        guard let flat = DiagramReader.straighten(photo, quad) else { throw DiagramReader.ReadError.noBoard }
        return DiagramReader.Reading(pieces: pieces, uncertain: uncertain, board: flat.image, quad: quad,
                                     flipped: false, photo: photo, kind: .board)
    }

    /// Whether White's pawns and king read as standing further up the board (towards rank 8)
    /// than Black's: the board is the other way round.
    static func whiteStandsHigh(_ p: [[Double]]) -> Bool {
        func meanRank(_ color: PieceColor) -> Double? {
            let kinds = [Piece(color, .pawn), Piece(color, .king)].compactMap { DiagramReader.classes.firstIndex(of: $0) }
            var weight = 0.0, sum = 0.0
            for sq in 0..<64 {
                let w = kinds.map { p[sq][$0] }.reduce(0, +)
                weight += w; sum += w * Double(sq / 8)
            }
            return weight > 0.5 ? sum / weight : nil
        }
        guard let white = meanRank(.white), let black = meanRank(.black) else { return false }
        return white > black
    }

    // MARK: - Crops

    /// The 64 crops, a1, b1, ..., h8, as the classifier's input: [64, 3, 96, 48], RGB 0...255.
    static func crops(_ image: RGBImage, _ board: Projective) -> MLMultiArray {
        let cw = cropWidth, ch = cropHeight
        let array = try! MLMultiArray(shape: [64, 3, NSNumber(value: ch), NSNumber(value: cw)], dataType: .float32)
        let out = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = ch * cw
        for sq in 0..<64 {
            let f = Double(sq % 8), r = Double(sq / 8)
            let c = [board.map(f, r), board.map(f + 1, r), board.map(f + 1, r + 1), board.map(f, r + 1)]
            // The front edge: the two corners lowest in the picture.
            let front = c.sorted { $0.y > $1.y }.prefix(2)
            let width = hypot(front.first!.x - front.last!.x, front.first!.y - front.last!.y)
            let cx = c.map(\.x).reduce(0, +) / 4
            let bottom = c.map(\.y).max()! + below * width
            let x0 = cx - wide * width / 2, x1 = cx + wide * width / 2
            let y0 = bottom - tall * width, y1 = bottom
            let sx = (x1 - x0) / Double(cw), sy = (y1 - y0) / Double(ch)
            let base = sq * 3 * plane
            for v in 0..<ch {
                for u in 0..<cw {
                    // As OpenCV's warpAffine: crop pixel (u, v) is the photo at x0 + u * sx.
                    let rgb = image.bilinear(x0 + Double(u) * sx, y0 + Double(v) * sy)
                    out[base + v * cw + u] = rgb.0
                    out[base + plane + v * cw + u] = rgb.1
                    out[base + 2 * plane + v * cw + u] = rgb.2
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
        guard let url = Bundle.main.url(forResource: "PieceClassifier", withExtension: "mlmodelc") else {
            throw DiagramReader.ReadError.model("the piece classifier is missing from the app")
        }
        do {
            let model = try MLModel(contentsOf: url)
            cachedModel = model
            return model
        } catch {
            throw DiagramReader.ReadError.model(error.localizedDescription)
        }
    }

    /// Per square (a1 first), the probability of each class in `DiagramReader.classes`.
    static func classify(_ crops: MLMultiArray, model: MLModel) throws -> [[Double]] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["crops": MLFeatureValue(multiArray: crops)])
        guard let out = try model.prediction(from: input).featureValue(for: "probabilities")?.multiArrayValue else {
            throw DiagramReader.ReadError.model("the classifier gave no answer")
        }
        return (0..<64).map { i in (0..<13).map { out[[NSNumber(value: i), NSNumber(value: $0)]].doubleValue } }
    }
}

/// A picture as RGB bytes, for sampling.
struct RGBImage {
    let width: Int, height: Int
    let pixels: [UInt8]       // RGBA

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// `image` scaled by `scale` (Lanczos), as RGBA.
    init?(_ image: CGImage, scale: Double) {
        let w = Int((Double(image.width) * scale).rounded()), h = Int((Double(image.height) * scale).rounded())
        guard w >= 16, h >= 16 else { return nil }
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(CIImage(cgImage: image).clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let scaled = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buffer in
            Self.context.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: w * 4,
                                bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        width = w; height = h; pixels = px
    }

    /// Bilinear, with the edge pixels repeated beyond the picture.
    func bilinear(_ x: Double, _ y: Double) -> (Float32, Float32, Float32) {
        let xc = min(max(x, 0), Double(width - 1)), yc = min(max(y, 0), Double(height - 1))
        let x0 = Int(xc), y0 = Int(yc)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float32(xc - Double(x0)), fy = Float32(yc - Double(y0))
        func at(_ x: Int, _ y: Int, _ c: Int) -> Float32 { Float32(pixels[(y * width + x) * 4 + c]) }
        func mix(_ c: Int) -> Float32 {
            let top = at(x0, y0, c) * (1 - fx) + at(x1, y0, c) * fx
            let bottom = at(x0, y1, c) * (1 - fx) + at(x1, y1, c) * fx
            return top * (1 - fy) + bottom * fy
        }
        return (mix(0), mix(1), mix(2))
    }

    /// Grey values as OpenCV's BGR2GRAY computes them.
    func grey() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            out[i] = 0.299 * Float(pixels[i * 4]) + 0.587 * Float(pixels[i * 4 + 1]) + 0.114 * Float(pixels[i * 4 + 2])
        }
        return out
    }
}
