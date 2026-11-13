import SwiftUI

enum EngineSettings {
    static let threadsKey = "engine.threads"
    static let hashKey = "engine.hashMB"
    static let limitKindKey = "engine.limitKind"
    static let searchSecondsKey = "engine.searchSeconds"
    static let searchDepthKey = "engine.searchDepth"

    static var maxThreads: Int { ProcessInfo.processInfo.activeProcessorCount }
    /// Four threads: every iPhone has at least two performance cores and four efficiency cores,
    /// and running all of them heats the phone into throttling within a minute or two.
    static var defaultThreads: Int { min(4, maxThreads) }
    static let defaultHashMB = 256
    static let hashChoices = [64, 128, 256, 512]
    /// While the phone reports `.serious`, the engine runs on at most this many threads.
    static let warmThreads = 2

    /// A search stops at a time or a depth, so that the phone does not heat up over a position
    /// nobody is looking at any more.
    enum LimitKind: String, CaseIterable {
        case time, depth
    }
    static let defaultLimitKind = LimitKind.time
    /// Seconds per search; 0 searches until stopped.
    static let defaultSearchSeconds = 20
    static let searchChoices = [5, 10, 20, 30, 60, 0]
    static let defaultSearchDepth = 22
    static let depthRange = 8...40

    static func limit(kind: LimitKind, seconds: Int, depth: Int) -> SearchLimit {
        switch kind {
        case .time: seconds > 0 ? .time(seconds: seconds) : .infinite
        case .depth: .depth(depth)
        }
    }
}

enum AnnotationSettings {
    static let inaccuracyKey = "annotation.inaccuracy"
    static let mistakeKey = "annotation.mistake"
    static let blunderKey = "annotation.blunder"
}

struct SettingsView: View {
    @AppStorage(EngineSettings.threadsKey) private var threads = EngineSettings.defaultThreads
    @AppStorage(EngineSettings.hashKey) private var hashMB = EngineSettings.defaultHashMB
    @AppStorage(EngineSettings.limitKindKey) private var limitKind = EngineSettings.defaultLimitKind
    @AppStorage(EngineSettings.searchSecondsKey) private var searchSeconds = EngineSettings.defaultSearchSeconds
    @AppStorage(EngineSettings.searchDepthKey) private var searchDepth = EngineSettings.defaultSearchDepth
    @AppStorage(AnnotationSettings.inaccuracyKey) private var inaccuracy = AnnotationThresholds.standard.inaccuracy
    @AppStorage(AnnotationSettings.mistakeKey) private var mistake = AnnotationThresholds.standard.mistake
    @AppStorage(AnnotationSettings.blunderKey) private var blunder = AnnotationThresholds.standard.blunder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                resourcesSection
                annotationSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var searchSection: some View {
        Section {
            Picker("Stop at", selection: $limitKind) {
                Text("Time").tag(EngineSettings.LimitKind.time)
                Text("Depth").tag(EngineSettings.LimitKind.depth)
            }
            .pickerStyle(.segmented)
            switch limitKind {
            case .time:
                Picker("Search time", selection: $searchSeconds) {
                    ForEach(EngineSettings.searchChoices, id: \.self) {
                        Text($0 == 0 ? "Unlimited" : "\($0) s").tag($0)
                    }
                }
            case .depth:
                Stepper("Depth: \(searchDepth)", value: $searchDepth, in: EngineSettings.depthRange)
            }
        } header: {
            Text("Search")
        } footer: {
            Text(limitKind == .time
                 ? "Each position is searched for this long. Tap \u{25B6} to search it again, deeper."
                 : "Each position is searched to this depth. Tap \u{25B6} to search 4 plies deeper.")
        }
    }

    private var resourcesSection: some View {
        Section {
            Stepper("Threads: \(threads)", value: $threads, in: 1...EngineSettings.maxThreads)
            Picker("Hash", selection: $hashMB) {
                ForEach(EngineSettings.hashChoices, id: \.self) { Text("\($0) MB").tag($0) }
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("More threads search faster but heat the phone. When it gets warm the engine drops to \(EngineSettings.warmThreads) threads, and if it overheats analysis pauses.")
        }
    }

    private var annotationSection: some View {
        Section {
            // Each threshold stays at least a tenth of a pawn inside its neighbours.
            thresholdStepper("Inaccuracy ?!", value: $inaccuracy, from: 0.1, to: mistake - 0.1)
            thresholdStepper("Mistake ?", value: $mistake, from: inaccuracy + 0.1, to: blunder - 0.1)
            thresholdStepper("Blunder ??", value: $blunder, from: mistake + 0.1, to: AnnotationThresholds.clampPawns)
            if inaccuracy != AnnotationThresholds.standard.inaccuracy
                || mistake != AnnotationThresholds.standard.mistake
                || blunder != AnnotationThresholds.standard.blunder {
                Button("Restore Defaults") {
                    inaccuracy = AnnotationThresholds.standard.inaccuracy
                    mistake = AnnotationThresholds.standard.mistake
                    blunder = AnnotationThresholds.standard.blunder
                }
            }
        } header: {
            Text("Game analysis")
        } footer: {
            Text("When a game is annotated, a move is marked by how many pawns it loses against the engine's best move. Evaluations beyond ±\(Int(AnnotationThresholds.clampPawns)) pawns, and mates, count as \(Int(AnnotationThresholds.clampPawns)).")
        }
    }

    private func thresholdStepper(_ label: String, value: Binding<Double>, from low: Double, to high: Double) -> some View {
        // max(): the bounds are sums of tenths, which binary floating point can leave a hair
        // apart in the wrong order, and an inverted ClosedRange traps.
        let range = low...max(low, high)
        return Stepper(value: Binding(
            // Rounded to tenths: repeated 0.1 steps accumulate binary rounding error.
            get: { value.wrappedValue },
            set: { value.wrappedValue = ($0 * 10).rounded() / 10 }
        ), in: range, step: 0.1) {
            LabeledContent(label, value: String(format: "%.1f pawns", value.wrappedValue))
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Engine", value: "Creatica AB")
            Text("Creatica AB is an alpha-beta engine using NNUE evaluation. Its evaluation code and networks come from Stockfish and are licensed under the GNU General Public License v3, so this app is distributed under the GPL v3 as well.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Engine source code", destination: URL(string: "https://github.com/creatica-soft/libchess")!)
        }
    }
}
