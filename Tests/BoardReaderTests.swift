import Testing
import UIKit
@testable import ChessAnalyzer

private final class FixtureToken {}

/// Frames of video of a real board, from clips left out of the classifier's training
/// (tools/board3d), with the positions from the game they were filmed in.
struct BoardReaderTests {
    static func photo(_ name: String) -> UIImage {
        let path = Bundle(for: FixtureToken.self).path(forResource: name, ofType: "jpg")!
        return UIImage(contentsOfFile: path)!
    }

    static let frames: [(name: String, fen: String, corners: [CGPoint])] = [
        // Corners a1, h1, h8, a8 as tools/board3d/locate.py found them.
        ("board-9065", "r5k1/pp2prbp/6p1/1qpQ1bN1/5P2/5P2/PP3PKP/R6R",
         [CGPoint(x: 155.5, y: 495.0), CGPoint(x: 814.5, y: 583.2), CGPoint(x: 884.5, y: 169.4), CGPoint(x: 411.0, y: 142.7)]),
        ("board-9097", "6k1/p3p1rp/6p1/8/3bNP2/1P3P1b/P4P1P/2q2QK1",
         [CGPoint(x: 149.2, y: 406.9), CGPoint(x: 797.6, y: 596.4), CGPoint(x: 932.7, y: 168.4), CGPoint(x: 455.9, y: 74.0)]),
    ]

    @Test(arguments: frames.indices)
    func findsTheBoardWhereThePrototypeDid(_ i: Int) throws {
        let frame = Self.frames[i]
        let photo = try #require(DiagramReader.upright(Self.photo(frame.name)))
        let found = try #require(BoardFinder.find(photo))
        // Within a fifth of a square of each corner, in the same order (a1 first).
        let square = hypot(frame.corners[1].x - frame.corners[0].x, frame.corners[1].y - frame.corners[0].y) / 8
        for (a, b) in zip(found, frame.corners) {
            #expect(hypot(a.x - b.x, a.y - b.y) < square / 5, "\(frame.name): \(a) against \(b)")
        }
    }

    @Test(arguments: frames.indices)
    func readsTheFrame(_ i: Int) async throws {
        let frame = Self.frames[i]
        let reading = try await BoardReader.read(Self.photo(frame.name))
        let expected = try Position(fen: frame.fen + " w - - 0 1")
        let wrong = (0..<64).filter { reading.pieces[$0] != expected[$0] }
        print("BOARD \(frame.name): wrong \(wrong.map(\.algebraic)) doubtful \(reading.doubtful.map(\.algebraic))")
        #expect(wrong.count <= 1)
        #expect(reading.kind == .board)
    }
}
