import SwiftUI

/// Times the engine on the device, for comparing builds of it (profile-guided optimisation).
///
/// Launched with `-benchEngine [nodes]` (default 1,000,000): instead of the tabs, the app searches
/// a fixed set of positions on one thread with a 64 MB table, cleared before each, to the same
/// node count, in five rounds, and prints each round's time and nodes per second to stderr
/// (stdout belongs to the engine). Every round does the same work, so rounds and builds compare
/// by time alone. Nothing else uses the engine meanwhile. The positions are Arasan 2026 test positions
/// that are not in libchess's PGO training set (testsets/pgo_train.tsv), so a profile is not
/// judged on the positions it was trained on. Phones slow down as they warm up: the thermal state
/// is printed with each round, and builds are compared on rounds run cool.
enum EngineBench {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-benchEngine") }

    static var nodes: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-benchEngine"), i + 1 < args.count, let n = Int(args[i + 1]) else { return 1_000_000 }
        return n
    }

    static let positions = [
        "r1b2rk1/1p1nbppp/pq1p4/3B4/P2NP3/2N1p3/1PP3PP/R2Q1R1K w - - 0 1",
        "r2r1k2/p3qpp1/1p1ppn1p/n5B1/P1PNbP2/2P3Q1/4B1PP/4RRK1 w - - 0 1",
        "2rr3k/2qnbppp/p1n1p3/1p1pP3/3P1N2/1Q1BBP2/PP3P1P/1KR3R1 w - - 0 1",
        "3q1r1k/1b3ppp/p1n5/1p1pPB2/2rP4/P6N/1P2Q1PP/R4RK1 w - - 0 1",
        "r1b1k2r/1p1pppb1/p5pp/3P4/q2p1B2/3P1Q2/PPP2PPP/R3R1K1 w kq - 0 1",
        "R4bk1/2Bbp2p/2p2pp1/1rPp4/3P4/4P2P/4BPPK/1q1Q4 w - - 0 1",
        "r1r3k1/p3bppp/2bp3Q/q2pP1P1/1p1BP3/8/PPP1B2P/2KR2R1 w - - 0 1",
        "r2q3r/1p1bbQ2/4p1Bk/3pP3/1n1P1P1p/pP6/Pn4PP/R1B1R1K1 w - - 0 1",
        "1r2brk1/4n1p1/4p2p/p2pP1qP/2pP1NP1/P1Q1BK2/2P4R/6R1 b - - 0 1",
        "1rb2k1r/2q2pp1/p2b3p/2n3B1/2QN4/3B4/PpP3PP/1K2R2R w - - 0 1",
        "5rk1/1pp3p1/3ppr1p/pP2p2n/4P2q/P2PQ2P/2P1NPP1/R4RK1 b - - 0 1",
        "r4rk1/1b1n1pb1/3p2p1/1p1Pq1Bp/2p1P3/2P2RNP/1PBQ2P1/5R1K w - - 0 1",
    ]

    struct View: SwiftUI.View {
        let engine: EngineService
        @State private var report: [String] = ["Starting the engine…"]

        var body: some SwiftUI.View {
            List(report, id: \.self) { Text($0).font(.caption.monospaced()) }
                .task { await run() }
        }

        private func say(_ line: String) {
            report.append(line)
            fputs("bench: \(line)\n", stderr)
        }

        private func run() async {
            engine.start(threads: 1, hashMB: 64)
            while engine.status == .starting { try? await Task.sleep(for: .milliseconds(100)) }
            report = []
            let nodes = EngineBench.nodes
            say("\(positions.count) positions, \(nodes) nodes each, 1 thread, 64 MB")
            var times: [Double] = []
            for round in 1...5 {
                let thermal = ProcessInfo.processInfo.thermalState.rawValue
                var searched: Int64 = 0
                var seconds = 0.0
                for fen in positions {
                    engine.newGame()
                    let start = Date()
                    guard await engine.search(fen: fen, limit: .nodes(nodes), for: .position) != nil else {
                        say("round \(round): a search was stopped; no result")
                        return
                    }
                    seconds += Date().timeIntervalSince(start)
                    searched += engine.lines[1]?.info.nodes ?? 0
                }
                say("round \(round): \(searched) nodes in \(String(format: "%.2f", seconds)) s, "
                    + "\(Int(Double(searched) / seconds)) nps, thermal \(thermal) → \(ProcessInfo.processInfo.thermalState.rawValue)")
                times.append(seconds)
            }
            say("median \(String(format: "%.2f", times.sorted()[times.count / 2])) s")
            say("done")
        }
    }
}
