import Foundation
import Testing
import UIKit
@testable import ChessAnalyzer

/// The whole reading of a real board (finder, crops, classifier) over frames of the training
/// clips, for comparing builds: how many frames read with every square right, a square or two
/// wrong, many wrong, or no board found. Runs only when given frames, so the normal test run
/// skips it:
///
///     TEST_RUNNER_BOARD_EVAL=tools/work/frames1:tools/work/labels1.json:12 xcodebuild ... test
///
/// (absolute paths; frames-dir:labels.json:every-nth, several separated by commas). The labels map
/// a clip (IMG_9101) to the board part of its FEN. A board turned round is read as the app reads
/// it, from the pieces; "turned" counts frames that are right only when turned a half turn.
struct BoardEvalTests {
    @Test func readsTheClips() throws {
        guard let spec = ProcessInfo.processInfo.environment["BOARD_EVAL"] else { return }
        for part in spec.split(separator: ",") {
            let f = part.split(separator: ":").map(String.init)
            let dir = URL(fileURLWithPath: f[0])
            // Labels "-": no positions known; each frame's reading is printed instead.
            let labels = f[1] == "-" ? [:] : try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: f[1])))
            let every = f.count > 2 ? Int(f[2]) ?? 10 : 10
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }.sorted()
            var counts = ["right": 0, "1-2 wrong": 0, "3-9 wrong": 0, "10+ wrong": 0, "no board": 0, "turned": 0]
            var shown = 0
            var doubtful: [Int] = []
            for (k, name) in names.enumerated() where k % every == 0 {
                let clip = String(name.prefix(8))
                if f[1] == "-" {
                    guard let image = UIImage(contentsOfFile: dir.appendingPathComponent(name).path),
                          let photo = DiagramReader.upright(image) else { continue }
                    guard let reading = try? BoardReader.read(photo) else { print("READ \(name) no board"); continue }
                    var position = Position(); position.squares = reading.pieces; let fen = String(position.fen.split(separator: " ")[0])
                    let q = reading.quad
                    let corners = [q.bottomLeft, q.bottomRight, q.topRight, q.topLeft].map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
                    print("READ \(name) \(fen) doubtful \(reading.doubtful.count) \(reading.doubtful.map(\.algebraic).joined(separator: ",")) corners \(corners) photo \(photo.width)x\(photo.height)")
                    continue
                }
                guard let fen = labels[clip], let expected = try? Position(fen: fen + " w - - 0 1"),
                      let image = UIImage(contentsOfFile: dir.appendingPathComponent(name).path),
                      let photo = DiagramReader.upright(image) else { continue }
                guard let reading = try? BoardReader.read(photo) else {
                    counts["no board", default: 0] += 1
                    continue
                }
                let wrong = (0..<64).filter { reading.pieces[$0] != expected[$0] }.count
                doubtful.append(reading.doubtful.count)
                let wrongTurned = (0..<64).filter { reading.pieces[63 - $0] != expected[$0] }.count
                if wrong > 2, wrongTurned <= 2 { counts["turned", default: 0] += 1; continue }
                let key = wrong == 0 ? "right" : wrong <= 2 ? "1-2 wrong" : wrong <= 9 ? "3-9 wrong" : "10+ wrong"
                counts[key, default: 0] += 1
                if wrong > 9, shown < 5 {
                    shown += 1
                    print("EVAL \(name): \(wrong) wrong")
                }
            }
            let total = counts.values.reduce(0, +)
            print("EVAL \(dir.lastPathComponent): \(total) frames  "
                  + ["right", "1-2 wrong", "3-9 wrong", "10+ wrong", "turned", "no board"].map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: "  ")
                  + "  | doubtful squares per frame: none \(doubtful.filter { $0 == 0 }.count), mean "
                  + String(format: "%.1f", Double(doubtful.reduce(0, +)) / Double(max(1, doubtful.count))))
        }
    }

    /// The live reader over the clips' frames in order, as the camera would give them: per settle
    /// rule, clips settled right, settled with squares wrong, and never settled, and the frames
    /// it took. Runs only when given clips:
    ///
    ///     TEST_RUNNER_BOARD_LIVE=frames-dir:labels.json:every-nth-clip,... xcodebuild ... test
    ///
    /// The rules: no square doubtful at all ("none doubtful"), or every square's likeliest
    /// reading at least so likely.
    @Test func settlesOnTheClips() throws {
        guard let spec = ProcessInfo.processInfo.environment["BOARD_LIVE"] else { return }
        let rules: [Double?] = [nil, 0.5, 0.6, 0.7, 0.8]
        func label(_ r: Double?) -> String { r.map { "sure \($0)" } ?? "none doubtful" }
        for part in spec.split(separator: ",") {
            let f = part.split(separator: ":").map(String.init)
            let dir = URL(fileURLWithPath: f[0])
            let labels = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: f[1])))
            let every = f.count > 2 ? Int(f[2]) ?? 1 : 1
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }.sorted()
            let clips = Dictionary(grouping: names) { String($0.prefix(8)) }.keys.sorted()
            var results: [String: (right: Int, wrong: Int, never: Int, frames: [Int], wrongSquares: Int)] = [:]
            for (k, clip) in clips.enumerated() where k % every == every - 1 {
                guard let fen = labels[clip], let expected = try? Position(fen: fen + " w - - 0 1") else { continue }
                // Each frame read once; the rules replay the same frames.
                var frames: [BoardReader.Frame?] = []
                for name in names where name.hasPrefix(clip) {
                    guard let image = UIImage(contentsOfFile: dir.appendingPathComponent(name).path),
                          let photo = DiagramReader.upright(image) else { continue }
                    frames.append(try? BoardReader.read(frame: photo))
                }
                for rule in rules {
                    var reader = LiveBoardReader()
                    reader.minimumSure = rule
                    var r = results[label(rule)] ?? (0, 0, 0, [], 0)
                    var settledAt: Int?
                    for (i, frame) in frames.enumerated() {
                        guard let frame else { continue }
                        reader.add(frame)
                        if reader.isSettled { settledAt = i + 1; break }
                    }
                    if let settledAt, let reading = try? reader.reading() {
                        let wrong = (0..<64).filter { reading.pieces[$0] != expected[$0] }.count
                        if wrong == 0 { r.right += 1 } else { r.wrong += 1; r.wrongSquares += wrong }
                        r.frames.append(settledAt)
                        if wrong > 0 { print("LIVE \(clip) \(label(rule)): settled after \(settledAt) frames with \(wrong) wrong") }
                    } else {
                        r.never += 1
                    }
                    results[label(rule)] = r
                }
            }
            for rule in rules {
                guard let r = results[label(rule)] else { continue }
                let mean = r.frames.isEmpty ? 0 : Double(r.frames.reduce(0, +)) / Double(r.frames.count)
                print("LIVE \(dir.lastPathComponent) \(label(rule)): settled right \(r.right), wrong \(r.wrong) (\(r.wrongSquares) squares), never \(r.never); "
                      + "frames to settle \(String(format: "%.1f", mean))")
            }
        }
    }
}
