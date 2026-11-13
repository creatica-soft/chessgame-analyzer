import Charts
import SwiftUI

extension MoveQuality {
    var color: Color {
        switch self {
        case .good: .primary
        case .inaccuracy: Color(red: 0.85, green: 0.62, blue: 0.0)
        case .mistake: .orange
        case .blunder: .red
        }
    }

    var label: String {
        switch self {
        case .good: "Good"
        case .inaccuracy: "Inaccuracy"
        case .mistake: "Mistake"
        case .blunder: "Blunder"
        }
    }
}

/// One game: the board at the selected move, what the engine thinks of that move, and the game
/// as a whole.
struct GameView: View {
    @Bindable var model: GameAnalysisModel
    let game: LoadedGame
    let onAnalyzePosition: (String) -> Void

    var body: some View {
        // Empty for a moment if the model already holds another game: never index past this one.
        let assessments = model.assessments.count == game.plies.count
            ? model.assessments : Array(repeating: nil, count: game.plies.count)
        let ply = min(model.selectedPly, game.plies.count)
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(game.pgn.title).font(.headline).multilineTextAlignment(.center)
                    if !game.pgn.subtitle.isEmpty {
                        Text(game.pgn.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                EvalBar(whiteShare: model.line.map { line in
                    line.score.fromWhite(sideToMove: model.sideToMove(at: line.startPly)).whiteShare
                } ?? model.eval(at: ply)?.whiteShare(sideToMove: model.sideToMove(at: ply)))
                board
                navigation
                status
                if let error = game.readError ?? model.readNote {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                MoveDetail(model: model, game: game, assessments: assessments, onAnalyzePosition: onAnalyzePosition)
                EvalChart(model: model, game: game, assessments: assessments)
                GameSummary(game: game, assessments: assessments)
                MoveList(model: model, game: game, assessments: assessments)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var board: some View {
        let ply = min(model.selectedPly, game.plies.count)
        let fen = model.line?.fen ?? game.fens[ply]
        return BoardView(
            position: (try? Position(fen: fen)) ?? .empty,
            flipped: model.flipped,
            selected: nil,
            bestMove: model.line == nil ? betterMove(at: ply) : nil,
            lastMove: lastMove(at: ply),
            onTap: { _ in }
        )
        .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
            // Swipe left for the next move, right for the previous one.
            if abs(drag.translation.width) > abs(drag.translation.height) {
                let delta = drag.translation.width < 0 ? 1 : -1
                if model.line != nil { model.stepLine(delta) } else { model.step(delta) }
            }
        })
    }

    /// The move that should have been played instead of the one that led here: the best move
    /// of the position before, unless it is the move played.
    private func betterMove(at ply: Int) -> (from: Square, to: Square)? {
        guard ply > 0, let best = model.eval(at: ply - 1)?.result?.bestMove,
              best != game.plies[ply - 1].uci else { return nil }
        return BoardView.squares(ofUCI: best)
    }

    private func lastMove(at ply: Int) -> (from: Square, to: Square)? {
        if let line = model.line {
            return line.index > 0 ? BoardView.squares(ofUCI: line.moves[line.index - 1].uci) : nil
        }
        return ply > 0 ? BoardView.squares(ofUCI: game.plies[ply - 1].uci) : nil
    }

    @ViewBuilder
    private var navigation: some View {
        if let line = model.line {
            HStack {
                Button("Start of Line", systemImage: "backward.end.fill") { model.selectLine(0) }
                    .disabled(line.index == 0)
                Spacer()
                Button("Previous", systemImage: "chevron.left") { model.stepLine(-1) }
                    .disabled(line.index == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Text(line.index == 0 ? "Start" : LineMoves.label(line, line.index - 1))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.tint)
                    .frame(minWidth: 110)
                Button("Next", systemImage: "chevron.right") { model.stepLine(1) }
                    .disabled(line.index == line.moves.count)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                Button("End of Line", systemImage: "forward.end.fill") { model.selectLine(line.moves.count) }
                    .disabled(line.index == line.moves.count)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
        } else {
            gameNavigation
        }
    }

    private var gameNavigation: some View {
        let ply = min(model.selectedPly, game.plies.count)
        return HStack {
            Button("Start", systemImage: "backward.end.fill") { model.select(ply: 0) }
                .disabled(ply == 0)
            Spacer()
            Button("Previous", systemImage: "chevron.left") { model.step(-1) }
                .disabled(ply == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Text(ply == 0 ? "Start" : moveLabel(game.plies[ply - 1]))
                .font(.headline.monospacedDigit())
                .frame(minWidth: 110)
            Button("Next", systemImage: "chevron.right") { model.step(1) }
                .disabled(ply == game.plies.count)
                .keyboardShortcut(.rightArrow, modifiers: [])
            Spacer()
            Button("End", systemImage: "forward.end.fill") { model.select(ply: game.plies.count) }
                .disabled(ply == game.plies.count)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
    }

    @ViewBuilder
    private var status: some View {
        let total = model.evals.count
        if model.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let reason = model.pauseReason {
                        Label(reason, systemImage: "pause.circle").foregroundStyle(.secondary)
                    } else {
                        // In moves, as the game is numbered: positions are twice as many.
                        Text("Analyzing move \(moveNumber(atPosition: model.searchingPly ?? model.analyzedPositions)) of \(lastMoveNumber)…")
                    }
                    Spacer()
                    Button("Stop") { model.stopAnalysis() }
                }
                .font(.footnote)
                ProgressView(value: Double(model.analyzedPositions), total: Double(max(total, 1)))
                if let note = model.thermalNote, model.pauseReason == nil {
                    Label(note, systemImage: "thermometer.high").font(.caption).foregroundStyle(.orange)
                }
            }
        } else if model.isUnanalyzed {
            HStack {
                Button("Analyze Game", systemImage: "play.fill") { model.startAnalysis() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Text(estimateText).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } else if !model.isComplete {
            HStack {
                Text("Analyzed \(Int((Double(model.analyzedPositions) / Double(max(total, 1)) * 100).rounded()))% of the game's \(lastMoveNumber) moves.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Continue Analysis", systemImage: "play.fill") { model.startAnalysis() }
                    .font(.footnote)
            }
        } else if model.failedPositions > 0 {
            Text("\(model.failedPositions) positions could not be analysed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

extension GameView {
    /// "38 moves, about 1 min 17 s": what pressing Analyze Game commits to.
    var estimateText: String {
        let moves = "\(lastMoveNumber) moves"
        guard let estimate = model.remainingEstimate else { return moves }
        return "\(moves), about \(estimate.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))"
    }

    /// The game's last move number: what "38 moves" means.
    var lastMoveNumber: Int { game.plies.last?.number ?? 0 }

    /// The number of the move that position `i` (after `i` plies) is judged for: the move played
    /// from it, or the last move at the end.
    func moveNumber(atPosition i: Int) -> Int {
        guard !game.plies.isEmpty else { return 0 }
        return game.plies[min(i, game.plies.count - 1)].number
    }
}

func moveLabel(_ ply: LoadedGame.Ply) -> String {
    "\(ply.number)\(ply.color == .white ? "." : "…") \(ply.san)"
}

/// What the engine thinks of the move that led to the board's position.
private struct MoveDetail: View {
    let model: GameAnalysisModel
    let game: LoadedGame
    let assessments: [MoveAssessment?]
    let onAnalyzePosition: (String) -> Void

    var body: some View {
        let ply = min(model.selectedPly, game.plies.count)
        VStack(alignment: .leading, spacing: 8) {
            if let line = model.line {
                lineDetail(line)
            } else if ply == 0 {
                Text("Start position").font(.headline)
                if let eval = model.eval(at: 0) {
                    Text("Evaluation \(eval.text(sideToMove: model.sideToMove(at: 0)))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                let move = game.plies[ply - 1]
                if let a = assessments[ply - 1] {
                    HStack(alignment: .firstTextBaseline) {
                        Text(moveLabel(move) + (a.quality.symbol ?? "")).font(.headline)
                        Text(a.isBest ? "Best move" : a.quality.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(a.isBest ? .green : a.quality.color)
                        Spacer()
                        Text(scoreChange(a, mover: move.color))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !a.isBest, let best = a.bestLine.first {
                        Text("Best was \(best), shown by the arrow.").font(.callout)
                    }
                    if let line = model.previewLine(beforePly: ply) {
                        LineMoves(line: line, current: nil) { i in
                            model.showBestLine(beforePly: ply)
                            model.selectLine(i + 1)
                        }
                    }
                    HStack {
                        Button(a.isBest ? "Play Engine Line" : "Play Best Line", systemImage: "play.circle") {
                            model.showBestLine(beforePly: ply)
                        }
                        .disabled(model.previewLine(beforePly: ply) == nil)
                        Spacer()
                        Button("Analyze Position", systemImage: "magnifyingglass") {
                            onAnalyzePosition(game.fens[ply - 1])
                        }
                    }
                    .font(.footnote)
                } else {
                    Text(moveLabel(move)).font(.headline)
                    Text("Not analysed yet.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func lineDetail(_ line: EngineLine) -> some View {
        let from = line.startPly == 0 ? "the start" : moveLabel(game.plies[line.startPly - 1])
        HStack(alignment: .firstTextBaseline) {
            Text("Engine line").font(.headline)
            Text("after \(from)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(line.score.fromWhite(sideToMove: model.sideToMove(at: line.startPly)).text)
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
        LineMoves(line: line, current: line.index - 1) { i in model.selectLine(i + 1) }
        HStack {
            Button("Back to Game", systemImage: "arrow.uturn.backward") { model.exitLine() }
            Spacer()
            Button("Analyze Position", systemImage: "magnifyingglass") { onAnalyzePosition(line.fen) }
        }
        .font(.footnote)
    }

    /// "+0.20 → −0.25", from White's side like every score in the app.
    private func scoreChange(_ a: MoveAssessment, mover: PieceColor) -> String {
        "\(a.bestScore.fromWhite(sideToMove: mover).text) → \(a.playedScore.fromWhite(sideToMove: mover).text)"
    }
}

/// The evaluation over the game, as White's share of the eval bar; tap or drag to pick a move.
private struct EvalChart: View {
    let model: GameAnalysisModel
    let game: LoadedGame
    let assessments: [MoveAssessment?]
    @State private var selection: Int?

    private struct Point: Identifiable {
        let ply: Int
        let share: Double
        var id: Int { ply }
    }

    var body: some View {
        let points = model.evals.indices.compactMap { i in
            model.evals[i].map { Point(ply: i, share: $0.whiteShare(sideToMove: model.sideToMove(at: i))) }
        }
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Move", p.ply), yStart: .value("Level", 0.5), yEnd: .value("White", p.share))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                LineMark(x: .value("Move", p.ply), y: .value("White", p.share))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(Array(assessments.enumerated()), id: \.offset) { i, a in
                if let a, a.quality == .mistake || a.quality == .blunder,
                   let share = points.first(where: { $0.ply == i + 1 })?.share {
                    PointMark(x: .value("Move", i + 1), y: .value("White", share))
                        .foregroundStyle(a.quality.color)
                        .symbolSize(30)
                }
            }
            RuleMark(x: .value("Move", model.selectedPly))
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1))
            RuleMark(y: .value("Level", 0.5))
                .foregroundStyle(Color.secondary.opacity(0.4))
        }
        .chartXScale(domain: 0...max(game.plies.count, 1))
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                // Plies on the axis, labelled as move numbers.
                AxisValueLabel { if let ply = value.as(Int.self) { Text("\(ply / 2 + 1)") } }
            }
        }
        .chartXSelection(value: $selection)
        .onChange(of: selection) { if let selection { model.select(ply: selection) } }
        .frame(height: 120)
        .accessibilityLabel("Evaluation graph")
    }
}

/// Inaccuracies, mistakes, blunders and average loss, for each player.
private struct GameSummary: View {
    let game: LoadedGame
    let assessments: [MoveAssessment?]

    var body: some View {
        let white = PlayerSummary.make(plies: game.plies, assessments: assessments, color: .white)
        let black = PlayerSummary.make(plies: game.plies, assessments: assessments, color: .black)
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text(name("White")).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(name("Black")).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            ForEach([MoveQuality.inaccuracy, .mistake, .blunder], id: \.self) { q in
                GridRow {
                    Text("\(q.label) \(q.symbol ?? "")").foregroundStyle(q.color)
                    Text("\(white.counts[q] ?? 0)").monospacedDigit()
                    Text("\(black.counts[q] ?? 0)").monospacedDigit()
                }
            }
            GridRow {
                Text("Average loss (cp)")
                Text(white.acpl.map(String.init) ?? "–").monospacedDigit()
                Text(black.acpl.map(String.init) ?? "–").monospacedDigit()
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func name(_ tag: String) -> String {
        guard let name = game.pgn[tag], !name.isEmpty, name != "?" else { return tag }
        return name
    }
}

/// The moves, two to a row, coloured by quality. Tap one to go to it.
private struct MoveList: View {
    let model: GameAnalysisModel
    let game: LoadedGame
    let assessments: [MoveAssessment?]

    private struct Row: Identifiable {
        let number: Int
        let white: Int?   // ply index
        let black: Int?
        var id: Int { number }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.fixed(40), alignment: .trailing),
                            GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)], spacing: 4) {
            ForEach(rows) { row in
                Text("\(row.number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                cell(row.white)
                cell(row.black)
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        for (i, ply) in game.plies.enumerated() {
            if ply.color == .white {
                rows.append(Row(number: ply.number, white: i, black: nil))
            } else if let last = rows.last, last.number == ply.number, last.black == nil {
                rows[rows.count - 1] = Row(number: last.number, white: last.white, black: i)
            } else {
                rows.append(Row(number: ply.number, white: nil, black: i))
            }
        }
        return rows
    }

    @ViewBuilder
    private func cell(_ index: Int?) -> some View {
        if let index {
            let a = assessments[index]
            let selected = model.selectedPly == index + 1
            Button {
                model.select(ply: index + 1)
            } label: {
                Text(game.plies[index].san + (a?.quality.symbol ?? ""))
                    .font(.callout.weight(a?.quality == .good || a == nil ? .regular : .semibold))
                    .foregroundStyle(a?.quality.color ?? .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.2) : .clear))
            }
            .buttonStyle(.plain)
        } else {
            Text("…").foregroundStyle(.secondary)
        }
    }
}

/// An engine line as a row of moves; tapping one plays the line to it.
struct LineMoves: View {
    let line: EngineLine
    /// The move shown on the board, highlighted.
    let current: Int?
    let onSelect: (Int) -> Void

    /// "12. Nf3" or "12… Nf6" for move `i` of the line.
    static func label(_ line: EngineLine, _ i: Int) -> String {
        let start = (try? Position(fen: line.startFEN)) ?? Position()
        let ply = i + (start.sideToMove == .black ? 1 : 0)
        let number = start.fullmoveNumber + ply / 2
        return "\(number)\(ply % 2 == 0 ? "." : "…") \(line.moves[i].san)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(line.moves.indices, id: \.self) { i in
                        Button { onSelect(i) } label: {
                            Text(text(i))
                                .font(.callout.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(i == current ? Color.accentColor.opacity(0.25) : .clear))
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
            }
            .onChange(of: current) { if let current { withAnimation { proxy.scrollTo(current, anchor: .center) } } }
        }
    }

    /// Numbers before White's moves, and before the first move.
    private func text(_ i: Int) -> String {
        let full = Self.label(line, i)
        let isWhite = full.contains(". ")
        return (i == 0 || isWhite) ? full : line.moves[i].san
    }
}
