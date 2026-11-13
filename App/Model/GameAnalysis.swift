import Foundation

/// A PGN game replayed by libchess: every position, and the move between each pair.
struct LoadedGame: Sendable {
    struct Ply: Sendable, Equatable {
        /// SAN as libchess writes it, so the list reads the same whatever wrote the PGN.
        var san: String
        var uci: String
        var fenAfter: String
        var number: Int
        var color: PieceColor
    }

    /// Tells this game from the one it replaced, even when both have the same moves.
    let id = UUID()
    let pgn: PGNGame
    let startFEN: String
    /// `plies[i]` leads from `fens[i]` to `fens[i + 1]`.
    let plies: [Ply]
    let fens: [String]
    /// Set when the PGN's moves stop making sense before the end; the game is the moves before.
    let readError: String?

    /// Replays `pgn` through libchess. Needs the engine to have started (see EngineService).
    init?(pgn: PGNGame) {
        guard let start = try? Position(fen: pgn.startFEN),
              EngineService.validationError(fen: start.fen) == nil else { return nil }
        self.pgn = pgn
        startFEN = start.fen
        let replayed = EngineService.replay(fen: startFEN, san: pgn.moves)
        let san = EngineService.san(fen: startFEN, uci: replayed.map(\.uci))

        var plies: [Ply] = []
        var number = start.fullmoveNumber
        var color = start.sideToMove
        for (i, move) in replayed.enumerated() {
            plies.append(Ply(san: i < san.count ? san[i] : pgn.moves[i], uci: move.uci,
                             fenAfter: move.fenAfter, number: number, color: color))
            if color == .black { number += 1 }
            color = color.opposite
        }
        self.plies = plies
        fens = [startFEN] + plies.map(\.fenAfter)

        if replayed.count < pgn.moves.count {
            let bad = pgn.moves[replayed.count]
            let label = "\(number)\(color == .white ? "." : "…") \(bad)"
            readError = "Move \(label) could not be played, so the game stops before it."
        } else {
            readError = nil
        }
    }
}

/// The engine's verdict on one position of a game.
enum PositionEval: Sendable, Equatable {
    case searched(EngineService.SearchResult)
    /// The side to move is checkmated.
    case checkmate
    case stalemate

    /// White's share of the eval bar, 0...1.
    func whiteShare(sideToMove: PieceColor) -> Double {
        switch self {
        case .searched(let r): r.score.fromWhite(sideToMove: sideToMove).whiteShare
        case .checkmate: sideToMove == .white ? 0 : 1
        case .stalemate: 0.5
        }
    }

    /// The score as text, from White's point of view.
    func text(sideToMove: PieceColor) -> String {
        switch self {
        case .searched(let r): r.score.fromWhite(sideToMove: sideToMove).text
        case .checkmate: sideToMove == .white ? "0–1" : "1–0"
        case .stalemate: "½–½"
        }
    }

    var result: EngineService.SearchResult? {
        if case .searched(let r) = self { return r }
        return nil
    }
}

/// How one move of a game compares with the engine's best.
struct MoveAssessment: Sendable, Equatable {
    var quality: MoveQuality
    /// The move played is the engine's best move.
    var isBest: Bool
    /// Pawns lost against the best move, after clamping (see AnnotationThresholds); never negative.
    var loss: Double
    /// The best line's score before the move and the score after it, both for the side that moved.
    var bestScore: EngineScore
    var playedScore: EngineScore
    /// The engine's line from the position before the move, in SAN; its first move is the best one.
    var bestLine: [String]

    /// Compares a move with the search of the position before it and of the position after it.
    /// nil until both positions have been searched.
    static func assess(_ ply: LoadedGame.Ply, before: PositionEval?, after: PositionEval?,
                       thresholds: AnnotationThresholds) -> MoveAssessment? {
        guard let best = before?.result, let after else { return nil }
        // The position after is scored for the opponent; mate there was delivered by this move.
        let played: EngineScore = switch after {
        case .searched(let r): r.score.negated
        case .checkmate: .mate(1)
        case .stalemate: .centipawns(0)
        }
        let isBest = best.bestMove == ply.uci
        let loss = isBest ? 0 : max(0, AnnotationThresholds.pawns(best.score) - AnnotationThresholds.pawns(played))
        return MoveAssessment(
            quality: isBest ? .good : thresholds.classify(best: best.score, played: played),
            isBest: isBest, loss: loss, bestScore: best.score, playedScore: played, bestLine: best.san)
    }
}

/// One player's totals.
struct PlayerSummary: Equatable {
    var counts: [MoveQuality: Int] = [:]
    var moves = 0
    var totalLoss = 0.0

    /// Average centipawn loss.
    var acpl: Int? { moves > 0 ? Int((totalLoss * 100 / Double(moves)).rounded()) : nil }

    static func make(plies: [LoadedGame.Ply], assessments: [MoveAssessment?], color: PieceColor) -> PlayerSummary {
        var s = PlayerSummary()
        for (ply, a) in zip(plies, assessments) where ply.color == color {
            guard let a else { continue }
            s.moves += 1
            s.totalLoss += a.loss
            s.counts[a.quality, default: 0] += 1
        }
        return s
    }
}

/// The game as PGN, with the engine's findings added: an [%eval] comment on every analysed move,
/// and on each inaccuracy, mistake and blunder its NAG, a note, and the engine's line as a variation.
enum AnnotatedPGN {
    static func write(_ game: LoadedGame, evals: [PositionEval?], assessments: [MoveAssessment?],
                      annotator: String) -> String {
        var tags = game.pgn.tags.filter { $0.name != "Annotator" }
        for required in ["Event", "Site", "Date", "Round", "White", "Black", "Result"]
        where !tags.contains(where: { $0.name == required }) {
            tags.append((required, required == "Result" ? game.pgn.result : "?"))
        }
        tags.append(("Annotator", annotator))
        var out = tags.map { "[\($0.name) \"\(escape($0.value))\"]" }.joined(separator: "\n")
        out += "\n\n"

        var tokens: [String] = []
        var needNumber = true
        for (i, ply) in game.plies.enumerated() {
            if ply.color == .white { tokens.append("\(ply.number).") } else if needNumber { tokens.append("\(ply.number)...") }
            tokens.append(ply.san)
            needNumber = false

            let assessment = i < assessments.count ? assessments[i] : nil
            if let nag = assessment?.quality.nag { tokens.append("$\(nag)") }

            var comment: [String] = []
            if i + 1 < evals.count, let after = evals[i + 1], let eval = evalTag(after, sideToMove: ply.color.opposite) {
                comment.append(eval)
            }
            if let a = assessment, a.quality != .good, let best = a.bestLine.first {
                comment.append("\(label(a.quality)). \(best) was best.")
            }
            if !comment.isEmpty {
                tokens.append("{ \(comment.joined(separator: " ")) }")
                needNumber = true
            }
            if let a = assessment, a.quality != .good, !a.bestLine.isEmpty {
                let line = MoveText.numbered(a.bestLine, fullmove: ply.number, sideToMove: ply.color)
                    .replacingOccurrences(of: "…", with: "...")
                tokens.append("( \(line) )")
                needNumber = true
            }
        }
        tokens.append(game.readError == nil ? game.pgn.result : "*")
        return out + wrap(tokens) + "\n"
    }

    private static func label(_ quality: MoveQuality) -> String {
        switch quality {
        case .good: "Good"
        case .inaccuracy: "Inaccuracy"
        case .mistake: "Mistake"
        case .blunder: "Blunder"
        }
    }

    /// [%eval] as lichess and ChessBase read it: pawns from White's side, or #n for a mate.
    private static func evalTag(_ eval: PositionEval, sideToMove: PieceColor) -> String? {
        guard let r = eval.result else { return nil }
        switch r.score.fromWhite(sideToMove: sideToMove) {
        case .centipawns(let cp): return "[%eval \(String(format: "%.2f", Double(cp) / 100))]"
        case .mate(let n): return "[%eval #\(n)]"
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Movetext lines of at most 80 characters, as the PGN export format asks.
    private static func wrap(_ tokens: [String]) -> String {
        var lines: [String] = []
        var line = ""
        for token in tokens.flatMap({ $0.split(separator: " ").map(String.init) }) {
            if !line.isEmpty, line.count + 1 + token.count > 80 {
                lines.append(line)
                line = token
            } else {
                line += line.isEmpty ? token : " " + token
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}

/// An engine line played out: every position along it, for stepping through on the board.
struct EngineLine: Equatable, Sendable {
    struct Move: Equatable, Sendable {
        var uci: String
        var san: String
        var fenAfter: String
    }

    let startFEN: String
    /// The game position the line starts from: `fens[startPly]`.
    let startPly: Int
    let score: EngineScore
    let moves: [Move]
    /// Moves played from the start: 0 is the start position.
    private(set) var index = 1

    init(startFEN: String, startPly: Int, result: EngineService.SearchResult) {
        self.startFEN = startFEN
        self.startPly = startPly
        score = result.score
        var moves: [Move] = []
        var fen = startFEN
        for (i, uci) in result.pv.enumerated() {
            guard let next = EngineService.play(fen: fen, uci: [uci]) else { break }
            let san = i < result.san.count ? result.san[i] : (EngineService.san(fen: fen, uci: [uci]).first ?? uci)
            moves.append(Move(uci: uci, san: san, fenAfter: next))
            fen = next
        }
        self.moves = moves
        index = min(1, moves.count)
    }

    var fen: String { index == 0 ? startFEN : moves[index - 1].fenAfter }

    mutating func select(_ i: Int) { index = max(0, min(moves.count, i)) }
}
