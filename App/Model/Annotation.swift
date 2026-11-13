import Foundation

/// How a move compares with the engine's best, by the evaluation it gives away.
enum MoveQuality: Sendable, Equatable, CaseIterable {
    case good
    case inaccuracy
    case mistake
    case blunder

    /// The PGN annotation glyph and its numeric annotation glyph (NAG).
    var symbol: String? {
        switch self {
        case .good: nil
        case .inaccuracy: "?!"
        case .mistake: "?"
        case .blunder: "??"
        }
    }

    var nag: Int? {
        switch self {
        case .good: nil
        case .inaccuracy: 6
        case .mistake: 2
        case .blunder: 4
        }
    }
}

/// The loss, in pawns, at which a move becomes an inaccuracy, a mistake and a blunder.
struct AnnotationThresholds: Sendable, Equatable {
    var inaccuracy = 0.3
    var mistake = 1.0
    var blunder = 2.0

    static let standard = AnnotationThresholds()

    /// Evaluations are clamped to this many pawns before they are compared, and a mate counts as
    /// the clamp. Without it, going from +15 to +12 would be a "blunder" though both are won, and
    /// a mate in 3 against a mate in 5 would be a loss of thousands of centipawns.
    static let clampPawns = 10.0

    /// Classifies a move from two scores, both from the point of view of the side that moved:
    /// the engine's best line before the move, and the position after it.
    func classify(best: EngineScore, played: EngineScore) -> MoveQuality {
        let loss = Self.pawns(best) - Self.pawns(played)
        if loss >= blunder { return .blunder }
        if loss >= mistake { return .mistake }
        if loss >= inaccuracy { return .inaccuracy }
        return .good
    }

    static func pawns(_ score: EngineScore) -> Double {
        switch score {
        case .centipawns(let cp): max(-clampPawns, min(clampPawns, Double(cp) / 100))
        case .mate(let n): n > 0 ? clampPawns : -clampPawns
        }
    }
}
