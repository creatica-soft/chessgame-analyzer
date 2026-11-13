# Chess Analyzer (iOS)

Set up a position, and the creatica_ab engine from [libchess](https://github.com/creatica-soft/libchess)
analyses it on the phone: score, best move and principal variation.

## Build

Requires Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and a libchess checkout at
`../libchess` (override `LIBCHESS_DIR` in `project.yml`).

    xcodegen generate
    open ChessAnalyzer.xcodeproj

There are no iOS simulator runtimes on the development Mac, so build and test on a device:

    xcodebuild -scheme ChessAnalyzer -destination 'id=<device udid>' -allowProvisioningUpdates test

## How the engine is hosted

The engine is compiled from the libchess sources unchanged; see `EngineBridge/CreaticaBridge.cpp`.
`creatica_ab.cpp`'s `main()` is renamed at compile time and run on a thread, `std::cin` reads from a
command queue, and C `stdout` is a `funopen()` stream that hands each output line to Swift. The app
then speaks plain UCI to it (`App/Engine/EngineService.swift`). libcurl, used only for the online
tablebase, is replaced by a stub (`EngineBridge/compat/curl/curl.h`), and that option is off.

## License

The NNUE code and networks in libchess come from Stockfish (GPL-3), so the app is a GPL-3 work.
