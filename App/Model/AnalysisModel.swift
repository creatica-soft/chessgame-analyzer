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
    /// The diagram the board was read from, while its reading is being checked.
    private(set) var diagram: DiagramReader.Reading?
    /// The diagram's squares still to check, outlined on the board. A square leaves the set when
    /// it is edited.
    private(set) var doubtful: Set<Square> = []
    /// The undo depth at which the diagram was loaded: undoing past it leaves the diagram.
    private var diagramDepth = 0
    /// A diagram's reading is on the board: analysis waits until the user has checked it and
    /// said so (Done or the engine button), even when every square was read with confidence.
    private(set) var awaitingCheck = false
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
                checked([from, square])
            } else if position[square] != nil {
                selectedSquare = square
            }
        case .place(let piece):
            change { $0.edit { $0[square] = $0[square] == piece ? nil : piece } }
            checked([square])
        case .erase:
            guard position[square] != nil else { return }
            change { $0.edit { $0[square] = nil } }
            checked([square])
        }
    }

    /// Squares the user has set by hand need no more checking.
    private func checked(_ squares: [Square]) {
        doubtful.subtract(squares)
    }

    // MARK: - A diagram read from a picture

    /// Puts a diagram's reading on the board for checking, with its doubtful squares outlined.
    /// Whose move it is a diagram doesn't show: when only one side gives a legal position (the
    /// other is in check), that one, otherwise White.
    func loadDiagram(_ reading: DiagramReader.Reading) {
        let legal = [PieceColor.white, .black].filter {
            EngineService.validationError(fen: reading.position(sideToMove: $0).fen) == nil
        }
        selectedSquare = nil
        // Waiting for the check before the board changes: a search of the same position (a
        // reading of the board already set up) is stopped too.
        awaitingCheck = true
        change { $0 = reading.position(sideToMove: legal.count == 1 ? legal[0] : .white) }
        engine.stop(.position)
        diagram = reading
        doubtful = Set(reading.doubtful)
        #if DEBUG
        fputs("diagram read: \(position.fen) doubtful \(reading.doubtful.map(\.algebraic))\n", stderr)
        #endif
        diagramDepth = undoStack.count
        // The board as printed: from Black's side when the diagram was.
        flipped = reading.flipped
    }

    /// The diagram read the other way up: it was printed from the other side.
    func turnDiagramRound() {
        guard var reading = diagram else { return }
        reading.turnRound()
        let depth = diagramDepth
        loadDiagram(reading)
        diagramDepth = depth
    }

    /// The reading has been checked: the outlines and the picture go, and analysis starts.
    func closeDiagram() {
        guard diagram != nil else { return }
        diagram = nil
        doubtful = []
        if awaitingCheck {
            awaitingCheck = false
            scheduleAnalysis()
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

    func setEnPassant(_ square: Square?) {
        guard position.enPassant != square else { return }
        change { $0.enPassant = square }
    }

    /// Whether `side` to move is a legal position with these pieces (the other king not in check).
    func isLegal(sideToMove side: PieceColor) -> Bool {
        var p = position
        p.sideToMove = side
        p.enPassant = nil
        return EngineService.validationError(fen: p.fen) == nil
    }

    /// The reading checked, and what the picture cannot show given: who is to move, and the en
    /// passant square if the last move was a pawn's double step. Analysis starts.
    func finishCheck(sideToMove side: PieceColor, enPassant: Square?) {
        setSideToMove(side)
        setEnPassant(enPassant.flatMap { position.possibleEnPassant(for: side).contains($0) ? $0 : nil })
        closeDiagram()
    }

    func setCastling(_ right: CastlingRights, _ on: Bool) {
        change { if on { $0.castling.insert(right) } else { $0.castling.remove(right) } }
    }

    func load(_ newPosition: Position) {
        selectedSquare = nil
        closeDiagram()
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
        if undoStack.count < diagramDepth { closeDiagram() }
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
        if awaitingCheck {
            // Asking for analysis of a diagram being checked takes it as checked.
            analysisEnabled = true
            closeDiagram()
        } else if isAnalyzing {
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

        // A diagram's reading waits until it has been checked: a misread position is not worth
        // searching, and the legality shown meanwhile helps the checking.
        guard invalidReason == nil, terminal == nil, analysisEnabled, pauseReason == nil, !awaitingCheck else {
            if invalidReason != nil || terminal != nil { engine.clear(.position) } else { engine.stop(.position) }
            return
        }
        if !force, engine.analyzedFEN == fen, isAnalyzing || searchCompleted { return }
        // Searching a finished position again goes further each time; see SearchLimit.extended.
        extensions = engine.analyzedFEN == fen && searchCompleted ? extensions + 1 : 0
        engine.analyze(fen: fen, limit: searchLimit.extended(by: extensions), for: .position)
    }
}
