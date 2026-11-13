import PhotosUI
import SwiftUI

/// A diagram read from a picture, before it replaces the board: the picture as it was cut,
/// beside the position read, with the doubtful squares marked.
struct DiagramReviewSheet: View {
    @State var reading: DiagramReader.Reading
    let onUse: (Position) -> Void
    @State private var sideToMove = PieceColor.white
    /// nil until changed: every castling the diagram allows.
    @State private var castling: CastlingRights?
    @State private var enPassant: Square?

    private var position: Position {
        reading.position(sideToMove: sideToMove, castling: castling, enPassant: enPassant)
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 4) {
                            Image(decorative: reading.board, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(1, contentMode: .fit)
                                // Turned like the board beside it.
                                .rotationEffect(reading.flipped ? .degrees(180) : .zero)
                            Text("Picture").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 4) {
                            BoardView(position: position, flipped: false,
                                      selected: nil, bestMove: nil, marked: Set(reading.doubtful), onTap: { _ in })
                            Text("Read").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    summary
                    Picker("Side to move", selection: $sideToMove) {
                        Text("White to move").tag(PieceColor.white)
                        Text("Black to move").tag(PieceColor.black)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sideToMove) { enPassant = nil }
                    notShown
                    Button("Turn Board Round", systemImage: "arrow.up.arrow.down") {
                        reading.turnRound()
                        castling = nil
                        enPassant = nil
                        chooseSideToMove()
                    }
                    .font(.callout)
                    Text("A diagram doesn't show whose move it is, whether the king or rooks have moved, or the last move: check the caption. Squares can be corrected on the board afterwards.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .onAppear(perform: chooseSideToMove)
            .navigationTitle("Diagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Position") {
                        dismiss()
                        onUse(position)
                    }
                }
            }
        }
    }

    /// When only one side to move makes a legal position (the other side is in check), that one.
    private func chooseSideToMove() {
        let legal = [PieceColor.white, .black].filter {
            EngineService.validationError(fen: reading.position(sideToMove: $0).fen) == nil
        }
        if legal.count == 1 { sideToMove = legal[0] }
    }

    /// Castling and en passant, offered only where the diagram allows them.
    @ViewBuilder
    private var notShown: some View {
        let possible = reading.possibleCastling
        let passant = reading.possibleEnPassant(sideToMove: sideToMove)
        if !possible.isEmpty || !passant.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(CastlingRights.ordered.filter { possible.contains($0.right) }, id: \.letter) { c in
                    Toggle(castlingLabel(c.right), isOn: Binding(
                        get: { (castling ?? possible).contains(c.right) },
                        set: { on in
                            var rights = castling ?? possible
                            if on { rights.insert(c.right) } else { rights.remove(c.right) }
                            castling = rights
                        }))
                }
                if !passant.isEmpty {
                    Picker("Last move", selection: $enPassant) {
                        Text("Not a pawn's double step").tag(Square?.none)
                        ForEach(passant, id: \.self) { sq in
                            Text(doubleStepLabel(sq)).tag(Square?.some(sq))
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

    private func castlingLabel(_ right: CastlingRights) -> String {
        switch right {
        case .whiteKingside: "White can castle short"
        case .whiteQueenside: "White can castle long"
        case .blackKingside: "Black can castle short"
        default: "Black can castle long"
        }
    }

    /// "…e7-e5" for en passant square e6.
    private func doubleStepLabel(_ passed: Square) -> String {
        let file = Array("abcdefgh")[passed.file]
        return passed.rank == 5 ? "…\(file)7-\(file)5" : "\(file)2-\(file)4"
    }

    @ViewBuilder
    private var summary: some View {
        let doubtful = reading.doubtful.count
        let pieces = reading.pieces.compactMap { $0 }.count
        VStack(alignment: .leading, spacing: 4) {
            Label("\(pieces) pieces read", systemImage: "checkmark.circle").foregroundStyle(.green)
            if doubtful >= 8 {
                Label("Many squares are uncertain: is the whole board in the picture? A closer, straighter picture reads better.",
                      systemImage: "viewfinder")
                    .foregroundStyle(.orange)
            } else if doubtful > 0 {
                Label("\(doubtful) square\(doubtful == 1 ? "" : "s") uncertain, outlined: check them against the picture.",
                      systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }
            if let problem = EngineService.validationError(fen: position.fen) {
                Label(problem.prefix(1).uppercased() + problem.dropFirst(), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if reading.flipped {
                Label("Printed from Black's side; turned round.", systemImage: "arrow.up.arrow.down")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
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
