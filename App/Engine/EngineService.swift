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

    /// Who asked for a search. The Position and Games tabs share the one engine; a client can
    /// stop only its own search, so one tab's housekeeping never cuts off the other's.
    enum Client: Equatable {
        case position
        case game
    }

    struct AnalysisLine: Equatable {
        var info: EngineInfo
        /// The PV in SAN, converted by libchess against `analyzedFEN`.
        var san: [String]
    }

    /// What a search that reached its limit found, from the side to move's point of view.
    struct SearchResult: Equatable {
        var score: EngineScore
        var depth: Int
        var bestMove: String
        var pv: [String]
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
    /// Whose search `analyzedFEN` is.
    private(set) var owner: Client?
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
    /// The caller waiting in `search`, resumed with the result, or nil if the search was stopped.
    private var waiter: CheckedContinuation<SearchResult?, Never>?

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
    /// so a running search is stopped first. An interactive one is restarted here; one awaited
    /// through `search` returns nil, and its caller decides whether to ask again.
    func configure(threads: Int, hashMB: Int) {
        guard threads != self.threads || hashMB != self.hashMB else { return }
        self.threads = threads
        self.hashMB = hashMB
        let resume = searching && waiter == nil ? analyzedFEN.map { ($0, owner ?? .position) } : nil
        halt()
        send("setoption name Threads value \(threads)")
        send("setoption name Hash value \(hashMB)")
        send("isready")
        if let (fen, client) = resume { analyze(fen: fen, limit: searchLimit, for: client) }
    }

    /// Searches `fen` within `limit`, replacing any search in progress, and publishes its lines.
    func analyze(fen: String, limit: SearchLimit, for client: Client) {
        halt()
        analyzedFEN = fen
        completedFEN = nil
        owner = client
        lines = [:]
        searchLimit = limit
        send("position fen \(fen)")
        send(limit.goCommand)
        outstandingSearches += 1
        searching = true
    }

    /// Searches `fen` to `limit` and returns what it found, or nil if the search was stopped
    /// before reaching its limit: by `stop`, by another search, or by `configure`.
    func search(fen: String, limit: SearchLimit, for client: Client) async -> SearchResult? {
        await withCheckedContinuation { continuation in
            analyze(fen: fen, limit: limit, for: client)
            waiter = continuation
        }
    }

    /// Stops `client`'s search, if the current one is its.
    func stop(_ client: Client) {
        guard owner == client else { return }
        halt()
    }

    /// Stops `client`'s search and forgets it, for a position the engine should not search.
    func clear(_ client: Client) {
        guard owner == client else { return }
        halt()
        analyzedFEN = nil
        completedFEN = nil
        lines = [:]
    }

    private func halt() {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
        guard searching else { return }
        send("stop")
        searching = false
    }

    private func send(_ command: String) {
        command.withCString { creatica_engine_send($0) }
    }

    private func handle(_ line: String) {
        switch UCIMessage.parse(line) {
        case .readyOK:
            ready = true
        case .bestMove(let move, _):
            outstandingSearches = max(0, outstandingSearches - 1)
            guard outstandingSearches == 0, searching else { return }
            searching = false
            completedFEN = analyzedFEN
            if let waiter {
                self.waiter = nil
                let best = lines[1]
                waiter.resume(returning: best?.info.score.map {
                    SearchResult(score: $0, depth: best?.info.depth ?? 0, bestMove: move,
                                 pv: best?.info.pv ?? [move], san: best?.san ?? [])
                })
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
    nonisolated static func validationError(fen: String) -> String? {
        var reason = [CChar](repeating: 0, count: 256)
        let ok = creatica_validate_fen(fen, &reason, Int32(reason.count))
        return ok == 1 ? nil : String(cString: reason)
    }

    enum Terminal: Equatable {
        case checkmate
        case stalemate
    }

    /// For a valid position: whether the side to move has no legal move, and why.
    nonisolated static func terminal(fen: String) -> Terminal? {
        switch creatica_terminal_state(fen) {
        case 1: .checkmate
        case 2: .stalemate
        default: nil
        }
    }

    nonisolated static func san(fen: String, uci: [String]) -> [String] {
        guard !uci.isEmpty else { return [] }
        var out = [CChar](repeating: 0, count: 4096)
        creatica_uci_to_san(fen, uci.joined(separator: " "), &out, Int32(out.count))
        return String(cString: out).split(separator: " ").map(String.init)
    }

    /// One move of a replayed game: its long-algebraic form and the position after it.
    struct ReplayedMove: Equatable {
        var uci: String
        var fenAfter: String
    }

    /// Plays `san` from `fen`, stopping at the first move libchess cannot read or finds illegal;
    /// the result is shorter than `san` exactly when that happened.
    nonisolated static func replay(fen: String, san: [String]) -> [ReplayedMove] {
        guard !san.isEmpty else { return [] }
        var out = [CChar](repeating: 0, count: 128 * (san.count + 1))
        let played = Int(creatica_replay_san(fen, san.joined(separator: " "), &out, Int32(out.count)))
        let lines = String(cString: out).split(separator: "\n").prefix(played)
        return lines.compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            return ReplayedMove(uci: String(line[..<space]), fenAfter: String(line[line.index(after: space)...]))
        }
    }

    struct LegalMove: Equatable, Sendable {
        var uci: String
        var san: String
    }

    /// Every legal move in `fen`.
    nonisolated static func legalMoves(fen: String) -> [LegalMove] {
        var out = [CChar](repeating: 0, count: 16 * 256)
        let n = Int(creatica_legal_moves(fen, &out, Int32(out.count)))
        return String(cString: out).split(separator: "\n").prefix(n).compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count == 2 ? LegalMove(uci: String(parts[0]), san: String(parts[1])) : nil
        }
    }

    /// The FEN after playing `uci` from `fen`, or nil if any of the moves is illegal.
    nonisolated static func play(fen: String, uci: [String]) -> String? {
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
