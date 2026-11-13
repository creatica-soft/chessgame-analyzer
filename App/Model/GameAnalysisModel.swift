import Foundation
import Observation

/// The Games tab: the games read from a PGN, the one being looked at, and its analysis.
///
/// Analysis searches every position of the game once, from the first, each to `limit`. A move is
/// then judged from the search before it and the search after it (see MoveAssessment), so the
/// assessments fill in behind the search and change with `thresholds` without searching again.
@MainActor
@Observable
final class GameAnalysisModel {
    let engine: EngineService

    /// Every game in the last PGN read.
    private(set) var games: [PGNGame] = []
    private(set) var game: LoadedGame?
    /// One per position of `game`, nil until searched.
    private(set) var evals: [PositionEval?] = []
    /// The position on the board: 0 is the start, k the position after k plies.
    private(set) var selectedPly = 0
    var flipped = false
    /// Set when the game was read from text that went on after the last move read: the game
    /// is shorter than what was printed.
    private(set) var readNote: String?
    /// The engine's line being played through on the board, instead of the game.
    private(set) var line: EngineLine?
    /// Analysis has been asked for and has not finished or been stopped. It may be paused.
    private(set) var isRunning = false
    /// The position being searched.
    private(set) var searchingPly: Int?
    private(set) var pauseReason: String?
    /// The engine is searching on fewer threads because the phone is warm.
    var thermalNote: String?
    private(set) var failedPositions = 0

    var limit: SearchLimit = .time(seconds: 1)
    var thresholds = AnnotationThresholds.standard

    private var task: Task<Void, Never>?

    init(engine: EngineService) {
        self.engine = engine
    }

    // MARK: - Loading

    /// Reads a PGN. With one game it is opened at once (without analysing it); with several, `games` lists them for
    /// `open`. Returns an error message when nothing could be read.
    func importPGN(_ text: String) -> String? {
        let found = PGNParser.parse(text)
        guard !found.isEmpty else { return "No game with moves was found in that text." }
        stopAnalysis()
        games = found
        game = nil
        evals = []
        selectedPly = 0
        line = nil
        if found.count == 1 { return open(found[0]) }
        return nil
    }

    /// Opens one of `games`. Returns an error message if libchess cannot replay it at all.
    @discardableResult
    func open(_ pgn: PGNGame) -> String? {
        guard engine.status != .starting else { return "The engine is still starting. Try again in a moment." }
        guard let loaded = LoadedGame(pgn: pgn) else { return "The game's starting position (FEN tag) is not legal." }
        guard !loaded.plies.isEmpty else { return loaded.readError ?? "The game has no moves." }
        stopAnalysis()
        // Selection and evaluations first: a view drawn with the new game must never see the
        // old game's ply or evaluations.
        selectedPly = 0
        line = nil
        readNote = nil
        evals = Array(repeating: nil, count: loaded.fens.count)
        failedPositions = 0
        game = loaded
        flipped = false
        // Analysis waits for the user: opening a game is for looking at it.
        return nil
    }

    /// Opens moves read from an image or loose text, from the standard start position.
    @discardableResult
    func openMoves(_ moves: [String], tags read: [GameTextReader.Tag] = [], title: String,
                   stoppedAt: String? = nil) -> String? {
        // The seven required tags first, from the text where it had them; then any others it had.
        // The result is left open: the moves read may stop before the end.
        let required = ["Event", "Site", "Date", "Round", "White", "Black"]
        var tags = required.map { name in
            (name: name, value: read.first { $0.name == name }?.value ?? (name == "Event" ? title : "?"))
        }
        tags.append((name: "Result", value: "*"))
        tags += read.filter { !required.contains($0.name) && $0.name != "Result" && $0.name != "FEN" && $0.name != "SetUp" }
            .map { (name: $0.name, value: $0.value) }
        let pgn = PGNGame(tags: tags, moves: moves, result: "*")
        games = [pgn]
        let error = open(pgn)
        if error == nil, let stoppedAt {
            readNote = "Only the first \((moves.count + 1) / 2) moves were read. \(stoppedAt)"
        }
        return error
    }

    /// Back to the list of games, or to nothing if there was only one.
    func close() {
        stopAnalysis()
        game = nil
        evals = []
        selectedPly = 0
        line = nil
        if games.count == 1 { games = [] }
    }

    // MARK: - Navigation

    func select(ply: Int) {
        guard let game else { return }
        line = nil
        selectedPly = max(0, min(game.plies.count, ply))
    }

    func step(_ delta: Int) { select(ply: selectedPly + delta) }

    /// Plays the engine's line from the position before move `ply` (the line for what should
    /// have been played there), showing its first move.
    func showBestLine(beforePly ply: Int) {
        guard let game, ply >= 1, ply <= game.plies.count,
              let result = eval(at: ply - 1)?.result else { return }
        line = EngineLine(startFEN: game.fens[ply - 1], startPly: ply - 1, result: result)
        if line?.moves.isEmpty == true { line = nil }
    }

    /// The line `showBestLine(beforePly:)` would play, for listing its moves.
    func previewLine(beforePly ply: Int) -> EngineLine? {
        guard let game, ply >= 1, ply <= game.plies.count, let result = eval(at: ply - 1)?.result else { return nil }
        let line = EngineLine(startFEN: game.fens[ply - 1], startPly: ply - 1, result: result)
        return line.moves.isEmpty ? nil : line
    }

    func stepLine(_ delta: Int) {
        // Read the index before mutating: reading `line` inside its own mutation is an
        // exclusivity violation, which traps.
        guard let index = line?.index else { return }
        line?.select(index + delta)
    }
    func selectLine(_ index: Int) { line?.select(index) }

    /// Back to the game, at the move the line replaced.
    func exitLine() {
        guard let line else { return }
        self.line = nil
        selectedPly = line.startPly + 1
    }

    // MARK: - Results

    /// One per move of `game`, nil until both positions around it have been searched.
    var assessments: [MoveAssessment?] {
        guard let game, evals.count == game.fens.count else { return [] }
        return game.plies.indices.map { i in
            MoveAssessment.assess(game.plies[i], before: evals[i], after: evals[i + 1], thresholds: thresholds)
        }
    }

    /// The evaluation of the position after `ply` moves, if it has been searched.
    func eval(at ply: Int) -> PositionEval? {
        evals.indices.contains(ply) ? evals[ply] : nil
    }

    var analyzedPositions: Int { evals.lazy.filter { $0 != nil }.count }
    /// Nothing analysed yet.
    var isUnanalyzed: Bool { evals.allSatisfy { $0 == nil } }

    /// Roughly how long analysing the rest takes at a fixed time per position; nil for a depth.
    var remainingEstimate: Duration? {
        guard case .time(let seconds) = limit else { return nil }
        let left = evals.lazy.filter { $0 == nil }.count
        return .seconds(Double(left) * Double(seconds))
    }

    var isComplete: Bool { !evals.isEmpty && analyzedPositions == evals.count }

    func sideToMove(at ply: Int) -> PieceColor {
        guard let game, ply <= game.plies.count else { return .white }
        return ply == 0 ? ((try? Position(fen: game.startFEN))?.sideToMove ?? .white) : game.plies[ply - 1].color.opposite
    }

    func annotatedPGN(annotator: String) -> String? {
        guard let game else { return nil }
        return AnnotatedPGN.write(game, evals: evals, assessments: assessments, annotator: annotator)
    }

    // MARK: - Analysis

    func startAnalysis() {
        guard game != nil, !isComplete, task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stopAnalysis() {
        task?.cancel()
        task = nil
        isRunning = false
        searchingPly = nil
        engine.stop(.game)
    }

    /// Pauses a running analysis (the app is in the background, the phone is too hot, or the
    /// Position tab has the engine); nil resumes it.
    func setPaused(_ reason: String?) {
        guard pauseReason != reason else { return }
        pauseReason = reason
        if reason != nil { engine.stop(.game) }
    }

    private func run() async {
        defer {
            if !Task.isCancelled {
                task = nil
                isRunning = false
                searchingPly = nil
            }
        }
        guard let game else { return }
        /// Still analysing this game: a search that returns after the game was replaced must not
        /// write into the new game's evaluations.
        func current() -> Bool { !Task.isCancelled && self.game?.id == game.id && evals.count == game.fens.count }
        while engine.status == .starting, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for i in game.fens.indices {
            guard current() else { return }
            guard evals[i] == nil else { continue }
            let fen = game.fens[i]
            switch EngineService.terminal(fen: fen) {
            case .checkmate: evals[i] = .checkmate; continue
            case .stalemate: evals[i] = .stalemate; continue
            case nil: break
            }
            searchingPly = i
            var failures = 0
            while current(), evals[i] == nil {
                if pauseReason != nil {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                if let result = await engine.search(fen: fen, limit: limit, for: .game) {
                    guard current() else { return }
                    evals[i] = .searched(result)
                } else if pauseReason == nil, !Task.isCancelled {
                    // Stopped by something else: a settings change, or the Position tab. A
                    // position that keeps failing is skipped rather than retried forever.
                    failures += 1
                    if failures >= 3 { failedPositions += 1; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
}
