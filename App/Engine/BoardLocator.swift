import CoreGraphics
import CoreML
import Foundation

/// Finds a real board's playing area with a network trained on rendered boards of many kinds, from
/// any side and on any surface (BoardNet.mlpackage: tools/board3d/finder.py, renders by
/// tools/render3d/boards3d.py), then places it exactly on the board's X-corners
/// (tools/board3d/refine.py, where both steps were developed and measured).
///
/// 1. The network sees the photo letterboxed into 256 x 256 and gives, at 64 x 64, the playing area
///    (which pieces standing on it do not break up), its four corners and its 81 square corners.
/// 2. Of the corner peaks, the four whose quadrilateral best covers the playing area; refined on
///    the square corners the network found.
/// 3. That board, within half a square nearly always but no closer than a quarter or so, names each
///    X-corner's square corner, and the board is fitted again to the X-corners, tighter each pass.
///
/// Which corner is a1 is left to `BoardFinder`, as for its own boards.
enum BoardLocator {
    static let side = 256, mapSide = 64
    static let stride = Double(side / mapSide)

    /// The playing area's corners, in order round it, in the pixels of the picture `blurred` is
    /// (the photo scaled by `scale`), or nil when the network sees no board.
    static func locate(_ photo: CGImage, scale: Double, blurred: [Float], _ w: Int, _ h: Int) -> [CGPoint]? {
        guard let maps = maps(photo) else { return nil }
        guard let quad = fit(maps.maps) else { return nil }
        let k = scale / maps.scale                  // network canvas to the working picture
        let network = quad.map { CGPoint(x: $0.x * k, y: $0.y * k) }
        let snapped = snap(network, blurred, w, h)
        #if DEBUG
        if ProcessInfo.processInfo.environment["BOARD_DEBUG"] != nil {
            func text(_ q: [CGPoint]) -> String { q.map { "(\(Int($0.x / scale)), \(Int($0.y / scale)))" }.joined(separator: " ") }
            print("board locator: network \(text(network)) snapped \(snapped == network ? "no" : text(snapped))")
        }
        #endif
        return snapped
    }

    // MARK: - The network

    struct Maps {
        /// Playing area, corners, square corners: each mapSide x mapSide, row major.
        var area: [Float], corners: [Float], lattice: [Float]
    }

    /// The network's maps, and the scale the photo was letterboxed at.
    static func maps(_ photo: CGImage) -> (maps: Maps, scale: Double)? {
        let s = Double(side) / Double(max(photo.width, photo.height))
        guard let small = RGBImage(photo, scale: s), let model = try? network(),
              let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32) else { return nil }
        // At the top left of a grey canvas, as in training.
        let p = input.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = side * side
        for i in 0..<(3 * plane) { p[i] = 114 }
        for y in 0..<min(side, small.height) {
            for x in 0..<min(side, small.width) {
                let o = (y * small.width + x) * 4
                for c in 0..<3 { p[c * plane + y * side + x] = Float32(small.pixels[o + c]) }
            }
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]),
              let out = try? model.prediction(from: provider).featureValue(for: "maps")?.multiArrayValue else { return nil }
        func channel(_ c: Int) -> [Float] {
            (0..<(mapSide * mapSide)).map { out[[0, NSNumber(value: c), NSNumber(value: $0 / mapSide), NSNumber(value: $0 % mapSide)]].floatValue }
        }
        return (Maps(area: channel(0), corners: channel(1), lattice: channel(2)), s)
    }

    nonisolated(unsafe) private static var cachedModel: MLModel?
    private static let modelLock = NSLock()

    static func network() throws -> MLModel {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cachedModel { return cachedModel }
        guard let url = Bundle.main.url(forResource: "BoardNet", withExtension: "mlmodelc") else {
            throw DiagramReader.ReadError.model("the board finder is missing from the app")
        }
        let model = try MLModel(contentsOf: url)
        cachedModel = model
        return model
    }

    // MARK: - Fitting the board

    /// Local maxima of a map over `threshold`, the strongest `top`, each placed at the centroid of
    /// the 3 x 3 cells round it; in canvas pixels, with their values.
    static func peaks(_ heat: [Float], threshold: Float, top: Int) -> [(point: CGPoint, value: Float)] {
        let n = mapSide
        var found: [(Int, Int, Float)] = []
        for y in 0..<n {
            for x in 0..<n {
                let v = heat[y * n + x]
                guard v > threshold else { continue }
                var isMax = true
                for dy in -1...1 {
                    for dx in -1...1 where (dx != 0 || dy != 0) && (0..<n).contains(x + dx) && (0..<n).contains(y + dy) {
                        if heat[(y + dy) * n + x + dx] > v { isMax = false }
                    }
                }
                if isMax { found.append((x, y, v)) }
            }
        }
        return found.sorted { $0.2 > $1.2 }.prefix(top).map { x, y, v in
            var sx = 0.0, sy = 0.0, sw = 0.0
            for yy in max(0, y - 1)...min(n - 1, y + 1) {
                for xx in max(0, x - 1)...min(n - 1, x + 1) {
                    let w = Double(heat[yy * n + xx])
                    sx += Double(xx) * w; sy += Double(yy) * w; sw += w
                }
            }
            return (CGPoint(x: (sx / sw + 0.5) * stride, y: (sy / sw + 0.5) * stride), v)
        }
    }

    /// The playing area's corners in the network's canvas, or nil.
    static func fit(_ maps: Maps) -> [CGPoint]? {
        let n = mapSide
        let inside = maps.area.map { $0 > 0.5 }
        guard inside.filter({ $0 }).count >= 4 else { return nil }
        let candidates = peaks(maps.corners, threshold: 0.1, top: 8)
        guard candidates.count >= 4 else { return nil }
        var best: (score: Double, quad: [CGPoint])?
        let m = candidates.count
        for a in 0..<m { for b in (a + 1)..<m { for c in (b + 1)..<m { for d in (c + 1)..<m {
            let combo = [a, b, c, d]
            var pts = combo.map { candidates[$0].point }
            let cx = pts.map(\.x).reduce(0, +) / 4, cy = pts.map(\.y).reduce(0, +) / 4
            pts.sort { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }        // round the board
            var area = 0.0
            for k in 0..<4 { area += pts[k].x * pts[(k + 1) % 4].y - pts[(k + 1) % 4].x * pts[k].y }
            guard abs(area) / 2 >= 100 else { continue }                          // three in a line, or a sliver
            var both = 0, either = 0
            for y in 0..<n {
                for x in 0..<n {
                    let px = (Double(x) + 0.5) * stride, py = (Double(y) + 0.5) * stride
                    var pos = true, neg = true
                    for k in 0..<4 {
                        let p0 = pts[k], p1 = pts[(k + 1) % 4]
                        let side = (p1.x - p0.x) * (py - p0.y) - (p1.y - p0.y) * (px - p0.x)
                        if side < 0 { pos = false }
                        if side > 0 { neg = false }
                    }
                    let inQuad = pos || neg, inArea = inside[y * n + x]
                    if inQuad && inArea { both += 1 }
                    if inQuad || inArea { either += 1 }
                }
            }
            let score = Double(both) / Double(max(1, either)) + 0.2 * Double(combo.map { candidates[$0].value }.reduce(0, +)) / 4
            if best == nil || score > best!.score { best = (score, pts) }
        } } } }
        guard let quad = best?.quad else { return nil }
        // Refined on the square corners found: each named by the board's grid, and the map fitted
        // to all of them.
        var board = Projective(board: quad)
        let lattice = peaks(maps.lattice, threshold: 0.2, top: 120).map(\.point)
        if lattice.count >= 6 {
            for _ in 0..<2 {
                guard let refined = refit(board, lattice, tolerance: 0.3, range: 0...8, minimum: 6) else { break }
                board = refined.board
            }
        }
        let q = corners(board)
        return q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) ? q : nil
    }

    // MARK: - Placing it on the X-corners

    /// A refit moving the board further than this, in squares, is not trusted: the network's board
    /// is within half a square nearly always, and a refit gone wrong slips a whole square.
    static let maxMove = 0.8

    /// `quad` refitted to the X-corners in `blurred` (all in its pixels), or `quad` itself when too
    /// few X-corners bear a board out, or the refit moves it more than `maxMove` squares.
    static func snap(_ quad: [CGPoint], _ blurred: [Float], _ w: Int, _ h: Int) -> [CGPoint] {
        // X-corners by both of the finder's checks: the quadrants miss boards turned near 45
        // degrees, the ring takes more stray points, which the board's grid sorts out here.
        var points: [CGPoint] = []
        for p in BoardFinder.xCorners(blurred, w, h) + BoardFinder.xCorners(blurred, w, h, ring: true)
        where points.allSatisfy({ hypot($0.x - p.x, $0.y - p.y) > 3 }) {
            points.append(p)
        }
        guard points.count >= 8 else { return quad }
        var board = Projective(board: quad)
        var used = false
        #if DEBUG
        let debug = ProcessInfo.processInfo.environment["BOARD_DEBUG"] != nil
        if debug { print("board locator: \(points.count) X-corners") }
        #endif
        // Only the 7 x 7 inner corners are X-corners: on the playing area's edge the squares meet
        // the frame, whose inlay lines and rim make corners of their own a little outside it.
        for tolerance in [0.3, 0.2, 0.12] {
            guard let refined = refit(board, points, tolerance: tolerance, range: 1...7, minimum: 8) else { break }
            #if DEBUG
            if debug { print("board locator: tolerance \(tolerance) fitted to \(refined.used)") }
            #endif
            board = refined.board
            used = true
        }
        guard used else { return quad }
        let q = corners(board)
        let square = (0..<4).map { hypot(quad[$0].x - quad[($0 + 1) % 4].x, quad[$0].y - quad[($0 + 1) % 4].y) }.reduce(0, +) / 32
        let moved = (0..<4).map { hypot(q[$0].x - quad[$0].x, q[$0].y - quad[$0].y) }.max()!
        #if DEBUG
        if debug { print("board locator: moved \(moved / square) squares") }
        #endif
        guard q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), moved <= maxMove * square else { return quad }
        return q
    }

    /// The board fitted again to the points that lie within `tolerance` of a whole lattice position
    /// in `range` (the nearest one to each position), and again without those it then misses by
    /// far; nil when they are fewer than `minimum` or on fewer than three lines either way, which
    /// fix no map.
    static func refit(_ board: Projective, _ points: [CGPoint], tolerance: Double, range: ClosedRange<Int>, minimum: Int)
        -> (board: Projective, used: Int)? {
        guard let inverse = board.inverse else { return nil }
        var nearest: [Int: (distance: Double, point: CGPoint, i: Int, j: Int)] = [:]
        for p in points {
            let g = inverse.map(Double(p.x), Double(p.y))
            let i = Int(g.x.rounded()), j = Int(g.y.rounded())
            let d = max(abs(g.x - Double(i)), abs(g.y - Double(j)))
            guard d < tolerance, range.contains(i), range.contains(j) else { continue }
            let key = i * 100 + j
            if nearest[key] == nil || d < nearest[key]!.distance { nearest[key] = (d, p, i, j) }
        }
        var chosen = Array(nearest.values)
        func fitted(_ c: [(distance: Double, point: CGPoint, i: Int, j: Int)]) -> Projective? {
            guard c.count >= minimum, Set(c.map(\.i)).count >= 3, Set(c.map(\.j)).count >= 3,
                  let f = Projective.fit(from: c.map { (Double($0.i), Double($0.j)) }, to: c.map { (Double($0.point.x), Double($0.point.y)) }),
                  f.inverse != nil else { return nil }
            return f
        }
        guard var fit = fitted(chosen) else { return nil }
        // Once more without the points the fit misses by far (an X-corner on a piece, or placed a
        // few pixels off): least squares lets a few pull the corners, which lie beyond them all.
        let miss = chosen.map { c in let p = fit.map(Double(c.i), Double(c.j)); return hypot(p.x - c.point.x, p.y - c.point.y) }
        let limit = max(2.0, 3 * miss.sorted()[miss.count / 2])
        let kept = zip(chosen, miss).filter { $0.1 <= limit }.map(\.0)
        if kept.count < chosen.count, let refit = fitted(kept) {
            chosen = kept
            fit = refit
        }
        return (fit, chosen.count)
    }

    static func corners(_ board: Projective) -> [CGPoint] {
        [board.map(0, 0), board.map(8, 0), board.map(8, 8), board.map(0, 8)]
    }
}
