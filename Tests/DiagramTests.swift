import CoreML
import Testing
import UIKit
@testable import ChessAnalyzer

/// The diagram reader on rendered book pages: board found, straightened, every square read.
struct DiagramTests {
    static func boardField(_ fen: String) -> String { String(fen.split(separator: " ")[0]) }

    @Test func readsABookDiagramOnATiltedPage() async throws {
        let reading = try await DiagramReader.read(DemoGame.diagram())
        let expected = try Position(fen: DemoGame.operaFinal)
        // The pieces are drawn with iOS's chess symbols, a style the classifier was not trained
        // on. As of the first model it misreads one square here (the bishop on g5 as a pawn), and
        // is sure of it: in a style it has never seen, a mistake is not always marked doubtful.
        let wrong = (0..<64).filter { reading.pieces[$0] != expected[$0] }
        #expect(wrong.count <= 1, "wrong \(wrong.map(\.algebraic))")
        #expect(!reading.flipped)
    }

    @Test func readsAnotherFont() async throws {
        let start = Position.startFEN
        let reading = try await DiagramReader.read(DemoGame.diagram(fen: start, degrees: -3, font: "Courier"))
        // iOS's chess symbols again, a style the classifier was not trained on.
        let expected = Position.start
        let wrong = (0..<64).filter { reading.pieces[$0] != expected[$0] }
        #expect(wrong.count <= 1, "wrong \(wrong.map(\.algebraic))")
        // King and rooks at home: castling is allowed.
        #expect(reading.position(sideToMove: .white).castling.isSuperset(of: [.blackKingside, .blackQueenside]))
    }

    @Test func turnsABoardPrintedFromBlacksSide() async throws {
        // The start position upside down: Black's pieces at the bottom.
        let image = DemoGame.diagram(fen: "RNBKQBNR/PPPPPPPP/8/8/8/8/pppppppp/rnbkqbnr w - - 0 1", degrees: 0)
        let reading = try await DiagramReader.read(image)
        #expect(reading.flipped)
        // iOS's chess symbols are a style the classifier was not trained on (see above).
        let start = Position.start
        let wrong = (0..<64).filter { reading.pieces[$0] != start[$0] }
        #expect(wrong.count <= 1, "wrong \(wrong.map(\.algebraic))")
    }

    @Test func aPageWithoutABoard() async throws {
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { c in
            UIColor.white.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            ("No diagram on this page." as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
        }
        await #expect(throws: DiagramReader.ReadError.self) { try await DiagramReader.read(blank) }
    }
}

/// What a diagram cannot show: castling and en passant, offered only where possible.
struct DiagramPositionTests {
    static func reading(_ fen: String) throws -> DiagramReader.Reading {
        let position = try Position(fen: fen)
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.cgImage!
        return DiagramReader.Reading(pieces: (0..<64).map { position[$0] }, uncertain: Array(repeating: false, count: 64),
                                     board: blank, quad: .init(topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero),
                                     flipped: false)
    }

    @Test func cornersAreNamedByWhereTheyAre() {
        let tl = CGPoint(x: 10, y: 12), tr = CGPoint(x: 110, y: 8), br = CGPoint(x: 115, y: 105), bl = CGPoint(x: 6, y: 100)
        let right = DiagramReader.Quad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
        // Left and right swapped (the board would read mirrored), a crossed outline, and turned.
        let mirrored = DiagramReader.Quad(topLeft: tr, topRight: tl, bottomRight: bl, bottomLeft: br)
        let crossed = DiagramReader.Quad(topLeft: tl, topRight: br, bottomRight: tr, bottomLeft: bl)
        let turned = DiagramReader.Quad(topLeft: br, topRight: bl, bottomRight: tl, bottomLeft: tr)
        for q in [right, mirrored, crossed, turned] { #expect(q.ordered == right) }
    }

    @Test func castlingOnlyWhereKingAndRookAreHome() throws {
        // White's king and h1 rook at home, a1 rook gone; Black's king moved.
        let r = try Self.reading("r3k2r/8/8/8/8/8/8/1R2K2R w - - 0 1")
        #expect(r.possibleCastling == [.whiteKingside, .blackKingside, .blackQueenside])
        #expect(r.position(sideToMove: .white).castling == r.possibleCastling)
        // Turned off by the user; and a right the diagram can't allow is never given.
        #expect(r.position(sideToMove: .white, castling: [.whiteQueenside]).castling == [])
    }

    @Test func enPassantOnlyAfterAPossibleDoubleStep() throws {
        // Black pawn on e5 with e6 and e7 empty, White pawn on d5 beside it: ...e7-e5 is possible.
        let r = try Self.reading("4k3/8/8/3Pp3/8/8/8/4K3 w - - 0 1")
        #expect(r.possibleEnPassant(sideToMove: .white) == [Square(algebraic: "e6")!])
        #expect(r.possibleEnPassant(sideToMove: .black).isEmpty)
        #expect(r.position(sideToMove: .white, enPassant: Square(algebraic: "e6")).fen.contains(" e6 "))
        // Not offered when the pawn could not have come from e7.
        let blocked = try Self.reading("4k3/4b3/8/3Pp3/8/8/8/4K3 w - - 0 1")
        #expect(blocked.possibleEnPassant(sideToMove: .white).isEmpty)
    }
}

struct DiagramCropTests {
    @Test func aPictureCroppedToTheBoard() async throws {
        // The demo page cut down to the board itself: no rectangle to find inside it.
        let page = try #require(DiagramReader.upright(DemoGame.diagram(degrees: 0)))
        // The page is drawn 1000 points wide, at the screen's scale, then fitted into 2000 pixels.
        let k = Double(page.width) / 1000
        let board = try #require(page.cropping(to: CGRect(x: 220 * k, y: 300 * k, width: 560 * k, height: 560 * k)))
        let reading = try await DiagramReader.read(UIImage(cgImage: board))
        #expect(reading.pieces.compactMap { $0 }.count == 20)   // the Opera Game's final position
    }
}

/// The corrections made after the classifier: one king each, no pawns on the edge ranks,
/// identical squares read alike.
struct DiagramRefineTests {
    static let k = DiagramReader.classes.count
    static func onehot(_ piece: Piece?, _ p: Double = 0.9) -> [Double] {
        let i = DiagramReader.classes.firstIndex(of: piece)!
        return (0..<k).map { $0 == i ? p : (1 - p) / Double(k - 1) }
    }
    /// Cells all different: a distinct pattern in each.
    static func distinctCells() -> MLMultiArray {
        let a = try! MLMultiArray(shape: [64, 1, 32, 32], dataType: .float32)
        let d = a.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<64 { for j in 0..<1024 { d[i * 1024 + j] = Float32((i * 37 + j * (i + 3)) % 256) } }
        return a
    }
    static func best(_ row: [Double]) -> Piece? { DiagramReader.classes[row.indices.max { row[$0] < row[$1] }!] }

    @Test func aMissingKingIsTheLikeliestOne() {
        var p = (0..<64).map { _ in Self.onehot(nil) }
        p[4] = Self.onehot(Piece(.black, .king))
        // White's king read as a queen, with some king probability.
        var row = Self.onehot(Piece(.white, .queen), 0.6)
        row[DiagramReader.classes.firstIndex(of: Piece(.white, .king))!] = 0.35
        p[60] = row
        let r = DiagramReader.refine(p, cells: Self.distinctCells())
        #expect(Self.best(r[60]) == Piece(.white, .king))
        #expect(DiagramReader.isDoubtful(r[60]))   // shown as doubtful
    }

    @Test func aSecondKingIsDemoted() {
        var p = (0..<64).map { _ in Self.onehot(nil) }
        p[4] = Self.onehot(Piece(.black, .king), 0.95)
        p[60] = Self.onehot(Piece(.white, .king))
        var row = Self.onehot(Piece(.black, .king), 0.5)
        row[DiagramReader.classes.firstIndex(of: Piece(.black, .queen))!] = 0.4
        p[20] = row
        let r = DiagramReader.refine(p, cells: Self.distinctCells())
        #expect(Self.best(r[20]) == Piece(.black, .queen))
        #expect(Self.best(r[4]) == Piece(.black, .king))
    }

    @Test func noPawnOnTheEdgeRows() {
        var p = (0..<64).map { _ in Self.onehot(nil) }
        p[4] = Self.onehot(Piece(.black, .king)); p[60] = Self.onehot(Piece(.white, .king))
        var row = Self.onehot(Piece(.white, .pawn), 0.6)
        row[DiagramReader.classes.firstIndex(of: Piece(.white, .bishop))!] = 0.3
        p[2] = row
        #expect(Self.best(DiagramReader.refine(p, cells: Self.distinctCells())[2]) == Piece(.white, .bishop))
    }

    @Test func identicalSquaresAreReadAlike() {
        let cells = Self.distinctCells()
        let d = cells.dataPointer.assumingMemoryBound(to: Float32.self)
        // Squares 18 and 20 (same colour) and 36 hold the same picture.
        for j in 0..<1024 { d[20 * 1024 + j] = d[18 * 1024 + j]; d[36 * 1024 + j] = d[18 * 1024 + j] }
        var p = (0..<64).map { _ in Self.onehot(nil) }
        p[4] = Self.onehot(Piece(.black, .king)); p[60] = Self.onehot(Piece(.white, .king))
        p[18] = Self.onehot(Piece(.white, .bishop), 0.95)
        p[20] = Self.onehot(Piece(.white, .bishop), 0.9)
        p[36] = Self.onehot(Piece(.white, .pawn), 0.5)   // the odd one out, unsure
        let r = DiagramReader.refine(p, cells: cells)
        #expect(Self.best(r[36]) == Piece(.white, .bishop))
        #expect(DiagramReader.identicalGroups(cells).contains([18, 20, 36]))
    }
}
