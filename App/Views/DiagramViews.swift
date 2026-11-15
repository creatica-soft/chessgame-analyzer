import PhotosUI
import SwiftUI

/// Above the board while a diagram's reading is checked: what was read and how sure it was,
/// the picture to compare with, turning the board round, and Done.
struct DiagramCheckBar: View {
    @Bindable var model: AnalysisModel
    let reading: DiagramReader.Reading
    @Binding var showingPicture: Bool
    /// Opens the corners for setting by hand.
    let onAdjust: () -> Void
    /// The en passant square chosen, if the last move may have been a pawn's double step.
    @State private var enPassant: Square?

    private static let castling: [(right: CastlingRights, side: PieceColor, label: String)] = [
        (.whiteKingside, .white, "O-O"), (.whiteQueenside, .white, "O-O-O"),
        (.blackKingside, .black, "O-O"), (.blackQueenside, .black, "O-O-O"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button { showingPicture.toggle() } label: {
                    DiagramPicture(reading: reading, boardFlipped: model.flipped)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(showingPicture ? Color.accentColor : Color.secondary.opacity(0.4),
                                    lineWidth: showingPicture ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingPicture ? "Show the board" : "Show the picture")
                VStack(alignment: .leading, spacing: 2) {
                    status
                    Text(showingPicture ? "Showing the picture: tap it to go back."
                                        : "Tap the picture to compare.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    if reading.photo != nil {
                        Button("Adjust Corners", systemImage: "crop", action: onAdjust)
                            .accessibilityHint("Set the board's corners in the picture by hand")
                    }
                    Button("Turn Round", systemImage: "arrow.up.arrow.down") { model.turnDiagramRound() }
                        .accessibilityHint("The board was seen from the other side")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
            }
            gameState
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    /// What a picture cannot show: castling still allowed, en passant, and who is to move; the
    /// side to move chosen ends the check.
    @ViewBuilder
    private var gameState: some View {
        // Castling the pieces allow, a row for each side; en passant squares likewise.
        ForEach([PieceColor.white, .black], id: \.self) { side in
            let rights = Self.castling.filter { $0.side == side && model.position.supports($0.right) }
            let passing = model.position.possibleEnPassant(for: side)
            if !rights.isEmpty || !passing.isEmpty {
                HStack(spacing: 6) {
                    Text(side == .white ? "White" : "Black")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    ForEach(rights, id: \.right.rawValue) { item in
                        chip(item.label, on: model.position.effectiveCastling.contains(item.right)) {
                            model.setCastling(item.right, !model.position.effectiveCastling.contains(item.right))
                        }
                        .accessibilityLabel("\(side == .white ? "White" : "Black") may castle \(item.label == "O-O" ? "kingside" : "queenside")")
                    }
                    ForEach(passing, id: \.self) { square in
                        chip("e.p. \(square.algebraic)", on: enPassant == square) {
                            enPassant = enPassant == square ? nil : square
                        }
                        .accessibilityLabel("\(side == .white ? "White" : "Black") may take en passant on \(square.algebraic): the last move was a pawn's double step")
                    }
                }
            }
        }
        let white = model.isLegal(sideToMove: .white), black = model.isLegal(sideToMove: .black)
        // An en passant square chosen says who is to move.
        let forced: PieceColor? = enPassant.map { $0.rank == 5 ? .white : .black }
        HStack(spacing: 8) {
            Text("To move:").font(.subheadline)
            sideButton(.white, enabled: white && forced != .black)
            sideButton(.black, enabled: black && forced != .white)
        }
        if white != black, white || black {
            Text(white ? "Black can't be to move: White's king would be in check."
                       : "White can't be to move: Black's king would be in check.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sideButton(_ side: PieceColor, enabled: Bool) -> some View {
        Button(side == .white ? "White" : "Black") {
            showingPicture = false
            model.finishCheck(sideToMove: side, enPassant: enPassant)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!enabled)
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: on ? "checkmark.circle.fill" : "circle")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(on ? .accentColor : .secondary)
    }

    @ViewBuilder
    private var status: some View {
        let left = model.doubtful.count
        Group {
            if reading.doubtful.count >= 8 && left == reading.doubtful.count {
                Label(reading.kind == .board ? "Many squares uncertain: a photo from White's side, from a little above, reads best."
                                             : "Many squares uncertain: is the whole board in the picture?", systemImage: "viewfinder")
                    .foregroundStyle(.orange)
            } else if left > 0 {
                Label("\(left) square\(left == 1 ? "" : "s") to check, outlined", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            } else if reading.doubtful.isEmpty {
                Label("Every square read with confidence", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("Every uncertain square set", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .font(.subheadline.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The straightened picture of a diagram, cut to the board and turned like the board on screen,
/// so it lies square for square over it.
struct DiagramPicture: View {
    let reading: DiagramReader.Reading
    let boardFlipped: Bool

    var body: some View {
        GeometryReader { geo in
            // The straightened picture keeps a margin round the board; leave it outside the frame.
            let g = DiagramReader.Geometry.self
            let scale = (8 + 2 * g.margin) / 8
            Image(decorative: reading.board, scale: 1)
                .resizable()
                .interpolation(.medium)
                .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                .rotationEffect(reading.flipped != boardFlipped ? .degrees(180) : .zero)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The whole picture with the board's outline and its grid, the corners dragged into place by
/// hand: for a board that was not found, or was found wrongly. While a corner is dragged, a
/// magnified view of it shows where it is, above the finger.
struct CornerEditor: View {
    let photo: CGImage
    @State var quad: DiagramReader.Quad
    let note: String?
    let onRead: (DiagramReader.Quad) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dragged: Int?
    @State private var dragStart: CGPoint?

    private static let loupeSize = 120.0
    /// The loupe's scale, in points per pixel of the picture (at most 2000 pixels across): about
    /// four times the picture on screen.
    private static let zoom = 0.75

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(note ?? "Drag the corners onto the board's corners, so the grid lines fall between the squares.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                GeometryReader { geo in
                    let iw = Double(photo.width), ih = Double(photo.height)
                    let scale = min(geo.size.width / iw, geo.size.height / ih)
                    let origin = CGPoint(x: (geo.size.width - iw * scale) / 2, y: (geo.size.height - ih * scale) / 2)
                    let toView = { (p: CGPoint) in CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
                    ZStack(alignment: .topLeading) {
                        Image(decorative: photo, scale: 1)
                            .resizable()
                            .frame(width: iw * scale, height: ih * scale)
                            .offset(x: origin.x, y: origin.y)
                        Canvas { context, _ in drawGrid(in: &context, toView: toView) }
                            .allowsHitTesting(false)
                        ForEach(0..<4, id: \.self) { i in
                            handle(i, at: toView(corner(i)), scale: scale, bounds: CGSize(width: iw, height: ih))
                        }
                        if let i = dragged {
                            loupe(at: corner(i), viewPoint: toView(corner(i)), size: geo.size)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("Board Corners")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Read") {
                        dismiss()
                        onRead(quad)
                    }
                }
            }
        }
    }

    private func corner(_ i: Int) -> CGPoint {
        [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft][i]
    }

    private func setCorner(_ i: Int, _ p: CGPoint) {
        switch i {
        case 0: quad.topLeft = p
        case 1: quad.topRight = p
        case 2: quad.bottomRight = p
        default: quad.bottomLeft = p
        }
    }

    /// The outline and the lines between the squares, as the board will be cut.
    private func drawGrid(in context: inout GraphicsContext, toView: (CGPoint) -> CGPoint) {
        let h = DiagramReader.Homography(quad)
        var grid = Path(), outline = Path()
        for k in 0...8 {
            let t = Double(k) / 8
            var path = (k == 0 || k == 8) ? outline : grid
            path.move(to: toView(h.map(t, 0))); path.addLine(to: toView(h.map(t, 1)))
            path.move(to: toView(h.map(0, t))); path.addLine(to: toView(h.map(1, t)))
            if k == 0 || k == 8 { outline = path } else { grid = path }
        }
        context.stroke(grid, with: .color(.white.opacity(0.8)), lineWidth: 2.5)
        context.stroke(grid, with: .color(.accentColor), lineWidth: 1)
        context.stroke(outline, with: .color(.white.opacity(0.8)), lineWidth: 4)
        context.stroke(outline, with: .color(.accentColor), lineWidth: 2)
    }

    private func handle(_ i: Int, at p: CGPoint, scale: Double, bounds: CGSize) -> some View {
        Circle()
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Circle().fill(Color.white.opacity(0.25)))
            .frame(width: 30, height: 30)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .position(p)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil { dragStart = corner(i); dragged = i }
                    guard let start = dragStart else { return }
                    let x = start.x + value.translation.width / scale, y = start.y + value.translation.height / scale
                    setCorner(i, CGPoint(x: min(max(x, 0), bounds.width), y: min(max(y, 0), bounds.height)))
                }
                .onEnded { _ in
                    dragStart = nil
                    dragged = nil
                    // Whichever handle went where, the corners are named by where they are.
                    quad = quad.ordered
                })
            .accessibilityLabel(["Top left", "Top right", "Bottom right", "Bottom left"][i] + " corner")
    }

    /// The picture round a corner, magnified, with a cross on the corner: in the top corner away
    /// from the finger.
    private func loupe(at p: CGPoint, viewPoint: CGPoint, size: CGSize) -> some View {
        let s = Self.loupeSize, z = Self.zoom
        let x = viewPoint.x < size.width / 2 ? size.width - s - 8 : 8.0
        return ZStack(alignment: .topLeading) {
            Image(decorative: photo, scale: 1)
                .resizable()
                .frame(width: Double(photo.width) * z, height: Double(photo.height) * z)
                .offset(x: s / 2 - p.x * z, y: s / 2 - p.y * z)
            Canvas { context, _ in
                var cross = Path()
                cross.move(to: CGPoint(x: s / 2 - 12, y: s / 2)); cross.addLine(to: CGPoint(x: s / 2 + 12, y: s / 2))
                cross.move(to: CGPoint(x: s / 2, y: s / 2 - 12)); cross.addLine(to: CGPoint(x: s / 2, y: s / 2 + 12))
                context.stroke(cross, with: .color(.accentColor), lineWidth: 2)
            }
        }
        .frame(width: s, height: s, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 3))
        .shadow(radius: 4)
        .offset(x: x, y: 8)
        .allowsHitTesting(false)
    }
}

/// The plain camera: one ordinary photo, no page detection or cropping. The diagram reader finds
/// the board itself, which suits a board on a screen or a page photographed at an angle.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, @MainActor UIImagePickerControllerDelegate, @MainActor UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
