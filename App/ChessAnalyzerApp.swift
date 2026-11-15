import SwiftUI

@main
struct ChessAnalyzerApp: App {
    @State private var engine: EngineService
    @State private var positionModel: AnalysisModel
    @State private var gameModel: GameAnalysisModel

    init() {
        let engine = EngineService()
        _engine = State(initialValue: engine)
        _positionModel = State(initialValue: AnalysisModel(engine: engine))
        _gameModel = State(initialValue: GameAnalysisModel(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            if EngineBench.requested {
                EngineBench.View(engine: engine)
            } else {
                RootView(engine: engine, positionModel: positionModel, gameModel: gameModel)
            }
        }
    }
}
