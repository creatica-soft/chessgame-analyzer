import SwiftUI

/// The engine's verdict: the score, the best move and its line, and the search's progress.
struct AnalysisPanel: View {
    let model: AnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice {
                Label(notice.text, systemImage: notice.symbol)
                    .foregroundStyle(notice.tint)
                    .font(.callout)
            }
            ForEach(Array(model.currentLines.enumerated()), id: \.offset) { index, line in
                lineView(line, isBest: index == 0)
            }
            if model.currentLines.isEmpty, notice == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                }
            }
            if let footnote {
                Text(footnote).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func lineView(_ line: EngineService.AnalysisLine, isBest: Bool) -> some View {
        let position = model.position
        let score = line.info.score?.fromWhite(sideToMove: position.sideToMove)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(score?.text ?? "…")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 72, alignment: .leading)
                if let best = line.san.first {
                    Text("Best: \(best)").font(.headline)
                }
                Spacer()
                Text(stats(line.info))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                if isBest, !line.san.isEmpty {
                    Button("Play", systemImage: "arrow.right.circle.fill") { model.playBestMove() }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .accessibilityLabel("Play best move")
                }
            }
            Text(MoveText.numbered(line.san, fullmove: position.fullmoveNumber, sideToMove: position.sideToMove))
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func stats(_ info: EngineInfo) -> String {
        let nps = info.nps >= 1_000_000
            ? String(format: "%.1fM", Double(info.nps) / 1_000_000)
            : String(format: "%.0fk", Double(info.nps) / 1_000)
        return "depth \(info.depth)/\(info.seldepth)\n\(nps) nodes/s"
    }

    /// A quiet line under the analysis: why it is not searching, or searching less hard.
    private var footnote: String? {
        if notice != nil { return nil }
        if let note = model.thermalNote, model.isAnalyzing { return note }
        if model.searchCompleted, !model.currentLines.isEmpty {
            return "Search finished. Tap \u{25B6} at the top to search longer."
        }
        if !model.analysisEnabled, !model.isAnalyzing, !model.currentLines.isEmpty {
            return "Stopped. Tap \u{25B6} at the top to continue."
        }
        return nil
    }

    private struct Notice {
        let text: String
        let symbol: String
        let tint: Color
    }

    private var notice: Notice? {
        if model.engine.status == .starting {
            return Notice(text: "Starting engine…", symbol: "hourglass", tint: .secondary)
        }
        if let reason = model.invalidReason {
            return Notice(text: "Not a legal position: \(reason)", symbol: "exclamationmark.triangle", tint: .orange)
        }
        switch model.terminal {
        case .checkmate:
            let winner = model.position.sideToMove == .white ? "Black" : "White"
            return Notice(text: "Checkmate. \(winner) wins.", symbol: "flag.checkered", tint: .primary)
        case .stalemate:
            return Notice(text: "Stalemate.", symbol: "equal.circle", tint: .primary)
        case nil:
            break
        }
        if let reason = model.pauseReason {
            return Notice(text: reason, symbol: "pause.circle", tint: .secondary)
        }
        if !model.analysisEnabled, model.currentLines.isEmpty {
            return Notice(text: "Analysis is off. Tap \u{25B6} at the top to analyze.", symbol: "pause.circle", tint: .secondary)
        }
        return nil
    }
}

/// A horizontal bar showing White's share of the evaluation, 0...1; nil shows it level.
struct EvalBar: View {
    let whiteShare: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.2))
                Rectangle()
                    .fill(Color(white: 0.95))
                    .frame(width: geo.size.width * (whiteShare ?? 0.5))
                    .animation(.easeOut(duration: 0.3), value: whiteShare)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityLabel("Evaluation")
        .accessibilityValue(whiteShare.map { "White \(Int(($0 * 100).rounded())) percent" } ?? "none")
    }
}
