import SwiftUI

@main
struct ChessAnalyzerApp: App {
    @State private var model = AnalysisModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
