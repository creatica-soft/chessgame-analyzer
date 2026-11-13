import SwiftUI

/// The editing tools: move, erase, and one button per piece.
struct PiecePalette: View {
    let selected: EditTool
    let onSelect: (EditTool) -> Void

    private static let kinds: [PieceKind] = [.king, .queen, .rook, .bishop, .knight, .pawn]

    var body: some View {
        VStack(spacing: 6) {
            row(first: .move, symbol: "hand.point.up.left", label: "Move", color: .white)
            row(first: .erase, symbol: "eraser", label: "Erase", color: .black)
        }
    }

    private func row(first tool: EditTool, symbol: String, label: String, color: PieceColor) -> some View {
        HStack(spacing: 4) {
            button(tool, label: label) {
                Image(systemName: symbol).font(.title3)
            }
            ForEach(Self.kinds, id: \.self) { kind in
                let piece = Piece(color, kind)
                button(.place(piece), label: "\(color == .white ? "White" : "Black") \(kind)") {
                    PieceGlyph(piece: piece)
                }
            }
        }
    }

    private func button(_ tool: EditTool, label: String, @ViewBuilder content: () -> some View) -> some View {
        Button { onSelect(tool) } label: {
            content()
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected == tool ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected == tool ? Color.accentColor : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected == tool ? .isSelected : [])
    }
}

/// One piece, drawn the same way the board draws it.
struct PieceGlyph: View {
    let piece: Piece
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Text(piece.solidGlyph).foregroundStyle(piece.color == .white ? Color.white : Color.black)
            if piece.color == .white {
                Text(piece.outlineGlyph).foregroundStyle(Color.black)
            }
        }
        .font(.system(size: size))
    }
}
