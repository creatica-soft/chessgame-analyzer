import Foundation
import Observation

/// What a tap on the board does.
enum EditTool: Hashable {
    /// Tap a piece, then tap where it goes. Free movement: an editor, not a game.
    case move
    case place(Piece)
    case erase
}

/// The screen's state: the position being edited and analysed, and the engine looking at it.
@MainActor
@Observable
final class AnalysisModel {
    let engine: EngineService

    private(set) var position = Position.start
    var tool: EditTool = .move
    private(set) var selectedSquare: Square?
    var flipped = false
    /// Whether edits start a search. The engine button turns it off and on; analysis also
    /// pauses on its own when the app leaves the foreground or the phone overheats, and
    /// `pauseReason` then says which.
    private(set) var analysisEnabled = true
    private(set) var pauseReason: String?
    /// How far one search goes.
    var searchLimit: SearchLimit = .time(seconds: 20)
    /// How many times the board's current position has been searched again after finishing.
    private var extensions = 0
    /// Shown while the phone is warm and the engine runs on fewer threads.
    var thermalNote: String?
    /// Why the engine cannot search the board as it stands.
    private(set) var invalidReason: String?
    private(set) var terminal: EngineService.Terminal?
    private var undoStack: [Position] = []
    private var pending: Task<Void, Never>?

    init(engine: EngineService) {
        self.engine = engine
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var fen: String { position.fen }

    /// Call once the engine has been started.
    func start() {
        scheduleAnalysis()
    }

    // MARK: - Editing

    func tap(_ square: Square) {
        switch tool {
        case .move:
            if let from = selectedSquare {
                selectedSquare = nil
                guard from != square, let piece = position[from] else { return }
                change { $0.edit { $0[square] = piece; $0[from] = nil } }
            } else if position[square] != nil {
                selectedSquare = square
            }
        case .place(let piece):
            change { $0.edit { $0[square] = $0[square] == piece ? nil : piece } }
        case .erase:
            guard position[square] != nil else { return }
            change { $0.edit { $0[square] = nil } }
        }
    }

    func selectTool(_ tool: EditTool) {
        self.tool = tool
        selectedSquare = nil
    }

    func setSideToMove(_ color: PieceColor) {
        guard position.sideToMove != color else { return }
        change { $0.sideToMove = color; $0.enPassant = nil }
    }

    func setCastling(_ right: CastlingRights, _ on: Bool) {
        change { if on { $0.castling.insert(right) } else { $0.castling.remove(right) } }
    }

    func load(_ newPosition: Position) {
        selectedSquare = nil
        change { $0 = newPosition }
    }

    /// Loads a FEN typed or pasted by the user. Returns the parse error, if any.
    func load(fen: String) -> String? {
        do {
            load(try Position(fen: fen.trimmingCharacters(in: .whitespacesAndNewlines)))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Plays the engine's best move on the board.
    func playBestMove() {
        guard let move = bestMove, let fen = EngineService.play(fen: position.fen, uci: [move]),
              let next = try? Position(fen: fen) else { return }
        load(next)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        selectedSquare = nil
        position = previous
        scheduleAnalysis()
    }

    private func change(_ mutate: (inout Position) -> Void) {
        var next = position
        mutate(&next)
        guard next != position else { return }
        undoStack.append(position)
        if undoStack.count > 200 { undoStack.removeFirst() }
        position = next
        scheduleAnalysis()
    }

    // MARK: - Analysis

    /// The engine button: stops a running search, or searches the board again, for longer if the
    /// last search of it finished.
    func toggleAnalysis() {
        if isAnalyzing {
            analysisEnabled = false
            pending?.cancel()
            engine.stop(.position)
        } else {
            analysisEnabled = true
            scheduleAnalysis(force: true)
        }
    }

    /// Whether the engine is searching for this screen (not for the Games tab).
    var isAnalyzing: Bool { engine.status == .analyzing && engine.owner == .position }

    /// Whether the last search of the board reached its limit.
    var searchCompleted: Bool { engine.completedFEN == position.fen }

    /// The engine's lines, if they are for the position on the board. (A game analysis that
    /// passed through this very position counts: its lines are as good as our own.)
    var currentLines: [EngineService.AnalysisLine] {
        guard engine.analyzedFEN == position.fen else { return [] }
        return engine.lines.keys.sorted().compactMap { engine.lines[$0] }
    }

    var bestMove: String? { currentLines.first?.info.pv.first }

    /// The best line's score from White's point of view.
    var whiteScore: EngineScore? {
        currentLines.first?.info.score?.fromWhite(sideToMove: position.sideToMove)
    }

    func setPaused(_ reason: String?) {
        guard pauseReason != reason else { return }
        pauseReason = reason
        scheduleAnalysis()
    }

    /// Re-validates and restarts the search shortly after the last change, so a burst of edits
    /// costs one restart rather than one per tap.
    private func scheduleAnalysis(force: Bool = false) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.waitForEngine()
            guard !Task.isCancelled else { return }
            self?.refreshAnalysis(force: force)
        }
    }

    private func waitForEngine() async {
        while engine.status == .starting, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func refreshAnalysis(force: Bool) {
        let fen = position.fen
        invalidReason = EngineService.validationError(fen: fen)
        terminal = invalidReason == nil ? EngineService.terminal(fen: fen) : nil

        guard invalidReason == nil, terminal == nil, analysisEnabled, pauseReason == nil else {
            if invalidReason != nil || terminal != nil { engine.clear(.position) } else { engine.stop(.position) }
            return
        }
        if !force, engine.analyzedFEN == fen, isAnalyzing || searchCompleted { return }
        // Searching a finished position again goes further each time; see SearchLimit.extended.
        extensions = engine.analyzedFEN == fen && searchCompleted ? extensions + 1 : 0
        engine.analyze(fen: fen, limit: searchLimit.extended(by: extensions), for: .position)
    }
}
