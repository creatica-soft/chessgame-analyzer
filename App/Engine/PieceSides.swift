import CoreML
import Foundation

/// Which side each piece is on, settled per board from the pieces' colours.
///
/// The classifier reads lightness only, so that it carries over to sets of any colours, and tells
/// the sides apart by how light they are. That fails for sets whose two sides are alike in
/// lightness and differ in colour, as gold against silver. But on any one board the two sides'
/// pieces are of two colours: each side's colour is taken from the pieces the classifier is sure
/// of, every piece is placed between the two, and that adds to (or outweighs) the classifier's own
/// odds for its side, the more the further apart the two colours are against how much each side's
/// pieces differ among themselves. Where the sides do not differ in colour, nothing changes.
/// Developed and measured on clip frames in tools/work (sides_eval.py): on the gold and silver set
/// filmed outdoors, pieces read on the wrong side fell from 54 to 4 in 42 frames.
extension BoardReader {
    /// Where in a crop (96 x 48) the square's own piece stands: low and in the middle.
    static let pieceRows = 52..<86, pieceColumns = 18..<30

    /// The 64 squares' probabilities with the sides re-weighed by the pieces' colours in `crops`.
    static func settleSides(_ p: [[Double]], crops: MLMultiArray) -> [[Double]] {
        settleSides(p, colours: pieceColours(crops))
    }

    /// Per square, CIE Lab lightness and chroma (L*, a*, b*) averaged where its own piece stands.
    static func pieceColours(_ crops: MLMultiArray) -> [[Double]] {
        let cw = cropWidth, plane = cropHeight * cropWidth
        let x = crops.dataPointer.assumingMemoryBound(to: Float32.self)
        return (0..<64).map { sq in
            var sum = [0.0, 0.0, 0.0], n = 0.0
            for v in pieceRows {
                for u in pieceColumns {
                    let i = sq * 3 * plane + v * cw + u
                    let lab = Self.lab(Double(x[i]), Double(x[i + plane]), Double(x[i + 2 * plane]))
                    for c in 0..<3 { sum[c] += lab[c] }
                    n += 1
                }
            }
            return sum.map { $0 / n }
        }
    }

    /// sRGB (0...255) to CIE Lab, D65.
    static func lab(_ r: Double, _ g: Double, _ b: Double) -> [Double] {
        func linear(_ c: Double) -> Double { let c = c / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
    }

    /// `p` (classes as `DiagramReader.classes`: empty, White's six, Black's six) with each piece's
    /// side re-weighed by its colour, `colours` as `pieceColours`.
    static func settleSides(_ p: [[Double]], colours d: [[Double]]) -> [[Double]] {
        let occupied = p.map { 1 - $0[0] }
        let white = p.map { row -> Double in
            let all = row[1...].reduce(0, +)
            return all > 1e-9 ? row[1...6].reduce(0, +) / all : 0.5
        }
        func logit(_ q: Double) -> Double { let q = min(max(q, 1e-4), 1 - 1e-4); return log(q / (1 - q)) }
        let classifierOdds = white.map(logit)
        var posterior = white
        /// The weighted median of `v`.
        func median(_ v: [Double], _ w: [Double]) -> Double {
            let order = v.indices.sorted { v[$0] < v[$1] }
            let half = w.reduce(0, +) / 2
            var sum = 0.0
            for i in order { sum += w[i]; if sum >= half { return v[i] } }
            return v[order.last!]
        }
        for _ in 0..<2 {
            // Each side's colour from the pieces the classifier (and, after the first round, the
            // colour too) is sure of...
            let sureWhite = (0..<64).map { occupied[$0] * pow(min(max(2 * posterior[$0] - 1, 0), 1), 2) }
            let sureBlack = (0..<64).map { occupied[$0] * pow(min(max(1 - 2 * posterior[$0], 0), 1), 2) }
            var ww = sureWhite, wb = sureBlack
            var colours: (white: [Double], black: [Double], t: [Double])?
            for pass in 0..<2 {
                let sw = ww.reduce(0, +), sb = wb.reduce(0, +)
                guard sw >= 2, sb >= 2 else { break }
                let cw = (0..<3).map { c in (0..<64).map { ww[$0] * d[$0][c] }.reduce(0, +) / sw }
                let cb = (0..<3).map { c in (0..<64).map { wb[$0] * d[$0][c] }.reduce(0, +) / sb }
                let axis = (0..<3).map { cb[$0] - cw[$0] }
                let length2 = axis.map { $0 * $0 }.reduce(0, +)
                guard length2 > 1e-12 else { break }
                // Along the line between the two colours: 0 at White's, 1 at Black's.
                let t = d.map { v in (0..<3).map { (v[$0] - cw[$0]) * axis[$0] }.reduce(0, +) / length2 }
                colours = (cw, cb, t)
                // ...that are nearer its colour than the other side's: a piece the classifier is
                // sure of but wrong about (gold read as white) does not pull it.
                if pass == 0 {
                    ww = (0..<64).map { t[$0] < 0.5 ? ww[$0] : 0 }
                    wb = (0..<64).map { t[$0] > 0.5 ? wb[$0] : 0 }
                }
            }
            guard let (cw, cb, t) = colours else { return p }
            // How far each side's pieces stray from its colour: the median, which a few pieces the
            // classifier got wrong do not move.
            let spreadW = 1.4826 * median(t.map(abs), sureWhite)
            let spreadB = 1.4826 * median(t.map { abs($0 - 1) }, sureBlack)
            let spread = max(0.08, ((spreadW * spreadW + spreadB * spreadB) / 2).squareRoot())
            // Colours three spreads apart count for nothing; six and more, in full.
            let strength = min(1, max(0, (1 / spread - 3) / 3))
            posterior = (0..<64).map { 1 / (1 + exp(-(classifierOdds[$0] - (t[$0] - 0.5) / spread * strength))) }
            #if DEBUG
            if ProcessInfo.processInfo.environment["BOARD_DEBUG"] != nil {
                let notes = (0..<64).filter { occupied[$0] > 0.5 }.map { sq in
                    "\("abcdefgh".map(String.init)[sq % 8])\(sq / 8 + 1) t \(String(format: "%.2f", t[sq])) white \(String(format: "%.2f→%.2f", white[sq], posterior[sq]))" }
                print("piece sides: spread \(String(format: "%.3f", spread)) strength \(String(format: "%.2f", strength)) White \(cw.map { Int($0) }) Black \(cb.map { Int($0) }): \(notes.joined(separator: ", "))")
            }
            #endif
        }
        return (0..<64).map { sq in
            let row = p[sq]
            let pieces = row[1...].reduce(0, +)
            let kinds = (0..<6).map { row[1 + $0] + row[7 + $0] }
            let total = max(kinds.reduce(0, +), 1e-9)
            return [row[0]] + kinds.map { pieces * $0 / total * posterior[sq] } + kinds.map { pieces * $0 / total * (1 - posterior[sq]) }
        }
    }
}
