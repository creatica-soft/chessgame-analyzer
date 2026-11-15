import Foundation
import UniformTypeIdentifiers

/// One game as read from a PGN file: its tags in file order and its main line in SAN.
struct PGNGame: Sendable, Equatable, Identifiable {
    let id = UUID()
    var tags: [(name: String, value: String)] = []
    /// The main line. Comments, variations, NAGs, move numbers and !? glyphs are dropped.
    var moves: [String] = []
    /// "1-0", "0-1", "1/2-1/2" or "*".
    var result = "*"

    subscript(tag: String) -> String? {
        tags.first { $0.name == tag }?.value
    }

    /// The position the game starts from: the FEN tag if there is one.
    var startFEN: String {
        if let fen = self["FEN"], !fen.isEmpty { return fen }
        return Position.startFEN
    }

    /// "White – Black", from the tags.
    var title: String {
        "\(player("White")) – \(player("Black"))"
    }

    private func player(_ tag: String) -> String {
        guard let name = self[tag], !name.isEmpty, name != "?" else { return tag }
        return name
    }

    /// Event, site and date, the parts that are known.
    var subtitle: String {
        [self["Event"], self["Date"]]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "?" && $0 != "????.??.??" }
            .joined(separator: " · ")
    }

    static func == (a: PGNGame, b: PGNGame) -> Bool {
        a.id == b.id
    }
}

enum PGNParser {
    static let results: Set<String> = ["1-0", "0-1", "1/2-1/2", "*"]

    /// Reads every game in `text`. A game ends at its result token, or where the next game's tags
    /// begin; a file with no tags at all is read as a single game. Games without moves are dropped.
    static func parse(_ text: String) -> [PGNGame] {
        var games: [PGNGame] = []
        var current = PGNGame()
        var inMovetext = false

        func finish() {
            if !current.moves.isEmpty { games.append(current) }
            current = PGNGame()
            inMovetext = false
        }

        var scanner = Scanner(text)
        while let ch = scanner.peek() {
            switch ch {
            case "[":
                // A tag only where a tag can be: before the movetext, or starting the next game.
                if inMovetext { finish() }
                if let tag = scanner.readTag() { current.tags.append(tag) }
            case "{":
                scanner.skip(past: "}")
            case ";":
                scanner.skip(past: "\n")
            case "(":
                scanner.skipVariation()
            case "%" where scanner.atLineStart:
                scanner.skip(past: "\n")   // the export-format escape mechanism
            default:
                if ch.isWhitespace || ch == ")" {
                    scanner.advance()
                    continue
                }
                let token = scanner.readToken()
                if results.contains(token) {
                    current.result = token
                    finish()
                } else if let san = cleanSAN(token) {
                    current.moves.append(san)
                    inMovetext = true
                } else if token.first?.isNumber == true || token.hasPrefix("$") {
                    inMovetext = true   // a move number or NAG
                }
            }
        }
        finish()
        return games
    }

    /// The SAN in a movetext token, without a leading move number or trailing !? glyphs; nil for
    /// tokens that are not moves (move numbers, NAGs, ellipses).
    static func cleanSAN(_ raw: String) -> String? {
        var token = Substring(raw)
        // "12.e4" and "12...e5": numbers written against the move.
        if let firstNonDigit = token.firstIndex(where: { !$0.isNumber }), firstNonDigit != token.startIndex,
           token[firstNonDigit] == "." {
            token = token[firstNonDigit...].drop { $0 == "." }
        }
        token = token.drop { $0 == "." }
        while let last = token.last, last == "!" || last == "?" { token = token.dropLast() }
        guard let first = token.first, !token.hasPrefix("$") else { return nil }
        var san = String(token)
        // Castling is sometimes written with zeros.
        if san.hasPrefix("0-0") { san = san.replacingOccurrences(of: "0", with: "O") }
        // "e.p." written after an en passant capture, or a null move written as Z0, is not a move.
        guard first.isLetter || first == "0", san != "e.p.", san != "Z0" else { return nil }
        return san
    }

    private struct Scanner {
        private let chars: [Character]
        private var i = 0

        init(_ text: String) { chars = Array(text) }

        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        mutating func advance() { i += 1 }

        var atLineStart: Bool { i == 0 || chars[i - 1] == "\n" }

        mutating func skip(past terminator: Character) {
            while i < chars.count, chars[i] != terminator { i += 1 }
            i += 1
        }

        /// Skips a parenthesised variation, nested ones and comments inside it included.
        mutating func skipVariation() {
            var depth = 0
            while i < chars.count {
                switch chars[i] {
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { i += 1; return }
                case "{":
                    skip(past: "}")
                    continue
                case ";":
                    skip(past: "\n")
                    continue
                default: break
                }
                i += 1
            }
        }

        /// `[Name "Value"]`, with \" and \\ escapes in the value.
        mutating func readTag() -> (name: String, value: String)? {
            i += 1   // "["
            var name = ""
            while i < chars.count, chars[i] != "]", !chars[i].isWhitespace, chars[i] != "\"" {
                name.append(chars[i]); i += 1
            }
            while i < chars.count, chars[i] != "\"", chars[i] != "]" { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    value.append(chars[i]); i += 1
                }
            }
            skip(past: "]")
            return name.isEmpty ? nil : (name, value)
        }

        mutating func readToken() -> String {
            var token = ""
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace || "{}();[".contains(c) { break }
                token.append(c); i += 1
            }
            if token.isEmpty { i += 1 }   // never stall on an unexpected character
            return token
        }
    }
}

/// Reading a PGN file chosen in Files or opened in the app from elsewhere.
enum PGNFile {
    /// The type of .pgn files: whichever type the system gives the extension (another chess app
    /// may declare one), and the one this app declares in its Info.plist.
    static var types: [UTType] {
        var types: [UTType] = []
        if let system = UTType(filenameExtension: "pgn") { types.append(system) }
        if let declared = UTType("org.creatica.chess-analyzer.pgn"), !types.contains(declared) { types.append(declared) }
        return types + [.plainText]
    }

    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        // PGN is meant to be ASCII; files in the wild are UTF-8 or Latin-1.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
