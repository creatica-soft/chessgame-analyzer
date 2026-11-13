import SwiftUI

/// The board, drawn in one Canvas. Taps are mapped to squares from their location.
struct BoardView: View {
    let position: Position
    let flipped: Bool
    let selected: Square?
    /// The engine's best move, drawn as an arrow.
    let bestMove: (from: Square, to: Square)?
    /// The move that led to this position, tinted.
    var lastMove: (from: Square, to: Square)? = nil
    let onTap: (Square) -> Void

    /// The from and to squares of a long-algebraic move.
    static func squares(ofUCI move: String) -> (from: Square, to: Square)? {
        guard move.count >= 4,
              let from = Square(algebraic: move.prefix(2)),
              let to = Square(algebraic: move.dropFirst(2).prefix(2)) else { return nil }
        return (from, to)
    }

    static let light = Color(red: 0.94, green: 0.85, blue: 0.71)
    static let dark = Color(red: 0.71, green: 0.53, blue: 0.39)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Canvas { context, _ in
                draw(in: &context, cell: side / 8)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let col = Int(location.x / (side / 8)), row = Int(location.y / (side / 8))
                guard (0..<8).contains(col), (0..<8).contains(row) else { return }
                onTap(square(row: row, col: col))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Chess board")
        .accessibilityValue(position.fen)
    }

    private func square(row: Int, col: Int) -> Square {
        flipped ? Square.at(file: 7 - col, rank: row) : Square.at(file: col, rank: 7 - row)
    }

    private func origin(of sq: Square, cell: CGFloat) -> CGPoint {
        let col = flipped ? 7 - sq.file : sq.file
        let row = flipped ? sq.rank : 7 - sq.rank
        return CGPoint(x: CGFloat(col) * cell, y: CGFloat(row) * cell)
    }

    private func center(of sq: Square, cell: CGFloat) -> CGPoint {
        let o = origin(of: sq, cell: cell)
        return CGPoint(x: o.x + cell / 2, y: o.y + cell / 2)
    }

    private func draw(in context: inout GraphicsContext, cell: CGFloat) {
        let highlighted: Set<Square> = bestMove.map { [$0.from, $0.to] } ?? []
        let previous: Set<Square> = lastMove.map { [$0.from, $0.to] } ?? []
        for sq in 0..<64 {
            let rect = CGRect(origin: origin(of: sq, cell: cell), size: CGSize(width: cell, height: cell))
            let isLight = (sq.file + sq.rank) % 2 == 1
            context.fill(Path(rect), with: .color(isLight ? Self.light : Self.dark))
            if previous.contains(sq) {
                context.fill(Path(rect), with: .color(.yellow.opacity(0.32)))
            }
            if highlighted.contains(sq) {
                context.fill(Path(rect), with: .color(.green.opacity(0.28)))
            }
            if sq == selected {
                context.fill(Path(rect), with: .color(.yellow.opacity(0.55)))
            }
            drawCoordinates(for: sq, in: rect, isLight: isLight, context: &context, cell: cell)
        }
        for sq in 0..<64 {
            guard let piece = position[sq] else { continue }
            drawPiece(piece, at: center(of: sq, cell: cell), cell: cell, context: &context)
        }
        if let move = bestMove {
            drawArrow(from: center(of: move.from, cell: cell), to: center(of: move.to, cell: cell),
                      cell: cell, context: &context)
        }
    }

    private func drawCoordinates(for sq: Square, in rect: CGRect, isLight: Bool,
                                 context: inout GraphicsContext, cell: CGFloat) {
        let color = isLight ? Self.dark : Self.light
        let font = Font.system(size: cell * 0.2, weight: .semibold)
        let bottomRow = flipped ? sq.rank == 7 : sq.rank == 0
        let leftCol = flipped ? sq.file == 7 : sq.file == 0
        if bottomRow {
            let letter = String(Array("abcdefgh")[sq.file])
            context.draw(Text(letter).font(font).foregroundStyle(color),
                         at: CGPoint(x: rect.maxX - cell * 0.1, y: rect.maxY - cell * 0.13), anchor: .center)
        }
        if leftCol {
            context.draw(Text("\(sq.rank + 1)").font(font).foregroundStyle(color),
                         at: CGPoint(x: rect.minX + cell * 0.1, y: rect.minY + cell * 0.14), anchor: .center)
        }
    }

    private func drawPiece(_ piece: Piece, at point: CGPoint, cell: CGFloat, context: inout GraphicsContext) {
        let font = Font.system(size: cell * 0.78)
        // A solid glyph coloured in, then for White the outline glyph on top as its border.
        let fill: Color = piece.color == .white ? .white : .black
        context.draw(Text(piece.solidGlyph).font(font).foregroundStyle(fill), at: point)
        if piece.color == .white {
            context.draw(Text(piece.outlineGlyph).font(font).foregroundStyle(.black), at: point)
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, cell: CGFloat, context: inout GraphicsContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let ux = dx / length, uy = dy / length
        let head = cell * 0.42, width = cell * 0.16
        let shaftEnd = CGPoint(x: b.x - ux * head, y: b.y - uy * head)

        var shaft = Path()
        shaft.move(to: a)
        shaft.addLine(to: shaftEnd)
        let color = Color(red: 0.1, green: 0.55, blue: 0.25).opacity(0.8)
        context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))

        var tip = Path()
        tip.move(to: b)
        tip.addLine(to: CGPoint(x: shaftEnd.x - uy * head * 0.6, y: shaftEnd.y + ux * head * 0.6))
        tip.addLine(to: CGPoint(x: shaftEnd.x + uy * head * 0.6, y: shaftEnd.y - ux * head * 0.6))
        tip.closeSubpath()
        context.fill(tip, with: .color(color))
    }
}
