import SwiftUI
import UIKit

enum AppTab: Hashable {
    case position
    case games
}

/// The two tabs, and what they share: the engine, its settings, and the conditions under which
/// it may run. The engine works for the visible tab only; the other one's analysis pauses.
struct RootView: View {
    let engine: EngineService
    let positionModel: AnalysisModel
    let gameModel: GameAnalysisModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.position
    @State private var openError: String?
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    @AppStorage(EngineSettings.threadsKey) private var threads = EngineSettings.defaultThreads
    @AppStorage(EngineSettings.hashKey) private var hashMB = EngineSettings.defaultHashMB
    @AppStorage(EngineSettings.limitKindKey) private var limitKind = EngineSettings.defaultLimitKind
    @AppStorage(EngineSettings.searchSecondsKey) private var searchSeconds = EngineSettings.defaultSearchSeconds
    @AppStorage(EngineSettings.searchDepthKey) private var searchDepth = EngineSettings.defaultSearchDepth
    @AppStorage(GameSettings.limitKindKey) private var gameLimitKind = GameSettings.defaultLimitKind
    @AppStorage(GameSettings.searchSecondsKey) private var gameSeconds = GameSettings.defaultSearchSeconds
    @AppStorage(GameSettings.searchDepthKey) private var gameDepth = GameSettings.defaultSearchDepth
    @AppStorage(AnnotationSettings.inaccuracyKey) private var inaccuracy = AnnotationThresholds.standard.inaccuracy
    @AppStorage(AnnotationSettings.mistakeKey) private var mistake = AnnotationThresholds.standard.mistake
    @AppStorage(AnnotationSettings.blunderKey) private var blunder = AnnotationThresholds.standard.blunder

    var body: some View {
        TabView(selection: $tab) {
            Tab("Position", systemImage: "checkerboard.rectangle", value: AppTab.position) {
                PositionView(model: positionModel)
            }
            Tab("Games", systemImage: "list.number", value: AppTab.games) {
                GamesView(model: gameModel) { fen in
                    if let position = try? Position(fen: fen) { positionModel.load(position) }
                    tab = .position
                }
            }
        }
        .onAppear {
            applySettings()
            engine.start(threads: effectiveThreads, hashMB: hashMB)
            positionModel.start()
            updateConditions()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demoGame") { runDemoGame() }
            if ProcessInfo.processInfo.arguments.contains("-demoScan") { tab = .games }
            #endif
        }
        .onChange(of: tab) { updateConditions() }
        .onChange(of: scenePhase) { updateConditions() }
        // A .pgn file opened in the app from Files or another app's share sheet.
        .onOpenURL { url in
            tab = .games
            do {
                openError = gameModel.importPGN(try PGNFile.read(url))
            } catch {
                openError = error.localizedDescription
            }
        }
        .alert("Couldn't Open the File", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .onChange(of: threads) { updateConditions() }
        .onChange(of: hashMB) { updateConditions() }
        .onChange(of: settingsSignature) { applySettings() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
            updateConditions()
        }
    }

    #if DEBUG
    /// Launched with -demoGame: analyses a short game and writes the annotated PGN to stderr
    /// (stdout belongs to the engine), so a device run can be checked from the console.
    private func runDemoGame() {
        tab = .games
        Task {
            while engine.status == .starting { try? await Task.sleep(for: .milliseconds(100)) }
            let start = Date()
            @MainActor func conditions() -> String {
                let p = ProcessInfo.processInfo
                return "thermal \(p.thermalState.rawValue) lowPower \(p.isLowPowerModeEnabled) threads \(engine.threads)"
            }
            fputs("demo: start, \(conditions()), limit \(gameModel.limit)\n", stderr)
            if let error = gameModel.importPGN(DemoGame.opera) { fputs("demo: \(error)\n", stderr); return }
            // -demoOpenOnly: just open it, as a user's game opens.
            if ProcessInfo.processInfo.arguments.contains("-demoOpenOnly") { return }
            gameModel.startAnalysis()
            var reported = 0
            while gameModel.isRunning {
                try? await Task.sleep(for: .milliseconds(250))
                while reported < gameModel.evals.count, let eval = gameModel.evals[reported] {
                    let r = eval.result
                    fputs("demo: position \(reported) depth \(r?.depth ?? 0) at \(String(format: "%.1f", Date().timeIntervalSince(start))) s, \(conditions())\n", stderr)
                    reported += 1
                }
            }
            let seconds = Date().timeIntervalSince(start)
            fputs("demo: analysed \(gameModel.analyzedPositions) positions in \(String(format: "%.1f", seconds)) s, \(conditions())\n", stderr)
            fputs((gameModel.annotatedPGN(annotator: "demo") ?? "") + "\n", stderr)
            // -demoSelect N [line K]: show move N, or the best line before it at its move K.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-demoSelect"), i + 1 < args.count, let ply = Int(args[i + 1]) {
                gameModel.select(ply: ply)
                if let j = args.firstIndex(of: "-demoLine"), j + 1 < args.count, let k = Int(args[j + 1]) {
                    gameModel.showBestLine(beforePly: ply)
                    gameModel.selectLine(k)
                    gameModel.stepLine(1)
                    gameModel.stepLine(-1)
                    fputs("demo: line at \(gameModel.line?.index ?? -1) of \(gameModel.line?.moves.count ?? 0)\n", stderr)
                }
            }
        }
    }
    #endif

    /// Changes whenever a search or annotation setting does.
    private var settingsSignature: [Double] {
        [Double(limitKind == .time ? 0 : 1), Double(searchSeconds), Double(searchDepth),
         Double(gameLimitKind == .time ? 0 : 1), Double(gameSeconds), Double(gameDepth),
         inaccuracy, mistake, blunder]
    }

    private func applySettings() {
        positionModel.searchLimit = EngineSettings.limit(kind: limitKind, seconds: searchSeconds, depth: searchDepth)
        gameModel.limit = GameSettings.limit(kind: gameLimitKind, seconds: gameSeconds, depth: gameDepth)
        gameModel.thresholds = AnnotationThresholds(inaccuracy: inaccuracy, mistake: mistake, blunder: blunder)
    }

    /// Threads for the current thermal state: the user's setting, capped while the phone is warm,
    /// and one when it is hot. Analysis goes on, more slowly, rather than stopping.
    private var effectiveThreads: Int {
        switch thermalState {
        case .critical: 1
        case .serious: min(threads, EngineSettings.warmThreads)
        default: threads
        }
    }

    private func updateConditions() {
        engine.configure(threads: effectiveThreads, hashMB: hashMB)
        let note: String? = effectiveThreads < threads
            ? (thermalState == .critical ? "The phone is hot: searching on one thread." : "The phone is warm: searching on \(effectiveThreads) threads.")
            : nil
        positionModel.thermalNote = note
        gameModel.thermalNote = note

        let shared: String? = if scenePhase != .active {
            "Paused while the app is in the background."
        } else {
            nil
        }
        // Pause the hidden tab before resuming the visible one, so its search is stopped first.
        if tab == .games {
            positionModel.setPaused(shared ?? "Paused while the Games tab uses the engine.")
            gameModel.setPaused(shared)
        } else {
            gameModel.setPaused(shared ?? "Paused while the Position tab uses the engine.")
            positionModel.setPaused(shared)
        }
    }
}

#if DEBUG
enum DemoGame {
    /// The same pixels on every device (an iPad's screen scale is 2, an iPhone's 3), so a demo
    /// reads alike everywhere.
    private static var fixedScale: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return format
    }

    /// The Opera Game's final position, 17. Rd8#.
    static let operaFinal = "1n1Rkb1r/p4ppp/4q3/4p1B1/4P3/8/PPP2PPP/2K5 b k - 1 17"

    /// A book page with a diagram of `fen`: caption, framed board with hatched dark squares,
    /// pieces from a font's chess symbols, the page turned by `degrees`.
    static func diagram(fen: String = operaFinal, degrees: Double = 2, font: String = "Menlo") -> UIImage {
        let size = CGSize(width: 1000, height: 1300)
        let position = (try? Position(fen: fen)) ?? .start
        return UIGraphicsImageRenderer(size: size, format: fixedScale).image { context in
            let cg = context.cgContext
            UIColor(white: 0.97, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: degrees * .pi / 180)
            cg.translateBy(x: -size.width / 2, y: -size.height / 2)
            let text: [NSAttributedString.Key: Any] = [.font: UIFont(name: "Georgia", size: 30) ?? .systemFont(ofSize: 30),
                                                       .foregroundColor: UIColor.black]
            ("Diagram 12. After 17. Rd8 mate. White's last move closed the game in style." as NSString)
                .draw(in: CGRect(x: 120, y: 120, width: 760, height: 120), withAttributes: text)
            let S = 70.0, x0 = 220.0, y0 = 300.0
            // Frame, a little outside the board.
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(4)
            cg.stroke(CGRect(x: x0 - 6, y: y0 - 6, width: 8 * S + 12, height: 8 * S + 12))
            for row in 0..<8 {
                for col in 0..<8 where (row + col) % 2 == 1 {
                    let r = CGRect(x: x0 + Double(col) * S, y: y0 + Double(row) * S, width: S, height: S)
                    cg.saveGState()
                    cg.clip(to: r)
                    cg.setLineWidth(1.6)
                    var t = -S
                    while t < S {
                        cg.move(to: CGPoint(x: r.minX + t, y: r.maxY))
                        cg.addLine(to: CGPoint(x: r.minX + t + S, y: r.minY))
                        t += 5
                    }
                    cg.strokePath()
                    cg.restoreGState()
                }
            }
            let pieceFont = UIFont(name: font, size: S * 1.15) ?? .systemFont(ofSize: S * 1.15)
            for sq in 0..<64 {
                guard let piece = position[sq] else { continue }
                let center = CGPoint(x: x0 + (Double(sq.file) + 0.5) * S, y: y0 + (7.5 - Double(sq.rank)) * S)
                func draw(_ glyph: String, _ color: UIColor) {
                    let s = NSAttributedString(string: glyph, attributes: [.font: pieceFont, .foregroundColor: color])
                    let b = s.size()
                    s.draw(at: CGPoint(x: center.x - b.width / 2, y: center.y - b.height / 2))
                }
                if piece.color == .white {
                    draw(piece.solidGlyph, .white)
                    draw(piece.outlineGlyph, .black)
                } else {
                    draw(piece.solidGlyph, .black)
                }
            }
        }
    }

    /// The Opera Game as a book prints it, in two columns, for -demoScan.
    static func page() -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        let columns = [
            "Morphy – Duke Karl\nParis 1858\n\n1. e4 e5\n2. Nf3 d6\n3. d4 Bg4\n4. dxe5 Bxf3\n5. Qxf3 dxe5\n6. Bc4 Nf6\n7. Qb3 Qe7\n8. Nc3 c6\n9. Bg5 b5",
            "10. Nxb5 cxb5\n11. Bxb5+ Nbd7\n12. O-O-O Rd8\n13. Rxd7 Rxd7\n14. Rd1 Qe6\n15. Bxd7+ Nxd7\n16. Qb8+ Nxb8\n17. Rd8# 1-0",
        ]
        return UIGraphicsImageRenderer(size: size, format: fixedScale).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia", size: 34) ?? .systemFont(ofSize: 34),
                .foregroundColor: UIColor.black,
            ]
            for (i, column) in columns.enumerated() {
                (column as NSString).draw(in: CGRect(x: 60 + CGFloat(i) * 600, y: 60, width: 480, height: 800),
                                          withAttributes: attributes)
            }
        }
    }

    /// Morphy v. the Duke of Brunswick and Count Isouard, Paris 1858.
    static let opera = """
    [Event "Paris"]
    [Site "Paris FRA"]
    [Date "1858.??.??"]
    [White "Paul Morphy"]
    [Black "Duke Karl / Count Isouard"]
    [Result "1-0"]

    1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7
    8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7
    14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0
    """
}
#endif
