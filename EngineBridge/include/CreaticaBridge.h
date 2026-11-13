// The C interface between the Swift app and the creatica_ab engine from ~/libchess.
//
// The engine is driven by UCI, exactly as a desktop GUI drives it: the app sends command lines and
// receives every line the engine prints. Nothing in libchess is modified to make that possible;
// see CreaticaBridge.cpp for how stdin and stdout are rerouted.
#ifndef CREATICA_BRIDGE_H
#define CREATICA_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Receives one complete output line from the engine, without the trailing newline.
/// Called on an engine thread, never on the main thread.
typedef void (*creatica_line_callback)(const char * _Nonnull line, void * _Nullable context);

/// Starts the engine's UCI loop on its own thread. Only the first call does anything: the engine
/// keeps process-wide state, so there is exactly one per process.
void creatica_engine_start(creatica_line_callback _Nonnull callback, void * _Nullable context);

/// Queues one UCI command ("position fen ...", "go infinite", "stop", ...), without a newline.
void creatica_engine_send(const char * _Nonnull command);

/// Checks that a FEN describes a position the engine can search. Returns 1 if it can. Otherwise
/// returns 0 and writes the reason, NUL-terminated, into `reason`.
int creatica_validate_fen(const char * _Nonnull fen, char * _Nonnull reason, int reason_len);

/// For a valid position: 0 if the side to move has a legal move, 1 if it is checkmated, 2 if it
/// is stalemated.
int creatica_terminal_state(const char * _Nonnull fen);

/// Converts the space-separated long-algebraic moves `uci_moves`, played from `fen`, into SAN,
/// space-separated, written NUL-terminated into `out`. Stops at the first illegal move. Returns
/// how many moves it converted.
int creatica_uci_to_san(const char * _Nonnull fen, const char * _Nonnull uci_moves,
                        char * _Nonnull out, int out_len);

/// Plays the space-separated long-algebraic moves `uci_moves` from `fen` and writes the FEN of the
/// resulting position into `out_fen`. Stops at the first illegal move. Returns how many it played.
int creatica_play_moves(const char * _Nonnull fen, const char * _Nonnull uci_moves,
                        char * _Nonnull out_fen, int out_len);

#ifdef __cplusplus
}
#endif

#endif
