import Testing
import UIKit
import UniformTypeIdentifiers
@testable import ChessAnalyzer

/// The reader checks every move against libchess, so these need the engine the host app starts.
struct GameTextReaderTests {
    static let ruyLopez = ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4", "Nf6", "O-O", "Be7", "Re1", "b5"]

    @Test func cleanNumberedText() {
        let r = GameTextReader.read("1.e4 e5 2.Nf3 Nc6 3.Bb5 a6 4.Ba4 Nf6 5.O-O Be7 6.Re1 b5")
        #expect(r.moves == Self.ruyLopez)
        #expect(r.corrections.isEmpty)
        #expect(r.stoppedAt == nil)
    }

    @Test func recognitionConfusionsAreRepaired() {
        // 8 for B, 0 for O in castling, l for 1.
        let r = GameTextReader.read("1. e4 e5 2. Nf3 Nc6 3. 8b5 a6 4. Ba4 Nf6 5. 0-0 Be7 6. Rel b5")
        #expect(r.moves == Self.ruyLopez)
        #expect(r.corrections == [
            .init(ply: 4, read: "8b5", san: "Bb5"),
            .init(ply: 10, read: "Rel", san: "Re1"),
        ])
    }

    @Test func commentaryIsSkipped() {
        let r = GameTextReader.read("""
        1. e4 e5 2. Nf3 Nc6 3. Bb5 The Ruy Lopez (3. Bc4 would be the Italian). 3... a6
        4. Ba4, keeping the pin. 4... Nf6 5. O-O! Be7 6. Re1 b5 7. Bb3 d6 8. c3 O-O 1-0
        """)
        #expect(Array(r.moves.prefix(12)) == Self.ruyLopez)
        #expect(r.moves.count == 16)
        #expect(r.stoppedAt == nil)
    }

    @Test func columnsOutOfOrder() {
        // A two-column page read straight across, so the second column comes first.
        let r = GameTextReader.read("5. O-O Be7\n6. Re1 b5\n1. e4 e5\n2. Nf3 Nc6\n3. Bb5 a6\n4. Ba4 Nf6")
        #expect(r.moves == Self.ruyLopez)
    }

    @Test func longAlgebraic() {
        let r = GameTextReader.read("1. e2-e4 e7-e5 2. Ng1-f3 Nb8-c6 3. Bf1-b5 a7-a6 4. Bb5-c5")
        #expect(r.moves == ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"])
        #expect(r.stoppedAt?.contains("Bb5-c5") == true)   // not a bishop move
    }

    @Test func unreadableFigurine() {
        // A knight figurine the recognizer turned into "&": only Nc3 reaches c3 with a piece.
        let r = GameTextReader.read("1. e4 e5 2. &c3")
        #expect(r.moves == ["e4", "e5", "Nc3"])
        #expect(r.corrections.first?.san == "Nc3")
    }

    @Test func stopsWhenTwoMovesAreEquallyClose() {
        // After 1.e4 e5, "Nd3" is one letter from both Nf3 and Nc3: ask rather than guess.
        let r = GameTextReader.read("1. e4 e5 2. Nd3 Nc6 3. Bb5")
        #expect(r.moves == ["e4", "e5"])
        #expect(r.stoppedAt?.contains("Nd3") == true)
    }

    @Test func unnumberedText() {
        #expect(GameTextReader.read("e4 e5 Nf3 Nc6 Bb5").moves == ["e4", "e5", "Nf3", "Nc6", "Bb5"])
    }

    @Test func misreadsTextRecognitionReallyMade() {
        // From the rendered-page test before the fixes: t for f, Cyrillic б for 6, 0 for O.
        let r = GameTextReader.read("5. Qxf3 dxe5\n6. Bc4 Nt6\n7. Qb3 Qe7\n8. Nc3 cб",
                                    startFEN: "rn1qkbnr/ppp2ppp/3p4/4P3/4P3/5b2/PPP2PPP/RNBQKB1R w KQkq - 0 5")
        #expect(r.moves == ["Qxf3", "dxe5", "Bc4", "Nf6", "Qb3", "Qe7", "Nc3", "c6"])
        #expect(r.corrections.map(\.san) == ["Nf6"])
    }

    @Test func blacksMisreadReplyIsReported() {
        // Looks like a move, but no legal move for Black is close to it.
        let r = GameTextReader.read("1. e4 e5 2. Nf3 Kb1 3. Bc4")
        #expect(r.moves == ["e4", "e5", "Nf3"])
        #expect(r.stoppedAt?.contains("Kb1") == true)
    }

    @Test func misreadsFromAPhotographedPGNFile() {
        // From photos of a PGN file in an editor: a dagger for f, capitals for small letters,
        // the editor's line numbers between the lines, quotes misread in the tags.
        let r = GameTextReader.read("""
        6337
        [Event "rated classical game"]
        6338
        [White 'Alice"]
        6339
        [Black ''Bob"]
        6340
        1. e4 c5 2. Nf3 Nc6 3. d4 cxd4 4. Nxd4 NT6 5. Nc3 d6 6. Be3 g6 7. f3 Bg7 8. Qd2 0-0
        9. 0-0-0 Nxd4 10. Bxd4 Bе6 11. Kb1 Qa5 12. g4 Rfc8 13. a3 Rab8 14. g5 Ne8 15. Bxg7 Nxg7
        16. h4 †5 17. KA1 Kh8 1-0
        6356
        Lines: 16,228 Location: 235,860 Line: 6,335
        """)
        #expect(r.moves.count == 34)
        #expect(Array(r.moves.suffix(4)) == ["h4", "f5", "Ka1", "Kh8"])
        #expect(r.corrections.map(\.san) == ["Nf6", "Ka1"])
        #expect(r.stoppedAt == nil)            // the game ended at 1-0: what follows is not moves
        #expect(r.tags.map(\.value) == ["rated classical game", "Alice", "Bob"])
    }

    @Test func misreadsFromAPhotoOfTheScreen() throws {
        // Read by Live Text and by the app from photos of a PGN file: & for 8, 94 for g4 (a bare
        // number after a move number), n4 that is h4 or b4 (only a later move tells), Cyrillic
        // letters, commas for full stops, l for 1, 0 for Q.
        let r = GameTextReader.read("""
        1. e4 c5 2. Nf3 Nc6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 d6 6. Be3 g6 7. f3 Bg7
        8. Bс4 0-0 9. Qd2 Na5 10. Be2 Nc6 11. 0-0-0 Nxd4 12. Bxd4 Bе6 13. Kb1
        Qa5 14. 94 Rfc8 15. a3 Rab8 16. g5 Ne8 17. Bxg7 Nxg7 18. Nd5 Qd8 19. n4
        Nh5 20. Rhg1 Bxd5 21. exd5 Qc7 22. f4 Nxf4 23. Qxf4 Qxc2+ 24. Kal Qxe2
        25. Rge1 Qc4 26. Qe3 Rc7 27. Qxa7 Rbc8 28. Qe3 Qxh4 29. Rh1 Qa4 30. Qh3
        h5 31. gxh6 Kh7 32. Qf3 f6 33, Qe3 b5 34, Qe6 Rf8 35. Rc1 Rxc1+ 36. Rxc1
        Qa7 37. Rh1 b4 38. Rh3 f5 39, Rg3 Rf6 40, Qc8 f4 41. Rb3 f3 42. Qh3 0g1+ 0-1
        """)
        try #require(r.moves.count == 84, "stopped: \(r.stoppedAt ?? "-")")
        #expect(r.moves[26] == "g4")
        #expect(r.moves[36] == "h4")
        #expect(r.stoppedAt == nil)
        #expect(r.corrections.map(\.san) == ["g4", "h4", "Ka1", "Qg1+"])
    }

    @Test func ampersandForEight() {
        let r = GameTextReader.read("1. e4 c5 2. Nf3 Nc6 3. c3 Nf6 4. e5 Ng4 5, d4 d6 6. dxc5 dxe5 7. Qxd&+ Kxd8")
        #expect(r.moves.suffix(2) == ["Qxd8+", "Kxd8"])
        #expect(r.corrections.isEmpty)   // & is taken as 8 before matching, like a Cyrillic letter
    }

    @Test func aTieTheTextNeverSettlesIsReported() {
        // 3. n4: h4 or b4, and nothing after it tells them apart.
        let r = GameTextReader.read("1. e4 e5 2. Nf3 Nc6 3. n4")
        #expect(r.moves.count == 4)
        #expect(r.stoppedAt?.contains("h4 or b4") == true || r.stoppedAt?.contains("b4 or h4") == true)
    }

    @Test func capitalForSmallLetter() {
        let r = GameTextReader.read("1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O Nxe4 5. Re1 Nd6 6. NC3")
        #expect(r.moves.last == "Nc3")
    }

    @Test func nothingToRead() {
        let r = GameTextReader.read("Chapter 3. The Opera Game, played in Paris in 1858.")
        #expect(r.moves.isEmpty)
    }

    @Test func distanceWeighsConfusions() {
        #expect(GameTextReader.distance("Rel", "Re1") == 0.4)
        #expect(GameTextReader.distance("Rex", "Re1") == 1)
        #expect(GameTextReader.distance("Nf3", "Nf3") == 0)
    }
}

/// Real text recognition on a rendered page: two columns, as books print games.
struct TextRecognitionTests {
    static func page(columns: [String]) -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia", size: 34) ?? .systemFont(ofSize: 34),
                .foregroundColor: UIColor.black,
            ]
            for (i, column) in columns.enumerated() {
                (column as NSString).draw(in: CGRect(x: 60 + CGFloat(i) * 600, y: 60, width: 480, height: 800),
                                          withAttributes: attributes)
            }
        }
    }

    @Test func readsATwoColumnPage() async throws {
        let image = Self.page(columns: [
            "Morphy – Duke Karl\nParis 1858\n\n1. e4 e5\n2. Nf3 d6\n3. d4 Bg4\n4. dxe5 Bxf3\n5. Qxf3 dxe5\n6. Bc4 Nf6\n7. Qb3 Qe7\n8. Nc3 c6\n9. Bg5 b5",
            "10. Nxb5 cxb5\n11. Bxb5+ Nbd7\n12. O-O-O Rd8\n13. Rxd7 Rxd7\n14. Rd1 Qe6\n15. Bxd7+ Nxd7\n16. Qb8+ Nxb8\n17. Rd8# 1-0",
        ])
        let text = try await TextRecognizer.text(in: image)
        let r = GameTextReader.read(text)
        #expect(r.moves.count == 33, "read: \(text)")
        #expect(r.moves.last == "Rd8#")
        #expect(r.stoppedAt == nil)
    }
}

@MainActor
struct ClipboardTests {
    @Test func decodesTheFormsTextComesIn() throws {
        let move = "1. e4 e5 2. Nf3"
        #expect(ClipboardReader.decode(Data(move.utf8), typeIdentifier: UTType.utf8PlainText.identifier) == move)
        let rtf = try NSAttributedString(string: move).data(
            from: NSRange(location: 0, length: move.utf16.count),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #expect(ClipboardReader.decode(rtf, typeIdentifier: UTType.rtf.identifier)?.contains(move) == true)
        let html = Data("<p>1. e4 e5 <b>2. Nf3</b></p>".utf8)
        #expect(ClipboardReader.decode(html, typeIdentifier: UTType.html.identifier)?.contains(move) == true)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: move), requiringSecureCoding: true)
        #expect(ClipboardReader.decode(archived, typeIdentifier: ClipboardReader.attributedString) == move)
    }
}

/// A whole game as the app read it from a photo of the screen, against the game itself.
struct PhotographedGameTests {
    static let read = """
1. e4 c5 2. Nf3 Nc6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 d6 6. Be3 g6 7. f3 Bg7
8. Bс4 0-0 9. Qd2 Na5 10. Be2 Nc6 11. 0-0-0 Nxd4 12. Bxd4 Bе6 13. Kb1
Qa5 14. 94 Rfc8 15. a3 Rab8 16. g5 Ne8 17. Bxg7 Nxg7 18. Nd5 Qd8 19. n4
Nh5 20. Rhg1 Bxd5 21. exd5 Qc7 22. f4 Nxf4 23. Qxf4 Qxc2+ 24. Kal Qxe2
25. Rge1 Qc4 26. Qe3 Rc7 27. Qxa7 Rbc8 28. Qe3 Qxh4 29. Rh1 Qa4 30. Qh3
h5 31. gxh6 Kh7 32. Qf3 f6 33, Qe3 b5 34, Qe6 Rf8 35. Rc1 Rxc1+ 36. Rxc1
Qa7 37. Rh1 b4 38. Rh3 f5 39, Rg3 Rf6 40, Qc8 f4 41. Rb3 f3 42. Qh3 0g1+
43. Ka2 f2 44. Rf3 f1=Q 45. Rxf1 Qxf1 46, Qe3 Rf7 47. axb4 Qa6+ 48. Kо3
Ob7 49. Qe4 Qd7 50. Qd3 e6 51. b5 e5 52. b6 Rf4 53. Qa6 Rf7 54. Kb4 g5
55. Ka5 g4 56. b3 g3 57. Qd3+ Qf5 58. Qxg3 Qf3 59. b7 Qxg3 60. b8=Q QC3+
61. Ka4 Rf4+ 62. b4 Rc4 63. Qxd6 Qc2+ 64. Kb5 e4 65. Qe7+ Kg6 66. h7 Rc7
67. h8=N+ Kf5 68. Qe6+ Kf4 69. Ng6+ Kf3 70. Qh3+ Ke2 71. Nf4+ Kd2 72.
Q92+ Kc3 73. Ne2+ Kb2 74. d6 Qd3+ 75. Kb6 Qxd6+ 76. Kb5 Qd5+ 77. Kb6
Rb7+ 78. Каб Qb5# 0-1
"""
    static let game = "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 Nf6 Nc3 d6 Be3 g6 f3 Bg7 Bc4 O-O Qd2 Na5 Be2 Nc6 O-O-O Nxd4 Bxd4 Be6 Kb1 Qa5 g4 Rfc8 a3 Rab8 g5 Ne8 Bxg7 Nxg7 Nd5 Qd8 h4 Nh5 Rhg1 Bxd5 exd5 Qc7 f4 Nxf4 Qxf4 Qxc2+ Ka1 Qxe2 Rge1 Qc4 Qe3 Rc7 Qxa7 Rbc8 Qe3 Qxh4 Rh1 Qa4 Qh3 h5 gxh6 Kh7 Qf3 f6 Qe3 b5 Qe6 Rf8 Rc1 Rxc1+ Rxc1 Qa7 Rh1 b4 Rh3 f5 Rg3 Rf6 Qc8 f4 Rb3 f3 Qh3 Qg1+ Ka2 f2 Rf3 f1=Q Rxf1 Qxf1 Qe3 Rf7 axb4 Qa6+ Kb3 Qb7 Qe4 Qd7 Qd3 e6 b5 e5 b6 Rf4 Qa6 Rf7 Kb4 g5 Ka5 g4 b3 g3 Qd3+ Qf5 Qxg3 Qf3 b7 Qxg3 b8=Q Qc3+ Ka4 Rf4+ b4 Rc4 Qxd6 Qc2+ Kb5 e4 Qe7+ Kg6 h7 Rc7 h8=N+ Kf5 Qe6+ Kf4 Ng6+ Kf3 Qh3+ Ke2 Nf4+ Kd2 Qg2+ Kc3 Ne2+ Kb2 d6 Qd3+ Kb6 Qxd6+ Kb5 Qd5+ Kb6 Rb7+ Ka6 Qb5#".split(separator: " ").map(String.init)

    @Test func readsTheWholeGame() {
        let r = GameTextReader.read(Self.read)
        #expect(r.stoppedAt == nil)
        #expect(r.moves == Self.game.map { $0 == "O-O" || $0 == "O-O-O" ? $0 : $0 })
        print("corrections:", r.corrections.map { "\($0.read)->\($0.san)" })
    }
}
