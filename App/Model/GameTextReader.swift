import Foundation

/// Reads a game from text that is not clean PGN: a printed page read by text recognition, or
/// text copied with Live Text. Such text has misread characters (0 for O, l for 1, 8 for B),
/// commentary between the moves, and lines out of order when a page has two columns.
///
/// Two things make it readable anyway. Move numbers: the text is cut into segments at each "12."
/// or "12...", so the moves for number 12 are found wherever they are on the page. And legality:
/// a position has only a few dozen legal moves, so a misread word is matched against them,
/// cheaply for the usual recognition confusions, and taken when exactly one is close. Every such
/// guess is reported, for the user to check.
enum GameTextReader {
    struct Correction: Equatable, Sendable {
        /// Index of the move in `moves`.
        var ply: Int
        var read: String
        var san: String
    }

    struct Result: Equatable, Sendable {
        /// Legal SAN from the start position.
        var moves: [String] = []
        var corrections: [Correction] = []
        /// Why reading stopped while the text still had numbered moves after the last one read.
        var stoppedAt: String?
        /// PGN tags found in the text, such as a photographed PGN file's: players, event, date.
        var tags: [Tag] = []
    }

    struct Tag: Equatable, Sendable {
        var name: String
        var value: String
    }

    private struct Segment {
        var number: Int?
        /// "12..." : the segment starts with Black's move.
        var blackFirst: Bool
        var tokens: [String]
        /// A result (1-0, 0-1, ½-½, *) closed it: the game ends with its moves.
        var endsGame = false
    }

    static func read(_ text: String, startFEN: String = Position.startFEN) -> Result {
        let segments = segment(text)
        var result = Result(tags: tags(in: text))
        guard let position = try? Position(fen: startFEN) else { return result }

        // Text without a single move number: take the moves in order.
        if !segments.contains(where: { $0.number != nil }) {
            var fen = position.fen
            for token in segments.flatMap(\.tokens) {
                guard let (move, corrected) = resolve(token, legal: EngineService.legalMoves(fen: fen)),
                      let next = EngineService.play(fen: fen, uci: [move.uci]) else {
                    if !result.moves.isEmpty || isMoveLike(token) {
                        result.stoppedAt = "Couldn't read “\(token)” as a legal move."
                    }
                    break
                }
                if corrected { result.corrections.append(Correction(ply: result.moves.count, read: token, san: move.san)) }
                result.moves.append(move.san)
                fen = next
            }
            return result
        }

        // Numbered text: for each move in turn, the first segment for its number with a legal move.
        let reader = NumberedReader(segments: segments)
        var state = NumberedReader.State(position: position)
        while state.moves.count <= 600 {
            let step = reader.options(state)
            var choice: NumberedReader.State?
            if step.options.count == 1 {
                choice = step.options[0]
            } else if step.options.count > 1 {
                // Two legal moves are as close to what was read (n4: h4 or b4?). Read on with
                // each: the wrong one usually makes a later move impossible.
                // Each tied reading is read on; one wins if it gets further, or as far with clearly
                // less guessing.
                let reach = step.options.map { reader.reach(from: $0, horizon: 60) }
                let ranked = reach.indices.sorted { reach[$0] > reach[$1] }
                let first = reach[ranked[0]], second = reach[ranked[1]]
                if first.plies > second.plies || first.cost + 0.5 <= second.cost {
                    choice = step.options[ranked[0]]
                } else {
                    let sans = step.options.compactMap(\.moves.last).joined(separator: " or ")
                    state.stoppedAt = "\(step.label): “\(step.token ?? "")” could be \(sans); the moves after it don't tell which."
                }
            } else {
                state.stoppedAt = step.stopReason
            }
            guard let next = choice else { break }
            state = next
        }
        result.moves = state.moves
        result.corrections = state.corrections
        result.stoppedAt = state.stoppedAt
        return result
    }

    /// Reading numbered text one ply at a time, as a pure step so that it can also be tried ahead.
    private struct NumberedReader {
        let segments: [Segment]

        struct State {
            var position: Position
            var used = Set<Int>()
            /// The segment the last move came from: if a result closed it, the game is over.
            var last: Int?
            /// What followed White's move in its segment: normally Black's reply.
            var carry: [String] = []
            var moves: [String] = []
            var corrections: [Correction] = []
            var stoppedAt: String?
            /// The sum of the corrections' costs: how much the text had to be bent to read so.
            var cost = 0.0
        }

        struct Step {
            /// The states each candidate move leads to: one if the word was clear, several on a tie.
            var options: [State] = []
            var token: String?
            var label: String
            /// Why there is no option; nil when the game simply ends here.
            var stopReason: String?
        }

        func options(_ state: State) -> Step {
            let number = state.position.fullmoveNumber
            let color = state.position.sideToMove
            let label = "Move \(number)\(color == .white ? "." : "…")"
            let fen = state.position.fen
            var firstFailure: String?

            func advance(_ token: String, segment: Int?) -> [State] {
                let found = candidates(token, legal: EngineService.legalMoves(fen: fen))
                return found.compactMap { c in
                    let move = c.move
                    guard let nextFEN = EngineService.play(fen: fen, uci: [move.uci]),
                          let next = try? Position(fen: nextFEN) else { return nil }
                    var s = state
                    s.position = next
                    s.cost += c.cost
                    if c.corrected { s.corrections.append(Correction(ply: s.moves.count, read: token, san: move.san)) }
                    s.moves.append(move.san)
                    if let segment {
                        s.used.insert(segment)
                        s.last = segment
                        s.carry = color == .white ? Array(segments[segment].tokens.dropFirst()) : []
                    } else {
                        s.carry = []
                    }
                    return s
                }
            }

            if color == .black, let reply = state.carry.first {
                let found = advance(reply, segment: nil)
                if !found.isEmpty { return Step(options: found, token: reply, label: label) }
                firstFailure = reply
            }
            for (i, segment) in segments.enumerated() where segment.number == number && !state.used.contains(i) {
                if color == .white, segment.blackFirst { continue }
                guard let first = segment.tokens.first else { continue }
                let found = advance(first, segment: i)
                if !found.isEmpty { return Step(options: found, token: first, label: label) }
                firstFailure = firstFailure ?? first
            }

            if let last = state.last, segments[last].endsGame, firstFailure == nil {
                return Step(label: label)
            }
            if let firstFailure {
                return Step(token: firstFailure, label: label,
                            stopReason: "\(label): couldn't read “\(firstFailure)” as a legal move.")
            }
            let later = segments.contains { ($0.number ?? 0) > number && !$0.tokens.isEmpty }
            return Step(label: label, stopReason: later ? "\(label) wasn't found in the text." : nil)
        }

        /// How far reading gets, and how much correcting it took: a wrong reading tends to stop
        /// early or to need many guesses later.
        struct Reach: Comparable {
            var plies: Int
            var cost: Double
            static func < (a: Reach, b: Reach) -> Bool {
                a.plies != b.plies ? a.plies < b.plies : a.cost > b.cost
            }
        }

        /// Reads on from `state` for up to `horizon` plies, taking the closest reading at every
        /// later tie (trying them all multiplies quickly).
        func reach(from state: State, horizon: Int) -> Reach {
            var s = state
            let limit = state.moves.count + horizon
            while s.moves.count < limit {
                let step = options(s)
                guard let next = step.options.min(by: { $0.cost < $1.cost }) else {
                    // The end of the game counts as reaching the horizon.
                    return Reach(plies: step.stopReason == nil ? limit : s.moves.count, cost: s.cost)
                }
                s = next
            }
            return Reach(plies: limit, cost: s.cost)
        }
    }

    // MARK: - Tags

    /// `[Name "value"]` lines, with the quotes as recognition returns them: ' “ ” or missing.
    static func tags(in text: String) -> [Tag] {
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`´")
        var tags: [Tag] = []
        for match in text.matches(of: /\[\s*([A-Za-z][A-Za-z0-9_]*)\s+([^\]\n]*)\]/) {
            let name = String(match.1)
            let value = String(match.2).trimmingCharacters(in: quotes.union(.whitespaces))
            guard !tags.contains(where: { $0.name == name }) else { break }   // a second game's tags
            tags.append(Tag(name: name, value: value))
        }
        return tags
    }

    // MARK: - Tokens

    /// Cuts the text into segments at move numbers, dropping comments in braces and parentheses.
    private static func segment(_ text: String) -> [Segment] {
        var cleaned = ""
        var depth = 0
        for ch in normalized(text) {
            switch ch {
            case "(", "{", "[": depth += 1; cleaned.append(" ")
            case ")", "}", "]": depth = max(0, depth - 1); cleaned.append(" ")
            default: if depth == 0 { cleaned.append(ch) }
            }
        }
        var segments = [Segment(number: nil, blackFirst: false, tokens: [])]
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        // The last token was a move number with its dots ("14."), so a bare number now is a move.
        var afterNumber = false
        for raw in cleaned.components(separatedBy: separators) where !raw.isEmpty {
            var token = Substring(raw)
            defer { if !raw.allSatisfy({ $0.isNumber || $0 == "." }) { afterNumber = false } }
            if PGNParser.results.contains(String(token)) || token == "½-½" {
                segments[segments.count - 1].endsGame = true
                continue
            }
            // A move number: "12.", "12...", "12" alone, or written against the move as "12.Nf3".
            let digits = token.prefix { $0.isNumber }
            if !digits.isEmpty, let n = Int(digits), n > 0, n < 400 {
                let rest = token.dropFirst(digits.count)
                let dots = rest.prefix { $0 == "." }
                let previous = segments[segments.count - 1]
                let misreadMove = rest.isEmpty && digits.count == 2 && previous.number != nil
                    && previous.tokens.isEmpty && !previous.endsGame && afterNumber
                if (rest.isEmpty || !dots.isEmpty) && !misreadMove {
                    afterNumber = !dots.isEmpty
                    segments.append(Segment(number: n, blackFirst: dots.count >= 2, tokens: []))
                    token = rest.dropFirst(dots.count)
                    if token.isEmpty { continue }
                }
            }
            let move = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".:!?"))
            if isMoveLike(move), !segments[segments.count - 1].endsGame { segments[segments.count - 1].tokens.append(move) }
        }
        return segments
    }

    /// Characters that text recognition returns for the ones printed: Cyrillic and Greek letters
    /// that look Latin, typographic dashes, the multiplication sign for a capture.
    private static let lookalikes: [Character: Character] = [
        "а": "a", "в": "b", "б": "6", "с": "c", "е": "e", "о": "o", "р": "p", "х": "x", "к": "k",
        "А": "A", "В": "B", "С": "C", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P",
        "Т": "T", "Х": "X", "ο": "o", "Ο": "O", "Β": "B", "Κ": "K", "Ν": "N",
        "–": "-", "—": "-", "‐": "-", "−": "-", "×": "x",
        // A thin f in some fonts.
        "†": "f", "ƒ": "f", "ſ": "f",
        // An 8 in some fonts.
        "&": "8",
    ]

    static func normalized(_ text: String) -> String {
        String(text.map { lookalikes[$0] ?? $0 }).replacingOccurrences(of: "…", with: "...")
    }

    /// Whether a word could be a move at all: castling, or a square in it, counting the characters
    /// a file letter or a rank digit is commonly misread as.
    static func isMoveLike(_ token: String) -> Bool {
        let t = token.uppercased().replacingOccurrences(of: "0", with: "O")
        if t.hasPrefix("O-O") || t == "OO" || t == "OOO" { return true }
        // Line and page numbers; a two-digit word may still be a misread pawn move (94 for g4).
        guard (2...9).contains(token.count), !(token.count > 2 && token.allSatisfy(\.isNumber)) else { return false }
        let chars = Array(token)
        if zip(chars, chars.dropFirst()).contains(where: { couldBe($0, Self.files) && couldBe($1, Self.ranks) }) {
            return true
        }
        // A piece move whose file letter was misread past recognising: Ko3.
        return (3...6).contains(chars.count) && "KQRBN".contains(chars[0])
            && couldBe(chars[chars.count - 1], Self.ranks)
    }

    private static let files: Set<Character> = Set("abcdefgh")
    private static let ranks: Set<Character> = Set("12345678")

    private static func couldBe(_ c: Character, _ set: Set<Character>) -> Bool {
        let lower = Character(c.lowercased())
        return set.contains(c) || set.contains(lower)
            || confusable.contains { ($0.contains(c) || $0.contains(lower)) && !$0.isDisjoint(with: set) }
    }

    // MARK: - Matching

    /// The legal move `token` most plausibly is, and whether reading it took a guess; nil if no
    /// legal move is close, or several are equally close.
    static func resolve(_ token: String, legal: [EngineService.LegalMove]) -> (EngineService.LegalMove, Bool)? {
        let found = candidates(token, legal: legal)
        return found.count == 1 ? (found[0].move, found[0].corrected) : nil
    }

    struct Candidate {
        var move: EngineService.LegalMove
        /// Reading the word as this move is a guess.
        var corrected: Bool
        /// How far the word is from the move: 0 when it reads as printed.
        var cost: Double
    }

    /// The legal moves `token` may be, each with whether reading it so is a guess: one when the
    /// word is clear or one move is clearly closest, several when they are about as close.
    static func candidates(_ token: String, legal: [EngineService.LegalMove]) -> [Candidate] {
        guard !legal.isEmpty else { return [] }
        var t = token.trimmingCharacters(in: CharacterSet(charactersIn: "!?+#"))
        for suffix in ["e.p.", "ep"] where t.hasSuffix(suffix) && t.count > suffix.count + 1 {
            t = String(t.dropLast(suffix.count))
        }

        // Castling, however it was printed or misread.
        let castle = t.uppercased().replacingOccurrences(of: "0", with: "O").filter { $0 != "-" && $0 != "–" && $0 != "—" }
        if castle == "OO" || castle == "OOO" {
            let san = castle == "OO" ? "O-O" : "O-O-O"
            return legal.filter { key($0.san) == key(san) }.prefix(1).map { Candidate(move: $0, corrected: false, cost: 0) }
        }

        // Long algebraic, as some books print it: Ng1-f3, e2-e4, e7xd8=Q.
        if let m = t.wholeMatch(of: /([KQRBN])?([a-h][1-8])[-x:–]?([a-h][1-8])=?([QRBNqrbn])?/) {
            let uci = "\(m.2)\(m.3)\((m.4.map(String.init) ?? "").lowercased())"
            if let move = legal.first(where: { $0.uci == uci }) { return [Candidate(move: move, corrected: false, cost: 0)] }
        }

        let target = key(t)
        let exact = legal.filter { key($0.san) == target }
        if exact.count == 1 { return [Candidate(move: exact[0], corrected: false, cost: 0)] }

        // The closest legal moves, if close.
        var scored = legal.map { (move: $0, cost: distance(target, key($0.san))) }
        // A figurine the recognizer could not read: try the word without its first character
        // against moves with a piece letter.
        if let first = target.first, !"KQRBNabcdefghO".contains(first) {
            let rest = String(target.dropFirst())
            scored += legal.filter { "KQRBN".contains($0.san.first ?? " ") }
                .map { (move: $0, cost: distance(rest, String(key($0.san).dropFirst())) + 0.5) }
        }
        scored.sort { $0.cost < $1.cost }
        guard let best = scored.first, best.cost <= 1.0 else { return [] }
        var out: [Candidate] = []
        for s in scored where s.cost < best.cost + 0.5 && !out.contains(where: { $0.move == s.move }) {
            out.append(Candidate(move: s.move, corrected: true, cost: s.cost))
        }
        return out
    }

    /// A move without the marks that are often dropped or misread: capture, check, promotion sign.
    static func key(_ san: String) -> String {
        san.filter { !"x:×-+#=".contains($0) }
    }

    /// Edit distance where the classic text-recognition confusions cost less than other mistakes.
    static func distance(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return Double(b.count) }
        if b.isEmpty { return Double(a.count) }
        var previous = (0...b.count).map(Double.init)
        for i in 1...a.count {
            var current = [Double(i)] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let substitution = previous[j - 1] + substitutionCost(a[i - 1], b[j - 1])
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }

    private static let confusable: [Set<Character>] = [
        ["0", "O", "o", "Q"], ["1", "l", "I", "|", "i", "7"], ["5", "S", "s", "6"], ["8", "B", "3"],
        ["6", "b"], ["9", "g", "q"], ["c", "e"], ["h", "b", "n"], ["f", "t", "T"], ["K", "k"], ["N", "n"],
        ["R", "K"], ["4", "A"], ["2", "Z", "z"],
    ]

    private static func substitutionCost(_ x: Character, _ y: Character) -> Double {
        if x == y { return 0 }
        // A capital read for a small letter or the other way round: KC3 for Kc3.
        if x.lowercased() == y.lowercased() { return 0.4 }
        if confusable.contains(where: { $0.contains(x) && $0.contains(y) }) { return 0.4 }
        return 1
    }
}
