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
        // The board turned about 45 degrees (found by the ring check), from clips filmed while it
        // was turned round; corners as named from the camera, before the pieces settle a half turn.
        // For 9137 the prototype's grid was pulled out by the printed border: these are checked by eye.
        ("board-9137", "r1bq1rk1/pp2ppbp/2n3p1/2p5/2BPNn2/4PN2/PP3PPP/R2QK2R",
         [CGPoint(x: 265, y: 360), CGPoint(x: 597, y: 694), CGPoint(x: 955, y: 324), CGPoint(x: 590, y: 152)]),
        ("board-9162", "6k1/p2qprbp/6p1/1p3bN1/1Qr2P2/5P2/PP3PKP/R3R3",
         [CGPoint(x: 751.4, y: 648.5), CGPoint(x: 1009.7, y: 353.0), CGPoint(x: 688.8, y: 165.0), CGPoint(x: 391.9, y: 364.8)]),
    ]

    @Test(arguments: frames.indices)
    func findsTheBoardWhereThePrototypeDid(_ i: Int) throws {
        let frame = Self.frames[i]
        let photo = try #require(DiagramReader.upright(Self.photo(frame.name)))
        let found = try #require(BoardFinder.find(photo))
        // Within a quarter of a square of each corner, in the same order (a1 first).
        let square = hypot(frame.corners[1].x - frame.corners[0].x, frame.corners[1].y - frame.corners[0].y) / 8
        for (a, b) in zip(found, frame.corners) {
            #expect(hypot(a.x - b.x, a.y - b.y) < square / 4, "\(frame.name): \(a) against \(b)")
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

    /// Frames combined: named from either dark corner, they are lined up with each other, and the
    /// reading settles on the position once it has held for a few frames.
    @Test func liveReadingSettles() throws {
        let frame = Self.frames[0]
        let photo = try #require(DiagramReader.upright(Self.photo(frame.name)))
        let read = try BoardReader.read(frame: photo)
        var live = LiveBoardReader()
        for i in 0..<6 {
            #expect(live.add(i % 2 == 0 ? read : read.turned) == .added)
        }
        #expect(live.isSettled)
        let reading = try live.reading()
        let expected = try Position(fen: frame.fen + " w - - 0 1")
        #expect((0..<64).filter { reading.pieces[$0] != expected[$0] }.count <= 1)
        // A frame of another position altogether is left out, until several in a row restart it.
        let other = try BoardReader.read(frame: #require(DiagramReader.upright(Self.photo("board-9137"))))
        #expect(live.add(other) == .rejected)
        for _ in 0..<2 { live.add(other) }
        #expect(live.add(other) == .restarted)
    }

    /// A frame on its side (the phone held sideways, the frame not turned by it) is turned upright
    /// from the board itself, the far side to the top, and read as the upright frame is.
    @Test(arguments: [1, 2, 3])
    func readsAFrameOnItsSide(_ quarterTurns: Int) throws {
        for frame in Self.frames.prefix(2) {
            let photo = try #require(DiagramReader.upright(Self.photo(frame.name)))
            let sideways = try #require(BoardReader.rotated(photo, quarterTurns: quarterTurns))
            #expect(BoardReader.uprightTurns(try #require(BoardFinder.find(photo))) == 0)
            let read = try BoardReader.read(frame: sideways)
            #expect(read.turns == (4 - quarterTurns) % 4, "\(frame.name)")
            var live = LiveBoardReader()
            live.add(read)
            let reading = try live.reading()
            let expected = try Position(fen: frame.fen + " w - - 0 1")
            #expect((0..<64).filter { reading.pieces[$0] != expected[$0] }.count <= 1, "\(frame.name)")
        }
    }
}
