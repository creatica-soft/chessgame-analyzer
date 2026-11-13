import SwiftUI
import UIKit

/// Everything about the position that is not on the board: castling, and the FEN itself.
struct PositionSheet: View {
    let model: AnalysisModel
    @Environment(\.dismiss) private var dismiss
    @State private var fenText = ""
    @State private var fenError: String?

    private static let castlingLabels: [(CastlingRights, String)] = [
        (.whiteKingside, "White O-O"),
        (.whiteQueenside, "White O-O-O"),
        (.blackKingside, "Black O-O"),
        (.blackQueenside, "Black O-O-O"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Self.castlingLabels, id: \.0.rawValue) { right, label in
                        Toggle(label, isOn: Binding(
                            get: { model.position.effectiveCastling.contains(right) },
                            set: { model.setCastling(right, $0) }
                        ))
                        .disabled(!model.position.supports(right))
                    }
                } header: {
                    Text("Castling")
                } footer: {
                    Text("A right is available only while that king and rook are on their original squares.")
                }

                Section("FEN") {
                    TextField("FEN", text: $fenText, axis: .vertical)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                    if let fenError {
                        Text(fenError).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Load FEN") {
                        fenError = model.load(fen: fenText)
                        if fenError == nil { dismiss() }
                    }
                    .disabled(fenText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Paste and Load") {
                        guard let text = UIPasteboard.general.string else {
                            fenError = "The clipboard has no text."
                            return
                        }
                        fenText = text
                        fenError = model.load(fen: text)
                        if fenError == nil { dismiss() }
                    }
                    Button("Copy Current FEN") {
                        UIPasteboard.general.string = model.fen
                    }
                }
            }
            .navigationTitle("Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { fenText = model.fen }
        }
    }
}
