import CreaticaBridge
import Foundation
import Observation

/// The creatica_ab engine, driven over UCI through the C bridge.
///
/// There is one engine per process (the C++ side keeps global state), so there is one of these.
/// Every method runs on the main actor. Engine output arrives on an engine thread and is handed
/// over with `DispatchQueue.main.async`, which keeps the lines in order. Task hops do not
/// guarantee order, and here it matters: a `bestmove` must not overtake the `info` before it.
@MainActor
@Observable
final class EngineService {
    enum Status: Equatable {
        case starting
        case idle
        case analyzing
    }

    struct AnalysisLine: Equatable {
        var info: EngineInfo
        /// The PV in SAN, converted by libchess against `analyzedFEN`.
        var san: [String]
    }

    var status: Status {
        if !ready { return .starting }
        return searching ? .analyzing : .idle
    }

    /// The latest line for each multipv index, for `analyzedFEN`.
    private(set) var lines: [Int: AnalysisLine] = [:]
    private(set) var analyzedFEN: String?
    /// Set when the search of `analyzedFEN` reached its limit, rather than being stopped.
    private(set) var completedFEN: String?
    /// The thread count the engine was last given.
    private(set) var threads = 0
    private var hashMB = 0

    private var ready = false
    /// A `go` has been sent and neither a `stop` nor the search's own end has followed.
    private var searching = false
    /// Searches started minus `bestmove`s received. The engine answers every `go` with exactly
    /// one `bestmove`, and finishes the old search before it reads the next command, so output
    /// belongs to the newest search only while this is 1.
    private var outstandingSearches = 0
    private var sink: LineSink?
    private var searchLimit: SearchLimit = .infinite

    func start(threads: Int, hashMB: Int) {
        guard sink == nil else { return }
        let sink = LineSink { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(line) }
            }
        }
        self.sink = sink
        creatica_engine_start(lineCallback, Unmanaged.passUnretained(sink).toOpaque())
        // The protocol loop serves commands only after init(), so these can be queued at once.
        send("setoption name OnlineTablebase value false")
        configure(threads: threads, hashMB: hashMB)
    }

    /// Applies resource settings. The engine resizes its pool and table only between searches,
    /// so a running analysis is stopped and restarted around the change.
    func configure(threads: Int, hashMB: Int) {
        guard threads != self.threads || hashMB != self.hashMB else { return }
        self.threads = threads
        self.hashMB = hashMB
        let resume = searching ? analyzedFEN : nil
        stop()
        send("setoption name Threads value \(threads)")
        send("setoption name Hash value \(hashMB)")
        send("isready")
        if let resume { analyze(fen: resume, limit: searchLimit) }
    }

    /// Searches `fen` within `limit`, replacing any search in progress.
    func analyze(fen: String, limit: SearchLimit) {
        stop()
        analyzedFEN = fen
        completedFEN = nil
        lines = [:]
        searchLimit = limit
        send("position fen \(fen)")
        send(limit.goCommand)
        outstandingSearches += 1
        searching = true
    }

    func stop() {
        guard searching else { return }
        send("stop")
        searching = false
    }

    /// Stops and forgets the last analysis, for a position the engine should not search.
    func clear() {
        stop()
        analyzedFEN = nil
        completedFEN = nil
        lines = [:]
    }

    private func send(_ command: String) {
        command.withCString { creatica_engine_send($0) }
    }

    private func handle(_ line: String) {
        switch UCIMessage.parse(line) {
        case .readyOK:
            ready = true
        case .bestMove:
            outstandingSearches = max(0, outstandingSearches - 1)
            if outstandingSearches == 0, searching {
                searching = false
                completedFEN = analyzedFEN
            }
        case .info(let info):
            guard outstandingSearches == 1, let fen = analyzedFEN else { return }
            lines[info.multipv] = AnalysisLine(info: info, san: Self.san(fen: fen, uci: info.pv))
        case .infoString, .other:
            break
        }
    }

    // MARK: - libchess helpers
    //
    // These wait inside the bridge until the engine has built its tables, so call them only once
    // `status` has left `.starting`, or they block the main thread for the engine's start-up.

    /// nil when the engine can search `fen`, otherwise why not.
    static func validationError(fen: String) -> String? {
        var reason = [CChar](repeating: 0, count: 256)
        let ok = creatica_validate_fen(fen, &reason, Int32(reason.count))
        return ok == 1 ? nil : String(cString: reason)
    }

    enum Terminal: Equatable {
        case checkmate
        case stalemate
    }

    /// For a valid position: whether the side to move has no legal move, and why.
    static func terminal(fen: String) -> Terminal? {
        switch creatica_terminal_state(fen) {
        case 1: .checkmate
        case 2: .stalemate
        default: nil
        }
    }

    static func san(fen: String, uci: [String]) -> [String] {
        guard !uci.isEmpty else { return [] }
        var out = [CChar](repeating: 0, count: 4096)
        creatica_uci_to_san(fen, uci.joined(separator: " "), &out, Int32(out.count))
        return String(cString: out).split(separator: " ").map(String.init)
    }

    /// The FEN after playing `uci` from `fen`, or nil if any of the moves is illegal.
    static func play(fen: String, uci: [String]) -> String? {
        var out = [CChar](repeating: 0, count: 256)
        let played = creatica_play_moves(fen, uci.joined(separator: " "), &out, Int32(out.count))
        return played == uci.count ? String(cString: out) : nil
    }
}

/// Receives lines on the engine thread. Kept alive by `EngineService` for the life of the process.
private final class LineSink: Sendable {
    let receive: @Sendable (String) -> Void
    init(_ receive: @escaping @Sendable (String) -> Void) { self.receive = receive }
}

private let lineCallback: creatica_line_callback = { line, context in
    guard let context else { return }
    let sink = Unmanaged<LineSink>.fromOpaque(context).takeUnretainedValue()
    sink.receive(String(cString: line))
}
