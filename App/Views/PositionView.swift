import SwiftUI

/// The Position tab: set up a position and let the engine analyse it.
struct PositionView: View {
    @Bindable var model: AnalysisModel
    @State private var showingPosition = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    EvalBar(whiteShare: model.whiteScore?.whiteShare)
                    BoardView(
                        position: model.position,
                        flipped: model.flipped,
                        selected: model.selectedSquare,
                        bestMove: model.bestMove.flatMap(BoardView.squares(ofUCI:)),
                        onTap: model.tap
                    )
                    sideToMovePicker
                    PiecePalette(selected: model.tool, onSelect: model.selectTool)
                    AnalysisPanel(model: model)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showingPosition) { PositionSheet(model: model) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }

    private var sideToMovePicker: some View {
        Picker("Side to move", selection: Binding(
            get: { model.position.sideToMove },
            set: { model.setSideToMove($0) }
        )) {
            Text("White to move").tag(PieceColor.white)
            Text("Black to move").tag(PieceColor.black)
        }
        .pickerStyle(.segmented)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.canUndo)
            Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.flipped.toggle() }
            engineButton
            Menu("Position", systemImage: "ellipsis.circle") {
                Button("Starting Position", systemImage: "arrow.counterclockwise") { model.load(.start) }
                Button("Clear Board", systemImage: "trash") { model.load(.empty) }
                Button("Castling and FEN…", systemImage: "doc.text") { showingPosition = true }
            }
        }
    }

    private var engineButton: some View {
        Button(model.isAnalyzing ? "Stop Analysis" : "Analyze",
               systemImage: model.isAnalyzing ? "stop.fill" : "play.fill") {
            model.toggleAnalysis()
        }
        .disabled(model.engine.status == .starting || model.invalidReason != nil || model.terminal != nil)
    }
}
