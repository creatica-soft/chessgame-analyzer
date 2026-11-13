import Testing
@testable import ChessAnalyzer

struct PositionTests {
    @Test func startPositionRoundTrips() throws {
        #expect(try Position(fen: Position.startFEN).fen == Position.startFEN)
    }

    @Test(arguments: [
        "r3k2r/pppq1ppp/2n1bn2/3pp3/1b1PP3/2N1BN2/PPPQ1PPP/R3KB1R w KQkq - 0 1",
        "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "8/8/8/8/8/8/8/K6k b - - 37 92",
    ])
    func fenRoundTrips(_ fen: String) throws {
        #expect(try Position(fen: fen).fen == fen)
    }

    @Test func fiveFieldFENGetsDefaults() throws {
        #expect(try Position(fen: "4k3/8/8/8/8/8/8/4K3 b -").fen == "4k3/8/8/8/8/8/8/4K3 b - - 0 1")
    }

    @Test(arguments: [
        ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1", FENError.badPlacement("expected 8 ranks, found 7")),
        ("rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", FENError.badPlacement("unexpected '9'")),
        ("rnbqkbnr/ppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", FENError.badPlacement("rank 7 has 7 squares")),
        ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1", FENError.badSideToMove),
        ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KXkq - 0 1", FENError.badCastling),
        ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e4 0 1", FENError.badEnPassant),
        ("rnbqkbnr", FENError.fieldCount),
    ])
    func badFENsAreRejected(_ fen: String, _ expected: FENError) {
        #expect(throws: expected) { try Position(fen: fen) }
    }

    @Test func castlingRightsFollowThePlacement() throws {
        var p = try Position(fen: Position.startFEN)
        p.edit { $0[7] = nil }                        // the h1 rook leaves
        #expect(p.fen.split(separator: " ")[2] == "Qkq")
        p.edit { $0[60] = nil; $0[59] = Piece(.black, .king) }   // the black king moves to d8
        #expect(p.fen.split(separator: " ")[2] == "Q")
        #expect(p.castling.contains(.blackKingside))     // the user's choice is kept...
        p.edit { $0[60] = Piece(.black, .king); $0[59] = nil }
        #expect(p.fen.split(separator: " ")[2] == "Qkq") // ...and returns with the king
    }

    @Test func enPassantNeedsTheDoubleSteppedPawn() throws {
        let p = try Position(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
        #expect(p.effectiveEnPassant == Square(algebraic: "d6"))
        let q = try Position(fen: "4k3/8/8/4P3/8/8/8/4K3 w - d6 0 1")
        #expect(q.effectiveEnPassant == nil)
        var r = p
        r.edit { $0[0] = Piece(.white, .rook) }
        #expect(r.enPassant == nil)                  // an edit is not a move
    }

    @Test func squareNames() {
        #expect(Square(algebraic: "a1") == 0)
        #expect(Square(algebraic: "h8") == 63)
        #expect(Square(algebraic: "e4") == 28)
        #expect(Square(algebraic: "i1") == nil)
        #expect(Square(algebraic: "a9") == nil)
        #expect(28.algebraic == "e4")
    }
}

struct UCITests {
    @Test func parsesAFullInfoLine() {
        let line = "info depth 24 seldepth 52 multipv 1 score cp 29 nodes 9509643 nps 3291672 hashfull 848 tbhits 0 time 2889 pv d2d4 g8f6 c2c4"
        guard case .info(let info) = UCIMessage.parse(line) else {
            Issue.record("not parsed as info")
            return
        }
        #expect(info.depth == 24)
        #expect(info.seldepth == 52)
        #expect(info.multipv == 1)
        #expect(info.score == .centipawns(29))
        #expect(info.nodes == 9_509_643)
        #expect(info.nps == 3_291_672)
        #expect(info.timeMs == 2889)
        #expect(info.hashfull == 848)
        #expect(info.pv == ["d2d4", "g8f6", "c2c4"])
    }

    @Test func parsesMateAndBounds() {
        guard case .info(let info) = UCIMessage.parse("info depth 9 score mate -3 lowerbound nodes 5 pv e1e2") else {
            Issue.record("not parsed as info")
            return
        }
        #expect(info.score == .mate(-3))
        #expect(info.nodes == 5)
    }

    @Test func otherLines() {
        #expect(UCIMessage.parse("bestmove e2e4 ponder e7e5") == .bestMove("e2e4", ponder: "e7e5"))
        #expect(UCIMessage.parse("bestmove 0000") == .bestMove("0000", ponder: nil))
        #expect(UCIMessage.parse("readyok") == .readyOK)
        #expect(UCIMessage.parse("info string hello there") == .infoString("hello there"))
        #expect(UCIMessage.parse("info depth 3 currmove e2e4") == .other("info depth 3 currmove e2e4"))
    }

    @Test func scoresAreShownFromWhitesSide() {
        #expect(EngineScore.centipawns(29).fromWhite(sideToMove: .black) == .centipawns(-29))
        #expect(EngineScore.mate(2).fromWhite(sideToMove: .black) == .mate(-2))
        #expect(EngineScore.centipawns(29).fromWhite(sideToMove: .white).text == "+0.29")
        #expect(EngineScore.centipawns(-150).text == "−1.50")
        #expect(EngineScore.centipawns(0).text == "0.00")
        #expect(EngineScore.mate(3).text == "#3")
        #expect(EngineScore.mate(-3).text == "#−3")
        #expect(EngineScore.centipawns(0).whiteShare == 0.5)
        #expect(EngineScore.mate(-1).whiteShare == 0)
    }

    @Test func numbersMoves() {
        #expect(MoveText.numbered(["e4", "e5", "Nf3"], fullmove: 1, sideToMove: .white) == "1. e4 e5 2. Nf3")
        #expect(MoveText.numbered(["Nc6", "Bb5", "a6"], fullmove: 2, sideToMove: .black) == "2… Nc6 3. Bb5 a6")
    }
}

/// These go through the C bridge to libchess, so they need the engine the host app starts.
@MainActor
struct BridgeTests {
    @Test func validation() {
        #expect(EngineService.validationError(fen: Position.startFEN) == nil)
        #expect(EngineService.validationError(fen: "8/8/8/8/8/8/8/K7 w - - 0 1") != nil)
        #expect(EngineService.validationError(fen: "4k3/8/8/8/8/8/4R3/4K3 w - - 0 1") == "the side not to move is in check")
        #expect(EngineService.validationError(fen: "P3k3/8/8/8/8/8/8/4K3 w - - 0 1") != nil)
    }

    @Test func terminalPositions() {
        #expect(EngineService.terminal(fen: Position.startFEN) == nil)
        // Fool's mate.
        #expect(EngineService.terminal(fen: "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3") == .checkmate)
        #expect(EngineService.terminal(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1") == .stalemate)
    }

    @Test func sanConversion() {
        #expect(EngineService.san(fen: "r3k2r/pppq1ppp/2n1bn2/3pp3/1b1PP3/2N1BN2/PPPQ1PPP/R3KB1R w KQkq - 0 1",
                                  uci: ["e1c1", "e8g8", "d4e5", "d5e4", "e5f6"])
                == ["O-O-O", "O-O", "dxe5", "dxe4", "exf6"])
        #expect(EngineService.san(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", uci: ["e5d6"]) == ["exd6"])
        #expect(EngineService.san(fen: "4k3/1P6/8/8/8/8/8/4K3 w - - 0 1", uci: ["b7b8q"]) == ["b8=Q+"])
        #expect(EngineService.san(fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", uci: ["a1a8"]) == ["Ra8#"])
        // Disambiguation, now done by libchess's move2san().
        #expect(EngineService.san(fen: "8/K7/8/8/4Q2Q/k7/8/7Q w - - 0 1", uci: ["h4e1"]) == ["Qh4e1"])
        #expect(EngineService.san(fen: "4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1", uci: ["b1d2"]) == ["Nbd2"])
        // Stops at the first illegal move.
        #expect(EngineService.san(fen: Position.startFEN, uci: ["e2e4", "e2e4"]) == ["e4"])
    }

    @Test func playingMoves() {
        #expect(EngineService.play(fen: Position.startFEN, uci: ["e2e4"])
                == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        #expect(EngineService.play(fen: Position.startFEN, uci: ["e2e5"]) == nil)
    }
}

struct AnnotationTests {
    let t = AnnotationThresholds.standard

    @Test func defaultsAreTheUsersThresholds() {
        #expect(t.inaccuracy == 0.3 && t.mistake == 1.0 && t.blunder == 2.0)
    }

    @Test(arguments: [
        (30, 30, MoveQuality.good),
        (30, 1, .good),            // loses 0.29
        (30, 0, .inaccuracy),      // loses exactly 0.30
        (50, -49, .inaccuracy),    // loses 0.99
        (50, -50, .mistake),       // loses exactly 1.00
        (120, -79, .mistake),      // loses 1.99
        (120, -80, .blunder),      // loses exactly 2.00
    ])
    func classifiesByPawnsLost(best: Int, played: Int, expected: MoveQuality) {
        #expect(t.classify(best: .centipawns(best), played: .centipawns(played)) == expected)
    }

    @Test func evaluationsAreClamped() {
        // Both clearly won: +15 to +12 is not a blunder.
        #expect(t.classify(best: .centipawns(1500), played: .centipawns(1200)) == .good)
        // A slower mate is not a loss.
        #expect(t.classify(best: .mate(3), played: .mate(5)) == .good)
        // Letting a mate go for a won position is.
        #expect(t.classify(best: .mate(3), played: .centipawns(600)) == .blunder)
        // Walking into a mate from an equal position is.
        #expect(t.classify(best: .centipawns(0), played: .mate(-2)) == .blunder)
    }

    @Test func customThresholds() {
        let strict = AnnotationThresholds(inaccuracy: 0.1, mistake: 0.5, blunder: 1.0)
        #expect(strict.classify(best: .centipawns(0), played: .centipawns(-60)) == .mistake)
    }

    @Test func glyphs() {
        #expect(MoveQuality.inaccuracy.symbol == "?!" && MoveQuality.inaccuracy.nag == 6)
        #expect(MoveQuality.mistake.symbol == "?" && MoveQuality.mistake.nag == 2)
        #expect(MoveQuality.blunder.symbol == "??" && MoveQuality.blunder.nag == 4)
        #expect(MoveQuality.good.symbol == nil)
    }
}

struct SearchLimitTests {
    @Test func goCommands() {
        #expect(SearchLimit.time(seconds: 20).goCommand == "go movetime 20000")
        #expect(SearchLimit.depth(22).goCommand == "go depth 22")
        #expect(SearchLimit.infinite.goCommand == "go infinite")
    }

    @Test func extendingASearch() {
        #expect(SearchLimit.depth(22).extended(by: 0) == .depth(22))
        #expect(SearchLimit.depth(22).extended(by: 2) == .depth(30))
        #expect(SearchLimit.time(seconds: 20).extended(by: 3) == .time(seconds: 20))
    }
}
