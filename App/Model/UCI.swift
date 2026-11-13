import Foundation

/// A UCI score, from the point of view of the side to move as the protocol defines it.
enum EngineScore: Sendable, Equatable {
    case centipawns(Int)
    /// Moves to mate; negative when the side to move is being mated. `mate 0` means mated now.
    case mate(Int)

    /// The same score from White's point of view, which is how the app displays every score.
    func fromWhite(sideToMove: PieceColor) -> EngineScore {
        guard sideToMove == .black else { return self }
        switch self {
        case .centipawns(let cp): return .centipawns(-cp)
        case .mate(let n): return .mate(-n)
        }
    }

    /// The same score for the other side.
    var negated: EngineScore {
        switch self {
        case .centipawns(let cp): .centipawns(-cp)
        case .mate(let n): .mate(-n)
        }
    }

    /// The displayed text, assuming the score is already from White's point of view.
    var text: String {
        switch self {
        case .centipawns(let cp):
            // The engine reports tablebase results as 20000 less the distance.
            if cp >= 19_000 { return "+TB" }
            if cp <= -19_000 { return "−TB" }
            let pawns = Double(cp) / 100
            return cp > 0 ? String(format: "+%.2f", pawns) : cp < 0 ? String(format: "−%.2f", -pawns) : "0.00"
        case .mate(let n):
            return n >= 0 ? "#\(n)" : "#−\(-n)"
        }
    }

    /// White's expected share of the eval bar, 0...1 (lichess's win-probability curve).
    var whiteShare: Double {
        switch self {
        case .centipawns(let cp):
            let clamped = Double(max(-1000, min(1000, cp)))
            return 1 / (1 + exp(-0.00368208 * clamped))
        case .mate(let n):
            return n > 0 ? 1 : 0
        }
    }
}

struct EngineInfo: Sendable, Equatable {
    var multipv = 1
    var depth = 0
    var seldepth = 0
    var score: EngineScore?
    var nodes: Int64 = 0
    var nps: Int64 = 0
    var timeMs: Int64 = 0
    var hashfull = 0
    var pv: [String] = []
}

enum UCIMessage: Sendable, Equatable {
    case info(EngineInfo)
    case infoString(String)
    case bestMove(String, ponder: String?)
    case readyOK
    case other(String)

    /// Parses one output line. An `info` line counts only when it carries both a score and a PV;
    /// lines that only report progress (currmove, nodes) come back as `.other`.
    static func parse(_ line: String) -> UCIMessage {
        let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = t.first else { return .other(line) }
        switch head {
        case "readyok":
            return .readyOK
        case "bestmove":
            guard t.count >= 2 else { return .other(line) }
            let ponder = t.count >= 4 && t[2] == "ponder" ? t[3] : nil
            return .bestMove(t[1], ponder: ponder)
        case "info":
            if t.count >= 2, t[1] == "string" {
                return .infoString(t.dropFirst(2).joined(separator: " "))
            }
            var info = EngineInfo()
            var i = 1
            func next() -> String? { i + 1 < t.count ? t[i + 1] : nil }
            while i < t.count {
                switch t[i] {
                case "depth": info.depth = Int(next() ?? "") ?? 0; i += 2
                case "seldepth": info.seldepth = Int(next() ?? "") ?? 0; i += 2
                case "multipv": info.multipv = Int(next() ?? "") ?? 1; i += 2
                case "nodes": info.nodes = Int64(next() ?? "") ?? 0; i += 2
                case "nps": info.nps = Int64(next() ?? "") ?? 0; i += 2
                case "time": info.timeMs = Int64(next() ?? "") ?? 0; i += 2
                case "hashfull": info.hashfull = Int(next() ?? "") ?? 0; i += 2
                case "score":
                    guard i + 2 < t.count, let v = Int(t[i + 2]) else { i += 1; continue }
                    info.score = t[i + 1] == "mate" ? .mate(v) : .centipawns(v)
                    i += 3
                    // Bounds are reported but the value is still the best estimate we have.
                    if i < t.count, t[i] == "lowerbound" || t[i] == "upperbound" { i += 1 }
                case "pv":
                    info.pv = Array(t[(i + 1)...])
                    i = t.count
                default:
                    i += 1
                }
            }
            return info.score != nil && !info.pv.isEmpty ? .info(info) : .other(line)
        default:
            return .other(line)
        }
    }
}

enum MoveText {
    /// Numbers a SAN line for display: "3. Nf3 Nc6 4. Bb5" or, with Black to move, "3… Nc6 4. Bb5".
    static func numbered(_ san: [String], fullmove: Int, sideToMove: PieceColor) -> String {
        var out: [String] = []
        var number = fullmove
        var white = sideToMove == .white
        for (i, move) in san.enumerated() {
            if white {
                out.append("\(number). \(move)")
            } else if i == 0 {
                out.append("\(number)… \(move)")
            } else {
                out.append(move)
            }
            if !white { number += 1 }
            white.toggle()
        }
        return out.joined(separator: " ")
    }
}

/// How far one search goes.
enum SearchLimit: Sendable, Equatable {
    case time(seconds: Int)
    case depth(Int)
    case infinite

    var goCommand: String {
        switch self {
        case .time(let seconds): "go movetime \(seconds * 1000)"
        case .depth(let depth): "go depth \(depth)"
        case .infinite: "go infinite"
        }
    }

    /// The limit for searching a finished position again. A time limit is simply repeated, since
    /// the warm table makes the second search go deeper; a depth limit has to grow, or the
    /// engine would answer from the table at once with the same line.
    func extended(by steps: Int) -> SearchLimit {
        guard case .depth(let depth) = self else { return self }
        return .depth(depth + 4 * steps)
    }
}
