import Foundation
import Testing
import UIKit
@testable import ChessAnalyzer

/// Writes the demo pictures (a book diagram and a printed game page, drawn by `DemoGame`) as PNG
/// files, for the website's samples page that App Review uses. Runs only when given a folder:
///
///     TEST_RUNNER_SAMPLES_DIR=/abs/path xcodebuild ... test -only-testing:ChessAnalyzerTests/DemoSamplesTests
struct DemoSamplesTests {
    @Test func writesTheSamples() throws {
        guard let dir = ProcessInfo.processInfo.environment["SAMPLES_DIR"] else { return }
        for (name, image) in [("diagram", DemoGame.diagram()), ("printed-game", DemoGame.page())] {
            let data = try #require(image.pngData())
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
}
