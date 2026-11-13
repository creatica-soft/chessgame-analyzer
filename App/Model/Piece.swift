import Foundation

enum PieceColor: Sendable, Hashable, CaseIterable {
    case white, black

    var opposite: PieceColor { self == .white ? .black : .white }
}

enum PieceKind: Sendable, Hashable, CaseIterable {
    case king, queen, rook, bishop, knight, pawn

    /// The lowercase FEN letter.
    var letter: Character {
        switch self {
        case .king: "k"
        case .queen: "q"
        case .rook: "r"
        case .bishop: "b"
        case .knight: "n"
        case .pawn: "p"
        }
    }
}

struct Piece: Sendable, Hashable {
    let color: PieceColor
    let kind: PieceKind

    init(_ color: PieceColor, _ kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    init?(fenLetter: Character) {
        guard let kind = PieceKind.allCases.first(where: { $0.letter == Character(fenLetter.lowercased()) }) else {
            return nil
        }
        self.init(fenLetter.isUppercase ? .white : .black, kind)
    }

    var fenLetter: Character {
        color == .white ? Character(kind.letter.uppercased()) : kind.letter
    }

    /// The solid glyph from the Unicode "black" chess set. The board draws every piece with it and
    /// colours it, which keeps white and black pieces exactly the same shape and size.
    var solidGlyph: String {
        let scalar: String = switch kind {
        case .king: "\u{265A}"
        case .queen: "\u{265B}"
        case .rook: "\u{265C}"
        case .bishop: "\u{265D}"
        case .knight: "\u{265E}"
        case .pawn: "\u{265F}"
        }
        // U+FE0E asks for the text presentation; without it iOS draws the pawn as an emoji.
        return scalar + "\u{FE0E}"
    }

    /// The outline glyph from the Unicode "white" set, drawn over a white piece as its border.
    var outlineGlyph: String {
        let scalar: String = switch kind {
        case .king: "\u{2654}"
        case .queen: "\u{2655}"
        case .rook: "\u{2656}"
        case .bishop: "\u{2657}"
        case .knight: "\u{2658}"
        case .pawn: "\u{2659}"
        }
        return scalar + "\u{FE0E}"
    }
}
