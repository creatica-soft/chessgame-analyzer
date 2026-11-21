import CoreGraphics
import Foundation

/// A projective map of the plane (a homography), as a row-major 3x3 matrix.
struct Projective {
    var m: [Double]

    static let identity = Projective(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    func map(_ x: Double, _ y: Double) -> CGPoint {
        let w = m[6] * x + m[7] * y + m[8]
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    static func * (a: Projective, b: Projective) -> Projective {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i * 3 + j] += a.m[i * 3 + k] * b.m[k * 3 + j] } } }
        return Projective(m: r)
    }

    var inverse: Projective? {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7], c01 = a[5] * a[6] - a[3] * a[8], c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-12, det.isFinite else { return nil }
        let r = [c00, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
                 c01, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
                 c02, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]]
        return Projective(m: r.map { $0 / det })
    }

    /// Board coordinates (file, rank from 0 to 8; a1's outer corner at 0,0) to the picture, from
    /// the corners a1, h1, h8, a8.
    init(board corners: [CGPoint]) {
        self = Projective.fit(from: [(0, 0), (8, 0), (8, 8), (0, 8)], to: corners.map { (Double($0.x), Double($0.y)) }) ?? .identity
    }

    init(m: [Double]) { self.m = m }

    /// The same map with the board moved by (dx, dy) squares.
    func shifted(_ dx: Double, _ dy: Double) -> Projective {
        self * Projective(m: [1, 0, dx, 0, 1, dy, 0, 0, 1])
    }

    /// The map taking `from` to `to` (at least 4 points), by least squares on normalised points.
    static func fit(from: [(Double, Double)], to: [(Double, Double)]) -> Projective? {
        let n = from.count
        guard n >= 4, to.count == n else { return nil }
        func normaliser(_ p: [(Double, Double)]) -> Projective {
            let cx = p.map(\.0).reduce(0, +) / Double(p.count), cy = p.map(\.1).reduce(0, +) / Double(p.count)
            let d = p.map { hypot($0.0 - cx, $0.1 - cy) }.reduce(0, +) / Double(p.count)
            let s = d > 1e-9 ? 2.squareRoot() / d : 1
            return Projective(m: [s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1])
        }
        let ts = normaliser(from), td = normaliser(to)
        let src = from.map { ts.map($0.0, $0.1) }, dst = to.map { td.map($0.0, $0.1) }
        // h33 = 1: two equations a point, solved by the normal equations.
        var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
        for i in 0..<n {
            let x = Double(src[i].x), y = Double(src[i].y), u = Double(dst[i].x), v = Double(dst[i].y)
            let rows: [([Double], Double)] = [([x, y, 1, 0, 0, 0, -u * x, -u * y], u),
                                              ([0, 0, 0, x, y, 1, -v * x, -v * y], v)]
            for (row, b) in rows {
                for a in 0..<8 {
                    atb[a] += row[a] * b
                    for c in 0..<8 { ata[a * 8 + c] += row[a] * row[c] }
                }
            }
        }
        guard let h = solve(ata, atb, 8) else { return nil }
        let hn = Projective(m: h + [1])
        guard let tdi = td.inverse else { return nil }
        let result = tdi * hn * ts
        return result.m.allSatisfy(\.isFinite) ? result : nil
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var a = a, b = b
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0 * n + col]) < abs(a[$1 * n + col]) }!
            guard abs(a[pivot * n + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            for row in (col + 1)..<n {
                let f = a[row * n + col] / a[col * n + col]
                if f == 0 { continue }
                for k in col..<n { a[row * n + k] -= f * a[col * n + k] }
                b[row] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = b[row]
            for k in (row + 1)..<n { s -= a[row * n + k] * x[k] }
            x[row] = s / a[row * n + row]
        }
        return x
    }
}

/// Finds a real chess board in a photo by its grid: the 9 x 9 lattice of square corners.
/// The same method as tools/board3d/grid.py, where it was developed and measured.
///
/// 1. X-corners: where four squares meet, light and dark diagonally opposite; saddle points of the
///    smoothed brightness, checked by the pattern round them.
/// 2. Lattice: a cell of four X-corners is taken for a square, and the map it gives (grown outward
///    and refitted) that puts most X-corners on whole lattice positions wins.
/// 3. The lattice's basis: of the whole-number shears that pass through the same points, the one
///    whose cells alternate light and dark.
/// 4. Board: the 8 x 8 block of lattice squares that alternates most clearly, holds most of the
///    X-corners and whose surroundings do not carry the pattern on.
/// 5. Naming: rank 1 is the edge nearest the camera, a1 its left end, checked by a1 being dark.
///
/// The board is looked for first by `BoardLocator` (a network trained on rendered boards, placed
/// on the X-corners), which finds boards this grid search misses or misplaces: seen low from a
/// side, on a patterned table, with pieces hiding much of the grid. The grid search is kept for
/// when the network finds nothing whose squares alternate.
enum BoardFinder {
    static let work = 960.0

    /// The network's board is tried first unless BOARD_FINDER=grid is set (for comparing the two).
    static let useNetwork = ProcessInfo.processInfo.environment["BOARD_FINDER"] != "grid"

    /// The board's corners a1, h1, h8, a8 in the photo, or nil.
    static func find(_ photo: CGImage) -> [CGPoint]? { locate(photo)?.corners }

    /// The board's corners a1, h1, h8, a8 in the photo, and whether the network found them (not
    /// the grid search, which may place the board a square off).
    static func locate(_ photo: CGImage) -> (corners: [CGPoint], byNetwork: Bool)? {
        let scale = min(1, work / Double(max(photo.width, photo.height)))
        guard let image = RGBImage(photo, scale: scale) else { return nil }
        let w = image.width, h = image.height
        let grey = image.grey()
        let blurred = gaussian(grey, w, h, sigma: 2)
        if useNetwork, let quad = BoardLocator.locate(photo, scale: scale, blurred: blurred, w, h), plausible(quad) {
            let (named, _) = name(quad, grey, w, h)
            if checkerScore(grey, w, h, Projective(board: named)) >= minCheckerScore {
                return (named.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }, true)
            }
        }
        // X-corners checked by quadrants first: the ring finds boards turned near 45 degrees, which
        // the quadrants miss, but places the board a square off more often. A grid whose cells do
        // not alternate light and dark is not the board (a lattice sheared across the squares):
        // better none, and the corners set by hand, than a reading of it.
        var fallback: (corners: [CGPoint], score: Double)?
        for ring in [false, true] {
            guard let (named, agree) = board(xCorners(blurred, w, h, ring: ring), grey, w, h) else { continue }
            let score = checkerScore(grey, w, h, Projective(board: named))
            if agree, score >= minCheckerScore { return (named.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }, false) }
            if score >= minCheckerScore, score > fallback?.score ?? 0 { fallback = (named, score) }
        }
        return fallback.map { ($0.corners.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }, false) }
    }

    /// Below this `checkerScore` a grid is taken not to be the board: on held-out frames of the
    /// training board, no grid that read right scored under 0.7, and most wrong ones under 0.6.
    static let minCheckerScore = 0.65

    /// A board seen in perspective is a convex quadrilateral without very sharp corners; a lattice
    /// fitted to stray points can make a thin sliver instead.
    static func plausible(_ q: [CGPoint]) -> Bool {
        var sign = 0.0
        for k in 0..<4 {
            let a = q[(k + 3) % 4], b = q[k], c = q[(k + 1) % 4]
            let u = (a.x - b.x, a.y - b.y), v = (c.x - b.x, c.y - b.y)
            let cross = u.0 * v.1 - u.1 * v.0
            if sign == 0 { sign = cross < 0 ? -1 : 1 }
            guard cross * sign > 0 else { return false }
            let angle = acos(max(-1, min(1, (u.0 * v.0 + u.1 * v.1) / (hypot(u.0, u.1) * hypot(v.0, v.1)))))
            guard angle > 20 * .pi / 180 else { return false }
        }
        return true
    }

    /// The board on these X-corners, a1, h1, h8, a8, named so that a1 is a dark corner nearest the
    /// camera; and whether the squares' colours bear the naming out.
    static func board(_ points: [CGPoint], _ grey: [Float], _ w: Int, _ h: Int) -> ([CGPoint], Bool)? {
        guard let (lattice, onGrid) = fitLattice(points, grey: grey, w, h),
              let (i0, j0) = placeBoard(grey, w, h, lattice, onGrid) else { return nil }
        let quad = [lattice.map(i0, j0), lattice.map(i0 + 8, j0), lattice.map(i0 + 8, j0 + 8), lattice.map(i0, j0 + 8)]
        guard plausible(quad) else { return nil }
        return name(quad, grey, w, h)
    }

    /// A board's corners, in order round it, named a1, h1, h8, a8 so that a1 is a dark corner
    /// nearest the camera; and whether the squares' colours bear the naming out.
    static func name(_ quad: [CGPoint], _ grey: [Float], _ w: Int, _ h: Int) -> ([CGPoint], Bool) {
        let named = nameCorners(quad)
        guard let agree = coloursAgree(grey, w, h, Projective(board: named)) else { return (named, false) }
        if agree { return (named, true) }
        // a1 is light here: the camera is at a side of the board, not White's, or the board is
        // turned. Named from the next corner; the reader settles a half turn from the pieces.
        let turned = [named[1], named[2], named[3], named[0]]
        return (turned, coloursAgree(grey, w, h, Projective(board: turned)) == true)
    }

    // MARK: - Filtering

    /// Gaussian blur, edges reflected as OpenCV's BORDER_REFLECT_101.
    static func gaussian(_ src: [Float], _ w: Int, _ h: Int, sigma: Double) -> [Float] {
        let radius = Int((sigma * 4).rounded())
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        func reflect(_ i: Int, _ n: Int) -> Int {
            var i = i
            while i < 0 || i >= n { i = i < 0 ? -i : 2 * (n - 1) - i }
            return i
        }
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in -radius...radius { s += kernel[k + radius] * src[y * w + reflect(x + k, w)] }
                tmp[y * w + x] = s
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in -radius...radius { s += kernel[k + radius] * tmp[reflect(y + k, h) * w + x] }
                out[y * w + x] = s
            }
        }
        return out
    }

    // MARK: - X-corners

    /// X-corners: saddles of the brightness with the pattern of four squares round them, checked by
    /// the four diagonal quadrants (`ring` false) or by a ring at any angle (see `xPattern`).
    static func xCorners(_ g: [Float], _ w: Int, _ h: Int, maxPoints: Int = 400, ring: Bool = false) -> [CGPoint] {
        func at(_ x: Int, _ y: Int) -> Float {
            let xr = x < 0 ? -x : x >= w ? 2 * (w - 1) - x : x
            let yr = y < 0 ? -y : y >= h ? 2 * (h - 1) - y : y
            return g[yr * w + xr]
        }
        // Second derivatives, as 3x3 Sobel; a saddle where Ixy^2 > Ixx * Iyy.
        var saddle = [Float](repeating: 0, count: w * h)
        var top: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let ixx = (at(x - 1, y - 1) - 2 * at(x, y - 1) + at(x + 1, y - 1))
                    + 2 * (at(x - 1, y) - 2 * at(x, y) + at(x + 1, y))
                    + (at(x - 1, y + 1) - 2 * at(x, y + 1) + at(x + 1, y + 1))
                let iyy = (at(x - 1, y - 1) - 2 * at(x - 1, y) + at(x - 1, y + 1))
                    + 2 * (at(x, y - 1) - 2 * at(x, y) + at(x, y + 1))
                    + (at(x + 1, y - 1) - 2 * at(x + 1, y) + at(x + 1, y + 1))
                let ixy = at(x - 1, y - 1) - at(x + 1, y - 1) - at(x - 1, y + 1) + at(x + 1, y + 1)
                let s = max(0, ixy * ixy - ixx * iyy)
                saddle[y * w + x] = s
                top = max(top, s)
            }
        }
        // Local maxima in 9 x 9.
        var rowMax = [Float](repeating: 0, count: w * h), localMax = rowMax
        for y in 0..<h {
            for x in 0..<w {
                var m: Float = 0
                for k in max(0, x - 4)...min(w - 1, x + 4) { m = max(m, saddle[y * w + k]) }
                rowMax[y * w + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m: Float = 0
                for k in max(0, y - 4)...min(h - 1, y + 4) { m = max(m, rowMax[k * w + x]) }
                localMax[y * w + x] = m
            }
        }
        var peaks: [(Float, Int, Int)] = []
        for y in 0..<h {
            for x in 0..<w where saddle[y * w + x] > top * 0.02 && saddle[y * w + x] == localMax[y * w + x] {
                peaks.append((saddle[y * w + x], x, y))
            }
        }
        peaks.sort { $0.0 > $1.0 }
        let r = 6
        func mean(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Float {
            var s: Float = 0
            for y in y0..<y1 { for x in x0..<x1 { s += g[y * w + x] } }
            return s / Float((x1 - x0) * (y1 - y0))
        }
        func quadrants(_ x: Int, _ y: Int) -> Bool {
            let q0 = mean(x - r, x - 1, y - r, y - 1), q1 = mean(x + 2, x + r + 1, y - r, y - 1)
            let q2 = mean(x + 2, x + r + 1, y + 2, y + r + 1), q3 = mean(x - r, x - 1, y + 2, y + r + 1)
            let contrast = abs((q0 + q2) / 2 - (q1 + q3) / 2)
            return contrast >= 25 && abs(q0 - q2) <= contrast * 0.6 && abs(q1 - q3) <= contrast * 0.6
        }
        var found: [CGPoint] = []
        for (_, x, y) in peaks.prefix(maxPoints * 3) {
            guard x >= r + 1, y >= r + 1, x < w - r - 1, y < h - r - 1,
                  ring ? xPattern(g, w, x, y, r) : quadrants(x, y) else { continue }
            found.append(subPixel(g, w, h, x, y))
            if found.count >= maxPoints { break }
        }
        return found
    }

    private static let ring: [(Float, Float)] = (0..<16).map {
        let a = Double($0) * 2 * .pi / 16
        return (Float(cos(a)), Float(sin(a)))
    }

    /// The pattern round an X-corner, at any angle: on a ring of radius `r` round it the brightness
    /// changes from light to dark four times, and is alike at opposite points (a corner of four
    /// squares is symmetric about its centre, and stays so in perspective). As grid.py's x_pattern.
    static func xPattern(_ g: [Float], _ w: Int, _ x: Int, _ y: Int, _ r: Int) -> Bool {
        var s = [Float](repeating: 0, count: 16)
        for (i, (c, sn)) in ring.enumerated() {
            let px = Float(x) + Float(r) * c, py = Float(y) + Float(r) * sn
            let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
            let fx = px - Float(x0), fy = py - Float(y0)
            s[i] = g[y0 * w + x0] * (1 - fx) * (1 - fy) + g[y0 * w + x0 + 1] * fx * (1 - fy)
                + g[(y0 + 1) * w + x0] * (1 - fx) * fy + g[(y0 + 1) * w + x0 + 1] * fx * fy
        }
        let o = s.sorted()
        let low = (o[0] + o[1] + o[2] + o[3]) / 4, high = (o[12] + o[13] + o[14] + o[15]) / 4
        let contrast = high - low
        guard contrast >= 25 else { return false }
        var asymmetry: Float = 0
        for i in 0..<8 { asymmetry += abs(s[i] - s[i + 8]) }
        guard asymmetry / 8 <= contrast * 0.3 else { return false }
        let middle = (high + low) / 2
        var changes = 0
        for i in 0..<16 where (s[i] > middle) != (s[(i + 15) % 16] > middle) { changes += 1 }
        return changes == 4
    }

    /// An X-corner to a fraction of a pixel: the point every nearby gradient points across
    /// (OpenCV's cornerSubPix, on a 9 x 9 window).
    static func subPixel(_ g: [Float], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> CGPoint {
        var cx = Double(x), cy = Double(y)
        let win = 4
        for _ in 0..<5 {
            let ix = Int(cx.rounded()), iy = Int(cy.rounded())
            guard ix > win + 1, iy > win + 1, ix < w - win - 2, iy < h - win - 2 else { break }
            var a = 0.0, b = 0.0, c = 0.0, bb1 = 0.0, bb2 = 0.0
            for dy in -win...win {
                for dx in -win...win {
                    let px = ix + dx, py = iy + dy
                    let gx = Double(g[py * w + px + 1] - g[py * w + px - 1]) / 2
                    let gy = Double(g[(py + 1) * w + px] - g[(py - 1) * w + px]) / 2
                    let weight = exp(-Double(dx * dx + dy * dy) / Double(2 * win * win))
                    let gxx = gx * gx * weight, gxy = gx * gy * weight, gyy = gy * gy * weight
                    a += gxx; b += gxy; c += gyy
                    bb1 += gxx * Double(px) + gxy * Double(py)
                    bb2 += gxy * Double(px) + gyy * Double(py)
                }
            }
            let det = a * c - b * b
            guard abs(det) > 1e-9 else { break }
            let nx = (c * bb1 - b * bb2) / det, ny = (a * bb2 - b * bb1) / det
            guard abs(nx - Double(x)) < 4, abs(ny - Double(y)) < 4 else { break }
            let moved = hypot(nx - cx, ny - cy)
            cx = nx; cy = ny
            if moved < 0.01 { break }
        }
        return CGPoint(x: cx, y: cy)
    }

    // MARK: - Lattice

    private static func latticeCoordinates(_ pts: [CGPoint], _ inv: Projective) -> [CGPoint] {
        pts.map { inv.map(Double($0.x), Double($0.y)) }
    }

    private static func error(_ p: CGPoint) -> Double {
        max(abs(Double(p.x) - Double(p.x).rounded()), abs(Double(p.y) - Double(p.y).rounded()))
    }

    /// How many different lattice positions the points on whole numbers take: a map that sends
    /// many points to one position (collapsed) fits nothing.
    private static func distinct(_ lat: [CGPoint], _ use: (Int) -> Bool) -> Int {
        var seen = Set<Int>()
        for (i, p) in lat.enumerated() where use(i) {
            seen.insert((Int(Double(p.x).rounded()) + 1000) * 4096 + Int(Double(p.y).rounded()) + 1000)
        }
        return seen.count
    }

    /// Lattice to picture, and the whole lattice positions of the X-corners on it.
    static func fitLattice(_ pts: [CGPoint], grey: [Float], _ w: Int, _ h: Int) -> (Projective, [(Int, Int)])? {
        let n = pts.count
        guard n >= 8 else { return nil }
        let near: [[Int]] = (0..<n).map { i in
            Array((0..<n).filter { $0 != i }
                .sorted { hypot(pts[$0].x - pts[i].x, pts[$0].y - pts[i].y) < hypot(pts[$1].x - pts[i].x, pts[$1].y - pts[i].y) }
                .prefix(6))
        }
        var rng = SplitMix(seed: 0)
        var candidates: [(Int, Projective)] = []
        let unit: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        for _ in 0..<4000 {
            let p = rng.next(n)
            let nb = near[p]
            guard nb.count >= 3 else { continue }
            var ai = rng.next(nb.count), bi = rng.next(nb.count - 1)
            if bi >= ai { bi += 1 }
            var a = nb[ai], b = nb[bi]
            var u = (pts[a].x - pts[p].x, pts[a].y - pts[p].y), v = (pts[b].x - pts[p].x, pts[b].y - pts[p].y)
            let cross = u.0 * v.1 - u.1 * v.0
            let lu = hypot(u.0, u.1), lv = hypot(v.0, v.1)
            guard abs(cross) >= 0.3 * lu * lv else { continue }
            if cross < 0 { swap(&a, &b); swap(&u, &v); swap(&ai, &bi) }
            let gx = pts[p].x + u.0 + v.0, gy = pts[p].y + u.1 + v.1
            let c = (0..<n).min { hypot(pts[$0].x - gx, pts[$0].y - gy) < hypot(pts[$1].x - gx, pts[$1].y - gy) }!
            guard hypot(pts[c].x - gx, pts[c].y - gy) <= 0.25 * min(lu, lv) else { continue }
            let quad = [pts[p], pts[a], pts[c], pts[b]].map { (Double($0.x), Double($0.y)) }
            guard let H = Projective.fit(from: unit, to: quad), let inv = H.inverse else { continue }
            let lat = latticeCoordinates(pts, inv)
            // Near the cell only: a map from one cell drifts further out; grown outward below.
            let local = distinct(lat) { error(lat[$0]) < 0.15 && max(abs(Double(lat[$0].x) - 0.5), abs(Double(lat[$0].y) - 0.5)) < 2.6 }
            candidates.append((local, H))
        }
        guard !candidates.isEmpty else { return nil }
        var best: (Int, Projective)?
        for (_, start) in candidates.sorted(by: { $0.0 > $1.0 }).prefix(25) {
            var H = start
            for radius in [2.6, 4.6, 7.0, 99] {
                guard let inv = H.inverse else { break }
                let lat = latticeCoordinates(pts, inv)
                let use = { (i: Int) in error(lat[i]) < 0.15 && max(abs(Double(lat[i].x) - 0.5), abs(Double(lat[i].y) - 0.5)) < radius }
                guard distinct(lat, use) >= 5 else { break }
                let idx = (0..<n).filter(use)
                guard let H2 = Projective.fit(from: idx.map { (Double(lat[$0].x).rounded(), Double(lat[$0].y).rounded()) },
                                              to: idx.map { (Double(pts[$0].x), Double(pts[$0].y)) }) else { break }
                H = H2
            }
            guard let inv = H.inverse else { continue }
            let lat = latticeCoordinates(pts, inv)
            let score = distinct(lat) { error(lat[$0]) < 0.15 }
            if best == nil || score > best!.0 { best = (score, H) }
        }
        guard var H = best?.1 else { return nil }
        for _ in 0..<3 {
            guard let inv = H.inverse else { return nil }
            let lat = latticeCoordinates(pts, inv)
            let idx = (0..<n).filter { error(lat[$0]) < 0.15 }
            guard idx.count >= 8,
                  let H2 = Projective.fit(from: idx.map { (Double(lat[$0].x).rounded(), Double(lat[$0].y).rounded()) },
                                          to: idx.map { (Double(pts[$0].x), Double(pts[$0].y)) }) else { break }
            H = H2
        }
        H = reduceBasis(H, pts)
        func onGrid(_ H: Projective) -> [(Int, Int)] {
            guard let inv = H.inverse else { return [] }
            return latticeCoordinates(pts, inv).filter { error($0) < 0.15 }
                .map { (Int(Double($0.x).rounded()), Int(Double($0.y).rounded())) }
        }
        let first = onGrid(H)
        guard first.count >= 4 else { return nil }
        H = chooseBasis(H, first, grey, w, h)
        let final = onGrid(H)
        return final.isEmpty ? nil : (H, final)
    }

    /// The same lattice with its squarest cell in the picture (Gauss's reduction of the steps at
    /// the points' centre): the board's squares in most views. Seen corner-on, a square looks like
    /// a flat diamond whose short diagonal may be taken for a side; `chooseBasis` corrects that.
    static func reduceBasis(_ H: Projective, _ pts: [CGPoint]) -> Projective {
        let cx = Double(pts.map(\.x).reduce(0, +)) / Double(pts.count)
        let cy = Double(pts.map(\.y).reduce(0, +)) / Double(pts.count)
        var T = Projective.identity
        for _ in 0..<20 {
            let M = H * T
            guard let inv = M.inverse else { return H }
            let c = inv.map(cx, cy)
            let o = M.map(Double(c.x), Double(c.y))
            let pu = M.map(Double(c.x) + 1, Double(c.y)), pv = M.map(Double(c.x), Double(c.y) + 1)
            let u = (Double(pu.x - o.x), Double(pu.y - o.y)), v = (Double(pv.x - o.x), Double(pv.y - o.y))
            let uu = u.0 * u.0 + u.1 * u.1, vv = v.0 * v.0 + v.1 * v.1
            guard uu.isFinite, vv.isFinite, min(uu, vv) >= 4 else { return H }
            if uu > vv {
                T = T * Projective(m: [0, 1, 0, 1, 0, 0, 0, 0, 1])
                continue
            }
            let m = ((u.0 * v.0 + u.1 * v.1) / uu).rounded()
            if m == 0 { break }
            T = T * Projective(m: [1, -m, 0, 0, 1, 0, 0, 0, 1])
        }
        return H * T
    }

    /// One shear step either way, in either direction; the identity first, so that it wins a tie.
    private static let steps: [Projective] = [.identity,
        Projective(m: [1, 1, 0, 0, 1, 0, 0, 0, 1]), Projective(m: [1, -1, 0, 0, 1, 0, 0, 0, 1]),
        Projective(m: [1, 0, 0, 1, 1, 0, 0, 0, 1]), Projective(m: [1, 0, 0, -1, 1, 0, 0, 0, 1])]

    /// Of the bases one shear away, the one whose cells' middles alternate light and dark: in the
    /// board's own basis each middle lies inside a square, in a sheared one on a square's edge.
    static func chooseBasis(_ H: Projective, _ lat: [(Int, Int)], _ grey: [Float], _ w: Int, _ h: Int) -> Projective {
        guard !lat.isEmpty else { return H }
        // Judged on the cells all four of whose corners were found: they are on the board. The
        // lattice's whole span also takes in stray points off the board, whose cells would swamp it.
        let found = Set(lat.map { $0.0 * 4096 + $0.1 })
        var cells = lat.filter { found.contains(($0.0 + 1) * 4096 + $0.1) && found.contains($0.0 * 4096 + $0.1 + 1)
            && found.contains(($0.0 + 1) * 4096 + $0.1 + 1) }
        if cells.count < 6 {
            let lo = (lat.map(\.0).min()!, lat.map(\.1).min()!), hi = (lat.map(\.0).max()!, lat.map(\.1).max()!)
            cells = ((lo.0 - 1)...hi.0).flatMap { i in ((lo.1 - 1)...hi.1).map { (i, $0) } }
        }
        var best: (Double, Projective) = (-1, H)
        for T in steps {
            let M = H * T
            guard let Ti = T.inverse else { continue }
            var odd: [Float] = [], even: [Float] = []
            for (i, j) in cells {
                // The same image cell, named in the new basis; its middle there is sampled.
                let mid = Ti.map(Double(i) + 0.5, Double(j) + 0.5)
                let a = Double(mid.x).rounded(.down), b = Double(mid.y).rounded(.down)
                let c = M.map(a + 0.5, b + 0.5)
                let x = Int(c.x), y = Int(c.y)
                guard c.x >= 0, c.y >= 0, x < w, y < h else { continue }
                if (Int(a) + Int(b)) & 1 == 1 { odd.append(grey[y * w + x]) } else { even.append(grey[y * w + x]) }
            }
            guard odd.count + even.count >= 8, !odd.isEmpty, !even.isEmpty else { continue }
            let contrast = Double(abs(median(odd) - median(even)))
            if contrast > best.0 * 1.05 { best = (contrast, M) }
        }
        return best.1
    }

    private static func median(_ v: [Float]) -> Float {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: - Placing the board

    /// Points within a square, as fractions of it; the part nearest the camera is sampled.
    private static let grid: [(Double, Double)] = {
        let t = (0..<5).map { 0.12 + 0.19 * Double($0) }
        return t.flatMap { x in t.map { y in (x, y) } }
    }()

    /// The brightness of lattice square (i, j): the median of the part nearest the camera (lowest
    /// in the picture). Pieces stand up from their squares and hide what is behind them, higher in
    /// the picture; the near part is the likeliest seen. nil when it runs off the picture.
    private static func squareValue(_ grey: [Float], _ w: Int, _ h: Int, _ H: Projective, _ i: Double, _ j: Double) -> Float? {
        var pts: [CGPoint] = []
        for (x, y) in grid {
            let p = H.map(i + x, j + y)
            guard p.x >= 0, p.y >= 0, p.x < CGFloat(w), p.y < CGFloat(h) else { return nil }
            pts.append(p)
        }
        let near = pts.sorted { $0.y > $1.y }.prefix(8)
        return median(near.map { grey[Int($0.y) * w + Int($0.x)] })
    }

    /// The lattice corner (i0, j0) of the 8 x 8 block of squares that is the board.
    static func placeBoard(_ grey: [Float], _ w: Int, _ h: Int, _ H: Projective, _ lat: [(Int, Int)]) -> (Double, Double)? {
        // A lattice fitted to no points at all (it happens, rarely) places nothing.
        guard let i0 = lat.map(\.0).min(), let j0 = lat.map(\.1).min(),
              let i1 = lat.map(\.0).max(), let j1 = lat.map(\.1).max() else { return nil }
        let lo = (i0, j0), hi = (i1, j1)
        guard lo.0 - 2 <= hi.0 - 6, lo.1 - 2 <= hi.1 - 6 else { return nil }
        var best: (Double, (Double, Double))?
        for i0 in (lo.0 - 2)...(hi.0 - 6) {
            for j0 in (lo.1 - 2)...(hi.1 - 6) {
                // 10 x 10 squares: the block and a ring round it. v[y][x], x and y from 0 to 9.
                var v = [[Float?]](repeating: [Float?](repeating: nil, count: 10), count: 10)
                for y in 0..<10 {
                    for x in 0..<10 {
                        v[y][x] = squareValue(grey, w, h, H, Double(i0 - 1 + x), Double(j0 - 1 + y))
                    }
                }
                var odd: [Float] = [], even: [Float] = [], missing = 0
                for y in 1...8 {
                    for x in 1...8 {
                        guard let val = v[y][x] else { missing += 1; continue }
                        if ((x - 1) + (y - 1)) % 2 == 1 { odd.append(val) } else { even.append(val) }
                    }
                }
                guard Double(missing) / 64 <= 0.2, !odd.isEmpty, !even.isEmpty else { continue }
                let a = median(odd), b = median(even)
                let contrast = Double(abs(a - b))
                let inside = lat.filter { $0.0 > i0 && $0.0 < i0 + 8 && $0.1 > j0 && $0.1 < j0 + 8 }.count
                // The ring round it should not carry the pattern on; the far side is left out,
                // where the pieces stand in front of it.
                let sides: [[(Int, Int)]] = [(1...8).map { (0, $0) }, (1...8).map { (9, $0) },
                                             (1...8).map { ($0, 0) }, (1...8).map { ($0, 9) }]
                let centreY = { (cells: [(Int, Int)]) -> Double in
                    cells.map { Double(H.map(Double(i0 - 1 + $0.0) + 0.5, Double(j0 - 1 + $0.1) + 0.5).y) }.reduce(0, +) / Double(cells.count)
                }
                let far = sides.indices.min { centreY(sides[$0]) < centreY(sides[$1]) }!
                var ring: [Double] = []
                for (s, cells) in sides.enumerated() where s != far {
                    for (x, y) in cells {
                        guard let val = v[y][x] else { continue }
                        let expectOdd = ((x - 1) + (y - 1) + 4) % 2 == 1
                        ring.append(Double(val - (a + b) / 2) / (Double(a - b) / 2 + 1e-6) * (expectOdd ? 1 : -1))
                    }
                }
                let carry = ring.isEmpty ? 0 : max(0, ring.reduce(0, +) / Double(ring.count))
                // Every row and column of a board alternates light and dark, square to square. A
                // block taking in a row of the board's wooden frame has a line that does not
                // (pieces spoil single squares, which the medians shrug off, but not a whole line).
                let lines: [[(Int, Int)]] = (1...8).map { y in (1...8).map { ($0, y) } } + (1...8).map { x in (1...8).map { (x, $0) } }
                var flat = 0.0
                for line in lines {
                    var d: [Double] = []
                    for k in 0..<7 {
                        let (x, y) = line[k], (x2, y2) = line[k + 1]
                        guard let p = v[y][x], let q = v[y2][x2] else { continue }
                        let odd = ((x - 1) + (y - 1)) % 2 == 1
                        d.append(Double(p - q) * (odd == (a > b) ? 1 : -1))
                    }
                    if d.count >= 4 { flat += max(0, 0.4 - d.reduce(0, +) / Double(d.count) / (contrast + 1e-6)) }
                }
                let score = Double(inside) + 10 * contrast / 255 - 20 * carry - 10 * flat
                if best == nil || score > best!.0 { best = (score, (Double(i0), Double(j0))) }
            }
        }
        return best?.1
    }

    // MARK: - Naming the corners

    /// The four corners (in lattice order) as a1, h1, h8, a8: rank 1 the edge lowest in the
    /// picture (nearest the camera), a1 its left end.
    static func nameCorners(_ q: [CGPoint]) -> [CGPoint] {
        let sides = (0..<4).map { ($0, ($0 + 1) % 4) }
        let near = sides.max { q[$0.0].y + q[$0.1].y < q[$1.0].y + q[$1.1].y }!
        let (a1, h1) = q[near.0].x < q[near.1].x ? (near.0, near.1) : (near.1, near.0)
        let a8 = [(a1 + 1) % 4, (a1 + 3) % 4].first { $0 != h1 }!
        let h8 = (0..<4).first { ![a1, h1, a8].contains($0) }!
        return [q[a1], q[h1], q[h8], q[a8]]
    }

    /// How cleanly the board's squares alternate light and dark, either way round: the share of
    /// the squares in the picture whose near part is on the side of the median their colour puts
    /// them. About 1 for the board itself; near a half for a grid sheared across the squares.
    static func checkerScore(_ grey: [Float], _ w: Int, _ h: Int, _ board: Projective) -> Double {
        var values: [(Float, Bool)] = []
        for f in 0..<8 {
            for r in 0..<8 {
                guard let v = squareValue(grey, w, h, board, Double(f), Double(r)) else { continue }
                values.append((v, (f + r) % 2 == 0))
            }
        }
        guard values.count >= 32 else { return 0 }
        let m = median(values.map(\.0))
        let agree = values.filter { ($0.0 < m) == $0.1 }.count
        return Double(max(agree, values.count - agree)) / Double(values.count)
    }

    /// Whether the dark squares (a1's colour) are clearly darker than the light ones; nil when too
    /// few squares are in the picture to tell.
    static func coloursAgree(_ grey: [Float], _ w: Int, _ h: Int, _ board: Projective) -> Bool? {
        var dark: [Float] = [], light: [Float] = []
        for f in 0..<8 {
            for r in 0..<8 {
                guard let v = squareValue(grey, w, h, board, Double(f), Double(r)) else { continue }
                if (f + r) % 2 == 0 { dark.append(v) } else { light.append(v) }
            }
        }
        guard dark.count >= 16, light.count >= 16 else { return nil }
        return median(dark) < median(light) - 30
    }
}

/// A small, seedable random number generator, so the search is repeatable.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}
