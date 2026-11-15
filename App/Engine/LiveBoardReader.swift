import CoreGraphics
import Foundation

/// Reads a real board from a stream of camera frames: each frame is read on its own
/// (`BoardReader.read(frame:)`), and the last few frames' readings are averaged, so that a piece
/// misread in one frame, or hidden from one angle, is outvoted by the others. The reading has
/// settled when the averaged board has stayed the same for several frames with no square unsure.
struct LiveBoardReader {
    /// How many of the latest frames are averaged.
    var window = 8
    /// Frames the averaged board must stay unchanged for before it counts as settled.
    var steadyFrames = 4
    /// A frame differing from the average in more squares than this is taken to be misread (a
    /// grid placed wrong) and left out; after `restartAfter` such frames in a row, the average is
    /// started again from the new frames (the board, or the camera, has moved on).
    var maxDisagreement = 12
    var restartAfter = 4

    private(set) var frames: [BoardReader.Frame] = []
    /// Consecutive frames the averaged board has stayed the same for.
    private(set) var steady = 0
    private var rejectedInARow = 0
    private var lastBoard: [Int]?

    enum Outcome: Equatable { case added, rejected, restarted }

    /// Adds a frame's reading. A frame's board is named so that a1 is a dark corner, which may be
    /// either of two corners half a turn apart: it is turned to whichever fits the average better.
    @discardableResult
    mutating func add(_ frame: BoardReader.Frame) -> Outcome {
        guard !frames.isEmpty else { frames = [frame]; settle(); return .added }
        let mean = average
        func fit(_ p: [[Double]]) -> Double {
            (0..<64).map { sq in zip(mean[sq], p[sq]).map { $0 * $1 }.reduce(0, +) }.reduce(0, +)
        }
        let aligned = fit(frame.turned.probabilities) > fit(frame.probabilities) ? frame.turned : frame
        let differing = (0..<64).filter { Self.best(aligned.probabilities[$0]) != Self.best(mean[$0]) }.count
        if differing > maxDisagreement {
            rejectedInARow += 1
            guard rejectedInARow >= restartAfter else { return .rejected }
            frames = [frame]
            rejectedInARow = 0
            lastBoard = nil
            settle()
            return .restarted
        }
        rejectedInARow = 0
        frames.append(aligned)
        if frames.count > window { frames.removeFirst(frames.count - window) }
        settle()
        return .added
    }

    private mutating func settle() {
        let board = average.map(Self.best)
        steady = board == lastBoard ? steady + 1 : 0
        lastBoard = board
    }

    /// Per square, the frames' probabilities averaged.
    var average: [[Double]] {
        guard let first = frames.first else { return [] }
        var sum = first.probabilities
        for f in frames.dropFirst() {
            for sq in 0..<64 { for c in 0..<sum[sq].count { sum[sq][c] += f.probabilities[sq][c] } }
        }
        let n = Double(frames.count)
        return sum.map { $0.map { $0 / n } }
    }

    /// The squares (a1 = 0, as the frames are named) unsure in the average.
    var doubtful: [Int] {
        let p = average
        guard !p.isEmpty else { return [] }
        let constrained = DiagramReader.constrain(p)
        return (0..<64).filter { DiagramReader.isDoubtful(constrained[$0]) }
    }

    var isSettled: Bool { frames.count >= steadyFrames + 1 && steady >= steadyFrames && doubtful.isEmpty }

    /// The reading of the averaged frames, shown on the latest frame's photo; the board turned
    /// round if White's pawns and king stand on the far side.
    func reading() throws -> DiagramReader.Reading {
        guard var frame = frames.last else { throw DiagramReader.ReadError.noBoard }
        var p = average
        if BoardReader.whiteStandsHigh(p) {
            frame = frame.turned
            p = p.reversed()
        }
        return try BoardReader.reading(frame, probabilities: p)
    }

    private static func best(_ row: [Double]) -> Int {
        row.indices.max { row[$0] < row[$1] } ?? 0
    }
}
