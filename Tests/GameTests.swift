import UniformTypeIdentifiers
import Testing
@testable import ChessAnalyzer

struct PGNParserTests {
    static let twoGames = """
    [Event "Casual"]
    [Site "?"]
    [White "Anderssen, A."]
    [Black "Kieseritzky, L."]
    [Result "1-0"]

    1. e4 e5 2. f4 exf4 {King's Gambit} 3. Bc4 Qh4+ (3... d5 4. Bxd5) 4. Kf1 b5?! $6
    5. Bxb5 Nf6 6. Nf3 Qh6 ; a line comment
    7. d3 1-0

    [Event "Second"]
    [White "A \\"quoted\\" name"]
    [Black "B"]
    [Result "*"]

    1.d4 d5 2.c4 dxc4 3.e3 *
    """

    @Test func readsTagsMovesAndResults() {
        let games = PGNParser.parse(Self.twoGames)
        #expect(games.count == 2)
        #expect(games[0]["White"] == "Anderssen, A.")
        #expect(games[0].moves == ["e4", "e5", "f4", "exf4", "Bc4", "Qh4+", "Kf1", "b5",
                                   "Bxb5", "Nf6", "Nf3", "Qh6", "d3"])
        #expect(games[0].result == "1-0")
        #expect(games[1]["White"] == "A \"quoted\" name")
        #expect(games[1].moves == ["d4", "d5", "c4", "dxc4", "e3"])
        #expect(games[1].result == "*")
    }

    @Test func movetextWithoutTags() {
        let games = PGNParser.parse("1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")
        #expect(games.count == 1)
        #expect(games[0].moves == ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"])
        #expect(games[0].startFEN == Position.startFEN)
    }

    @Test func nestedVariationsAndOddTokens() {
        let pgn = "1. e4 (1. d4 d5 (1... Nf6 2. c4 {x}) 2. c4) 1... e5 2. 0-0?? 2... exd6 e.p. 3. Nf3!! $1 1/2-1/2"
        let games = PGNParser.parse(pgn)
        #expect(games.first?.moves == ["e4", "e5", "O-O", "exd6", "Nf3"])
        #expect(games.first?.result == "1/2-1/2")
    }

    @Test func gameWithoutResultEndsAtNextTags() {
        let games = PGNParser.parse("[White \"a\"]\n1. e4 e5\n[White \"b\"]\n1. d4 *")
        #expect(games.map(\.moves) == [["e4", "e5"], ["d4"]])
    }

    @Test func emptyInput() {
        #expect(PGNParser.parse("").isEmpty)
        #expect(PGNParser.parse("[Event \"x\"]\n*").isEmpty)
    }
}

/// Replaying goes through libchess, so it needs the engine the host app starts.
struct ReplayTests {
    @Test func replaysAndNormalisesSAN() throws {
        let pgn = try #require(PGNParser.parse("1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O Nxe4 5. Re1 Nd6 6. Nxe5 Be7 7. Bf1 Nxe5 8. Rxe5 O-O").first)
        let game = try #require(LoadedGame(pgn: pgn))
        #expect(game.readError == nil)
        #expect(game.plies.count == 16)
        #expect(game.fens.count == 17)
        #expect(game.plies[6].uci == "e1g1")        // castling in the engine's notation
        #expect(game.plies[6].san == "O-O")
        #expect(game.plies[15].uci == "e8g8")
        #expect(game.plies[0].number == 1 && game.plies[0].color == .white)
        #expect(game.plies[15].number == 8 && game.plies[15].color == .black)
        #expect(game.fens[1] == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
                || game.fens[1] == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")
    }

    @Test func addsCheckMarksTheFileLacked() throws {
        let pgn = try #require(PGNParser.parse("1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7").first)
        let game = try #require(LoadedGame(pgn: pgn))
        #expect(game.plies.last?.san == "Qxf7#")
    }

    @Test func stopsAtAnIllegalMove() throws {
        let pgn = try #require(PGNParser.parse("1. e4 e5 2. Ke3 Nc6").first)
        let game = try #require(LoadedGame(pgn: pgn))
        #expect(game.plies.count == 2)
        #expect(game.readError?.contains("2. Ke3") == true)
    }

    @Test func startsFromTheFENTag() throws {
        let pgn = try #require(PGNParser.parse("[FEN \"4k3/8/8/8/8/8/4P3/4K3 b - - 0 40\"]\n40... Kd7 41. e4 *").first)
        let game = try #require(LoadedGame(pgn: pgn))
        #expect(game.plies.map(\.san) == ["Kd7", "e4"])
        #expect(game.plies[0].number == 40 && game.plies[0].color == .black)
        #expect(game.plies[1].number == 41)
    }

    @Test func rejectsAnIllegalStartPosition() throws {
        let pgn = try #require(PGNParser.parse("[FEN \"8/8/8/8/8/8/8/K7 w - - 0 1\"]\n1. Ka2 *").first)
        #expect(LoadedGame(pgn: pgn) == nil)
    }
}

struct AssessmentTests {
    static func result(_ cp: Int, best: String, san: [String] = ["Nc3"]) -> PositionEval {
        .searched(EngineService.SearchResult(score: .centipawns(cp), depth: 18, bestMove: best, pv: [best], san: san))
    }

    let ply = LoadedGame.Ply(san: "Nf3", uci: "g1f3", fenAfter: "", number: 12, color: .white)

    @Test func playingTheBestMoveIsNeverMarked() {
        // The search after the move disagrees with the one before by more than a blunder;
        // the move was still the engine's choice.
        let a = MoveAssessment.assess(ply, before: Self.result(50, best: "g1f3"),
                                      after: Self.result(300, best: "e7e5"), thresholds: .standard)
        #expect(a?.isBest == true && a?.quality == .good && a?.loss == 0)
    }

    @Test func lossIsBestBeforeMinusPlayedAfter() {
        // Before: +0.50 for White with Nc3. After Nf3: Black's search says +0.60 for Black.
        let a = MoveAssessment.assess(ply, before: Self.result(50, best: "b1c3"),
                                      after: Self.result(60, best: "e7e5"), thresholds: .standard)
        #expect(a?.quality == .mistake)
        #expect(a?.playedScore == .centipawns(-60))
        #expect(abs((a?.loss ?? 0) - 1.1) < 1e-9)
        #expect(a?.bestLine == ["Nc3"])
    }

    @Test func deliveringMateAndStalemate() {
        let mate = MoveAssessment.assess(ply, before: .searched(.init(score: .mate(1), depth: 1, bestMove: "g1f3", pv: [], san: [])),
                                         after: .checkmate, thresholds: .standard)
        #expect(mate?.quality == .good && mate?.isBest == true)
        // Stalemating from a won position throws the win away.
        let stale = MoveAssessment.assess(ply, before: Self.result(900, best: "b1c3"), after: .stalemate, thresholds: .standard)
        #expect(stale?.quality == .blunder)
    }

    @Test func needsBothSearches() {
        #expect(MoveAssessment.assess(ply, before: nil, after: Self.result(0, best: "a"), thresholds: .standard) == nil)
        #expect(MoveAssessment.assess(ply, before: Self.result(0, best: "a"), after: nil, thresholds: .standard) == nil)
    }

    @Test func summary() {
        let plies = [ply, LoadedGame.Ply(san: "e5", uci: "e7e5", fenAfter: "", number: 12, color: .black)]
        let a1 = MoveAssessment(quality: .mistake, isBest: false, loss: 1.2, bestScore: .centipawns(0),
                                playedScore: .centipawns(-120), bestLine: [])
        let s = PlayerSummary.make(plies: plies, assessments: [a1, nil], color: .white)
        #expect(s.counts[.mistake] == 1 && s.moves == 1 && s.acpl == 120)
        #expect(PlayerSummary.make(plies: plies, assessments: [a1, nil], color: .black).acpl == nil)
    }
}

struct AnnotatedPGNTests {
    @Test func writesEvalsNAGsAndCorrections() throws {
        let pgn = try #require(PGNParser.parse("[White \"W\"]\n[Black \"B\"]\n[Result \"*\"]\n1. e4 e5 2. Qh5 Nc6 *").first)
        let game = try #require(LoadedGame(pgn: pgn))
        let evals: [PositionEval?] = [
            AssessmentTests.result(30, best: "e2e4"),
            AssessmentTests.result(-30, best: "e7e5"),
            AssessmentTests.result(30, best: "g1f3", san: ["Nf3", "Nc6"]),
            AssessmentTests.result(80, best: "b8c6"),    // after Qh5, Black to move: -0.80 for White
            nil,
        ]
        let assessments = game.plies.indices.map {
            MoveAssessment.assess(game.plies[$0], before: evals[$0], after: evals[$0 + 1], thresholds: .standard)
        }
        #expect(assessments[2]?.quality == .mistake)   // +0.30 → −0.80 loses 1.10
        let text = AnnotatedPGN.write(game, evals: evals, assessments: assessments, annotator: "Test")
        #expect(text.contains("[Annotator \"Test\"]"))
        #expect(text.contains("[Event \"?\"]"))          // the seven-tag roster is completed
        let movetext = text.replacingOccurrences(of: "\n", with: " ")   // wrapping is layout
        #expect(movetext.contains("1. e4 { [%eval 0.30] } 1... e5 { [%eval 0.30] }"))
        #expect(movetext.contains("2. Qh5 $2 { [%eval -0.80] Mistake. Nf3 was best. } ( 2. Nf3 Nc6 ) 2... Nc6 *"), "\(text)")
        #expect(!text.split(separator: "\n").contains { $0.count > 80 })
    }
}

struct EngineLineTests {
    @Test func playsThePVAndNumbersItsMoves() {
        let afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        let result = EngineService.SearchResult(score: .centipawns(-30), depth: 10, bestMove: "e7e5",
                                                pv: ["e7e5", "g1f3", "b8c6"], san: ["e5", "Nf3", "Nc6"])
        var line = EngineLine(startFEN: afterE4, startPly: 1, result: result)
        #expect(line.moves.map(\.san) == ["e5", "Nf3", "Nc6"])
        #expect(line.index == 1)
        #expect(line.fen.hasPrefix("rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w"))
        #expect(LineMoves.label(line, 0) == "1… e5")
        #expect(LineMoves.label(line, 1) == "2. Nf3")
        line.select(9)
        #expect(line.index == 3)
        line.select(0)
        #expect(line.fen == afterE4)
    }

    @Test func stopsAtAnIllegalPVMove() {
        let result = EngineService.SearchResult(score: .centipawns(30), depth: 10, bestMove: "e2e4",
                                                pv: ["e2e4", "e2e4"], san: ["e4", "e4"])
        #expect(EngineLine(startFEN: Position.startFEN, startPly: 0, result: result).moves.count == 1)
    }
}

struct PGNFileTests {
    @Test func pgnFilesAreText() throws {
        // Without the declaration in Info.plist, .pgn gets a dynamic type that conforms to nothing
        // and the file is greyed out in the Open dialog.
        let type = try #require(UTType(filenameExtension: "pgn"))
        #expect(type.conforms(to: .plainText))
        #expect(!type.isDynamic)
        #expect(PGNFile.types.contains(type))
    }

    @Test func readsLatin1() throws {
        let url = URL.temporaryDirectory.appending(path: "test.pgn")
        try Data("[White \"Réti\"]\n\n1. Nf3 *\n".data(using: .isoLatin1)!).write(to: url)
        #expect(try PGNFile.read(url).contains("Réti"))
    }
}
