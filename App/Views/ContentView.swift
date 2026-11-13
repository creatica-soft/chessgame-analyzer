import SwiftUI

struct ContentView: View {
    @Bindable var model: AnalysisModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(EngineSettings.threadsKey) private var threads = EngineSettings.defaultThreads
    @AppStorage(EngineSettings.hashKey) private var hashMB = EngineSettings.defaultHashMB
    @AppStorage(EngineSettings.limitKindKey) private var limitKind = EngineSettings.defaultLimitKind
    @AppStorage(EngineSettings.searchSecondsKey) private var searchSeconds = EngineSettings.defaultSearchSeconds
    @AppStorage(EngineSettings.searchDepthKey) private var searchDepth = EngineSettings.defaultSearchDepth
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State private var showingPosition = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    EvalBar(score: model.whiteScore)
                    BoardView(
                        position: model.position,
                        flipped: model.flipped,
                        selected: model.selectedSquare,
                        bestMove: bestMoveSquares,
                        onTap: model.tap
                    )
                    sideToMovePicker
                    PiecePalette(selected: model.tool, onSelect: model.selectTool)
                    AnalysisPanel(model: model)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Analyzer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showingPosition) { PositionSheet(model: model) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
        .onAppear {
            model.searchLimit = searchLimit
            model.start(threads: effectiveThreads, hashMB: hashMB)
            updateConditions()
        }
        .onChange(of: threads) { updateConditions() }
        .onChange(of: hashMB) { updateConditions() }
        .onChange(of: searchLimit) { model.searchLimit = searchLimit }
        .onChange(of: scenePhase) { updateConditions() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
            updateConditions()
        }
    }

    private var searchLimit: SearchLimit {
        EngineSettings.limit(kind: limitKind, seconds: searchSeconds, depth: searchDepth)
    }

    private var bestMoveSquares: (from: Square, to: Square)? {
        guard let move = model.bestMove, move.count >= 4,
              let from = Square(algebraic: move.prefix(2)),
              let to = Square(algebraic: move.dropFirst(2).prefix(2)) else { return nil }
        return (from, to)
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
        let analyzing = model.engine.status == .analyzing
        return Button(analyzing ? "Stop Analysis" : "Analyze",
                      systemImage: analyzing ? "stop.fill" : "play.fill") {
            model.toggleAnalysis()
        }
        .disabled(model.engine.status == .starting || model.invalidReason != nil || model.terminal != nil)
    }

    /// Threads for the current thermal state: the user's setting, capped while the phone is warm.
    private var effectiveThreads: Int {
        thermalState == .serious ? min(threads, EngineSettings.warmThreads) : threads
    }

    private func updateConditions() {
        model.engine.configure(threads: effectiveThreads, hashMB: hashMB)
        model.thermalNote = thermalState == .serious && threads > EngineSettings.warmThreads
            ? "The phone is warm: searching on \(EngineSettings.warmThreads) threads." : nil
        if scenePhase != .active {
            model.setPaused("Paused while the app is in the background.")
        } else if thermalState == .critical {
            model.setPaused("Paused: the phone is too hot. Analysis resumes when it cools down.")
        } else {
            model.setPaused(nil)
        }
    }
}
