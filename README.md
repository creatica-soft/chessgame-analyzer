# Chess Analyzer (iOS)

The creatica_ab engine from [libchess](https://github.com/creatica-soft/libchess), on the phone.

- **Position**: set up a position (or paste a FEN) and see the score, best move and principal
  variation.
- **Games**: paste, type or open a PGN (`.pgn` files can also be opened in the app from Files).
  A game opens without analysis; **Analyze Game** searches every position once, and each move is
  marked as an inaccuracy, mistake or blunder by the pawns it loses against the engine's best move
  (0.3 / 1 / 2 by default, in Settings). The board's arrow shows the move that should have been
  played instead, and the engine's line can be played through on the board. Shows an evaluation
  graph, a per-player summary with average centipawn loss, and exports the game as annotated PGN
  (`[%eval]` comments, NAGs, and the corrections as variations).

- **Scanning**: a printed game can be read from the camera (the system document scanner), a photo,
  or a copied picture. Text recognition runs on the phone; `GameTextReader` then rebuilds the game
  using move numbers (so two-column pages, commentary, line numbers and PGN headers don't matter)
  and legality: a misread word is matched against the legal moves, with the usual recognition
  confusions cheap (8/B, 0/O, l/1, t/f, capitals, Cyrillic lookalikes, `&` for 8, `†` for f). When
  two legal moves are equally close, each is read on for up to 60 plies and the one that needs
  clearly less correcting later wins. Every guess is shown for review, and the recognised text
  can be corrected and read again. Loose text pasted from Live Text goes the same way.

When the phone gets warm the engine drops to 2 threads, and to 1 when it is hot; analysis
continues.

The two tabs share the one engine; the hidden tab's analysis pauses.

## Build

Requires Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and a libchess checkout at
`../libchess` (override `LIBCHESS_DIR` in `project.yml`).

    xcodegen generate
    open ChessAnalyzer.xcodeproj

Tests run on a simulator or a device:

    xcodebuild -scheme ChessAnalyzer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
    xcodebuild -scheme ChessAnalyzer -destination 'id=<device udid>' -allowProvisioningUpdates test

A Debug build launched with `-demoGame` analyses a sample game and writes progress and the
annotated PGN to stderr, for checking a device run from the console; `-demoScan` reads a rendered
two-column book page through the scanning path and opens its review. Every scan or paste is saved
(image and recognised text, the last ten) in the app's Documents/Imports, visible in Files, so a
page that read badly can be examined:

    xcrun devicectl device process launch --console --device <udid> org.creatica.chessanalyzer -demoGame

## How the engine is hosted

The engine is compiled from the libchess sources unchanged; see `EngineBridge/CreaticaBridge.cpp`.
`creatica_ab.cpp`'s `main()` is renamed at compile time and run on a thread, `std::cin` reads from a
command queue, and C `stdout` is a `funopen()` stream that hands each output line to Swift. The app
then speaks plain UCI to it (`App/Engine/EngineService.swift`). libcurl, used only for the online
tablebase, is replaced by a stub (`EngineBridge/compat/curl/curl.h`), and that option is off.

## License

The NNUE code and networks in libchess come from Stockfish (GPL-3), so the app is a GPL-3 work.
