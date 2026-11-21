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
        // The board turned about 45 degrees, from clips filmed while it was turned round; corners as
        // named from the camera, before the pieces settle a half turn. These two are checked by eye
        // on the squares' corners, zoomed: the prototype's corners were pulled onto the printed
        // border's lines.
        ("board-9137", "r1bq1rk1/pp2ppbp/2n3p1/2p5/2BPNn2/4PN2/PP3PPP/R2QK2R",
         [CGPoint(x: 222, y: 373), CGPoint(x: 591, y: 690), CGPoint(x: 939, y: 319), CGPoint(x: 593, y: 146)]),
        ("board-9162", "6k1/p2qprbp/6p1/1p3bN1/1Qr2P2/5P2/PP3PKP/R3R3",
         [CGPoint(x: 755, y: 636), CGPoint(x: 1014, y: 353), CGPoint(x: 682, y: 159), CGPoint(x: 408, y: 363)]),
    ]

    @Test(arguments: frames.indices)
    func findsTheBoardWhereThePrototypeDid(_ i: Int) throws {
        let frame = Self.frames[i]
        let photo = try #require(DiagramReader.upright(Self.photo(frame.name)))
        let found = try #require(BoardFinder.find(photo))
        print("FOUND \(frame.name) \(found.map { "(\(String(format: "%.1f", $0.x)), \(String(format: "%.1f", $0.y)))" }.joined(separator: " "))")
        // Within a quarter of a square of each corner, in the same order (a1 first). The folding
        // board of 9137 is not flat, its halves at a slight angle, so no one perspective fits all
        // its square corners; there the corner nearest the camera, which the pieces hide most of
        // the X-corners round, may be up to half a square out.
        let square = hypot(frame.corners[1].x - frame.corners[0].x, frame.corners[1].y - frame.corners[0].y) / 8
        let within = frame.name == "board-9137" ? square / 2 : square / 4
        for (a, b) in zip(found, frame.corners) {
            #expect(hypot(a.x - b.x, a.y - b.y) < within, "\(frame.name): \(a) against \(b)")
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

    /// A board named from any corner is turned upright by the pieces: the quarter turns too, which
    /// the squares' colours rule out when they can be seen, but from low at a side may not.
    @Test(arguments: frames.indices.prefix(2))
    func turnsTheBoardUprightFromAnyCorner(_ i: Int) throws {
        let frame = Self.frames[i]
        let read = try BoardReader.read(frame: #require(DiagramReader.upright(Self.photo(frame.name))))
        let upright = read.rotated(BoardReader.uprightTurn(read.probabilities))
        let expected = try Position(fen: frame.fen + " w - - 0 1")
        for k in 0..<4 {
            let named = upright.rotated(k)
            #expect(BoardReader.uprightTurn(named.probabilities) == (4 - k) % 4, "\(frame.name) turned \(k)")
            #expect(named.rotated(4 - k).corners == upright.corners)
            var live = LiveBoardReader()
            live.add(named)
            let reading = try live.reading()
            #expect((0..<64).filter { reading.pieces[$0] != expected[$0] }.count <= 1, "\(frame.name) turned \(k)")
        }
    }

    /// Frames combined: named from any corner, they are lined up with each other, and the
    /// reading settles on the position once it has held for a few frames.
    @Test func liveReadingSettles() throws {
        let frame = Self.frames[0]
        let photo = try #require(DiagramReader.upright(Self.photo(frame.name)))
        let read = try BoardReader.read(frame: photo)
        var live = LiveBoardReader()
        for i in 0..<6 {
            #expect(live.add(read.rotated(i % 4)) == .added)
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
