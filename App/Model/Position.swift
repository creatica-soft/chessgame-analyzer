import Foundation

/// A square index in libchess's numbering: 0 = a1, 7 = h1, 56 = a8, 63 = h8.
typealias Square = Int

extension Square {
    var file: Int { self % 8 }
    var rank: Int { self / 8 }

    static func at(file: Int, rank: Int) -> Square { rank * 8 + file }

    init?(algebraic: some StringProtocol) {
        let chars = Array(algebraic)
        guard chars.count == 2,
              let f = chars[0].asciiValue, let r = chars[1].asciiValue,
              (97...104).contains(f), (49...56).contains(r) else { return nil }
        self = Square.at(file: Int(f) - 97, rank: Int(r) - 49)
    }

    var algebraic: String {
        let files = Array("abcdefgh")
        return "\(files[file])\(rank + 1)"
    }
}

struct CastlingRights: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let whiteKingside = CastlingRights(rawValue: 1)
    static let whiteQueenside = CastlingRights(rawValue: 2)
    static let blackKingside = CastlingRights(rawValue: 4)
    static let blackQueenside = CastlingRights(rawValue: 8)
    static let all: CastlingRights = [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]

    /// FEN order, with the king and rook squares each right requires (standard chess only).
    static let ordered: [(right: CastlingRights, letter: Character, king: Square, rook: Square, piece: PieceColor)] = [
        (.whiteKingside, "K", 4, 7, .white),
        (.whiteQueenside, "Q", 4, 0, .white),
        (.blackKingside, "k", 60, 63, .black),
        (.blackQueenside, "q", 60, 56, .black),
    ]
}

enum FENError: Error, Equatable, LocalizedError {
    case fieldCount
    case badPlacement(String)
    case badSideToMove
    case badCastling
    case badEnPassant

    var errorDescription: String? {
        switch self {
        case .fieldCount: "A FEN needs at least the piece placement and the side to move."
        case .badPlacement(let why): "Bad piece placement: \(why)."
        case .badSideToMove: "The side to move must be w or b."
        case .badCastling: "Bad castling field."
        case .badEnPassant: "Bad en passant field."
        }
    }
}

/// The position being analysed: what the board editor changes and what the engine is given as a FEN.
///
/// This type only knows what a FEN can say. Whether the position is legal, and everything that
/// needs move generation (SAN, playing a move), is asked of libchess through the bridge.
struct Position: Sendable, Hashable {
    var squares: [Piece?] = Array(repeating: nil, count: 64)
    var sideToMove: PieceColor = .white
    /// What the user asked for. `fen` drops any right the placement cannot support.
    var castling: CastlingRights = []
    var enPassant: Square?
    var halfmoveClock = 0
    var fullmoveNumber = 1

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let start = try! Position(fen: startFEN)
    static let empty = Position()

    subscript(square: Square) -> Piece? {
        get { squares[square] }
        set { squares[square] = newValue }
    }

    init() {}

    init(fen: String) throws {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { throw FENError.fieldCount }

        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { throw FENError.badPlacement("expected 8 ranks, found \(ranks.count)") }
        for (i, rankText) in ranks.enumerated() {
            let rank = 7 - i
            var file = 0
            for ch in rankText {
                if let skip = ch.wholeNumberValue, (1...8).contains(skip) {
                    file += skip
                } else if let piece = Piece(fenLetter: ch) {
                    guard file < 8 else { throw FENError.badPlacement("rank \(rank + 1) is too long") }
                    squares[Square.at(file: file, rank: rank)] = piece
                    file += 1
                } else {
                    throw FENError.badPlacement("unexpected '\(ch)'")
                }
            }
            guard file == 8 else { throw FENError.badPlacement("rank \(rank + 1) has \(file) squares") }
        }

        switch fields[1] {
        case "w": sideToMove = .white
        case "b": sideToMove = .black
        default: throw FENError.badSideToMove
        }

        if fields.count > 2, fields[2] != "-" {
            for ch in fields[2] {
                guard let entry = CastlingRights.ordered.first(where: { $0.letter == ch }) else {
                    throw FENError.badCastling
                }
                castling.insert(entry.right)
            }
        }

        if fields.count > 3, fields[3] != "-" {
            guard let sq = Square(algebraic: fields[3]), sq.rank == 2 || sq.rank == 5 else {
                throw FENError.badEnPassant
            }
            enPassant = sq
        }

        if fields.count > 4, let n = Int(fields[4]), n >= 0 { halfmoveClock = n }
        if fields.count > 5, let n = Int(fields[5]), n >= 1 { fullmoveNumber = n }
    }

    /// Whether the placement allows a castling right: king and rook on their original squares.
    func supports(_ right: CastlingRights) -> Bool {
        guard let entry = CastlingRights.ordered.first(where: { $0.right == right }) else { return false }
        return self[entry.king] == Piece(entry.piece, .king) && self[entry.rook] == Piece(entry.piece, .rook)
    }

    /// The castling rights the FEN will actually carry.
    var effectiveCastling: CastlingRights {
        castling.intersection(CastlingRights(CastlingRights.ordered.map(\.right).filter(supports)))
    }

    /// The en passant square, if the placement agrees a pawn has just made a double step past it.
    var effectiveEnPassant: Square? {
        guard let ep = enPassant else { return nil }
        let (mover, pawnRank, epRank) = sideToMove == .white
            ? (PieceColor.black, 4, 5) : (PieceColor.white, 3, 2)
        guard ep.rank == epRank,
              self[Square.at(file: ep.file, rank: pawnRank)] == Piece(mover, .pawn),
              self[ep] == nil else { return nil }
        return ep
    }

    var fen: String {
        var placement = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for file in 0..<8 {
                if let piece = self[Square.at(file: file, rank: rank)] {
                    if empty > 0 { placement += String(empty); empty = 0 }
                    placement.append(piece.fenLetter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { placement += String(empty) }
            if rank > 0 { placement += "/" }
        }
        let rights = effectiveCastling
        let castlingField = CastlingRights.ordered
            .filter { rights.contains($0.right) }
            .map { String($0.letter) }
            .joined()
        return [
            placement,
            sideToMove == .white ? "w" : "b",
            castlingField.isEmpty ? "-" : castlingField,
            effectiveEnPassant?.algebraic ?? "-",
            String(halfmoveClock),
            String(fullmoveNumber),
        ].joined(separator: " ")
    }

    /// Records a manual edit. Edits are not moves, so an en passant square no longer applies.
    mutating func edit(_ change: (inout [Piece?]) -> Void) {
        change(&squares)
        enPassant = nil
    }
}
