// Runs creatica_ab inside the app without changing a line of ~/libchess.
//
// The engine is a UCI program: uci_frontend.cpp reads commands with std::getline(std::cin) and
// everything it and creatica_ab.cpp print goes through C stdio's stdout (printf, vfprintf, fflush).
// Three substitutions make that work in-process:
//
//   1. main(). creatica_ab.cpp is compiled with -Dmain=creatica_ab_main (see project.yml), so its
//      five-line main() becomes an ordinary function this file calls on a thread of its own.
//   2. stdin. std::cin's buffer is replaced by CommandQueue, whose underflow() blocks until the
//      app sends a command. uci_frontend.cpp's getline loop never notices.
//   3. stdout. On Darwin `stdout` is the variable __stdoutp, so it is pointed at a funopen()
//      stream whose write function splits the bytes into lines and hands each to the app. Every
//      printf in the engine lands there. File descriptor 1 is untouched.
//
// Side effect of 3: Swift's print() also writes to stdout, so its lines reach the callback too.
// The Swift side ignores lines that are not UCI, and Debug builds echo every line to stderr so
// the Xcode console still shows everything.
#include "CreaticaBridge.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <iostream>
#include <mutex>
#include <pthread.h>
#include <sstream>
#include <streambuf>
#include <string>

#include "nnue/bitboard.h"   // libchess.h requires nnue/types.h first
#include "libchess.h"

extern int creatica_ab_main(int argc, char ** argv);

namespace {

// ------------------------------------------------------------------ stdin

class CommandQueue : public std::streambuf {
public:
    void push(std::string line) {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            line.push_back('\n');
            queue_.push_back(std::move(line));
        }
        cv_.notify_one();
    }

protected:
    int_type underflow() override {
        if (gptr() < egptr()) return traits_type::to_int_type(*gptr());
        std::unique_lock<std::mutex> lk(mtx_);
        cv_.wait(lk, [this] { return !queue_.empty(); });
        current_ = std::move(queue_.front());
        queue_.pop_front();
        char * p = current_.data();
        setg(p, p, p + current_.size());
        return traits_type::to_int_type(*gptr());
    }

private:
    std::mutex mtx_;
    std::condition_variable cv_;
    std::deque<std::string> queue_;
    std::string current_;
};

CommandQueue g_commands;

// ------------------------------------------------------------------ stdout

creatica_line_callback g_callback = nullptr;
void * g_context = nullptr;
std::mutex g_out_mtx;
std::string g_partial;

// Readiness: the helpers below use libchess's attack tables, which the engine's init() builds on
// the engine thread. They wait for the first "readyok", which uci_frontend.cpp can only print
// after init() has returned.
std::mutex g_ready_mtx;
std::condition_variable g_ready_cv;
bool g_ready = false;

void deliver(const std::string& line) {
#ifdef CREATICA_ECHO_ENGINE   // set in Debug builds by project.yml
    std::fprintf(stderr, "[engine] %s\n", line.c_str());
#endif
    if (!g_ready && line == "readyok") {
        {
            std::lock_guard<std::mutex> lk(g_ready_mtx);
            g_ready = true;
        }
        g_ready_cv.notify_all();
    }
    if (g_callback) g_callback(line.c_str(), g_context);
}

int stdout_write(void *, const char * buf, int n) {
    std::lock_guard<std::mutex> lk(g_out_mtx);
    g_partial.append(buf, (size_t)n);
    size_t start = 0;
    for (size_t nl; (nl = g_partial.find('\n', start)) != std::string::npos; start = nl + 1) {
        std::string line = g_partial.substr(start, nl - start);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        deliver(line);
    }
    g_partial.erase(0, start);
    return n;
}

void * engine_thread(void *) {
    char name[] = "creatica_ab";
    char * argv[] = {name, nullptr};
    creatica_ab_main(1, argv);
    deliver("info string engine loop exited");
    return nullptr;
}

bool wait_ready() {
    std::unique_lock<std::mutex> lk(g_ready_mtx);
    return g_ready_cv.wait_for(lk, std::chrono::seconds(30), [] { return g_ready; });
}

void write_reason(char * reason, int len, const char * text) {
    if (len <= 0) return;
    std::snprintf(reason, (size_t)len, "%s", text);
}

} // namespace

extern "C" void creatica_engine_start(creatica_line_callback callback, void * context) {
    static std::once_flag once;
    std::call_once(once, [&] {
        g_callback = callback;
        g_context = context;

        FILE * f = funopen(nullptr, nullptr, stdout_write, nullptr, nullptr);
        setvbuf(f, nullptr, _IOLBF, 0);
        stdout = f;
        std::cin.rdbuf(&g_commands);

        // The engine's own search threads get 8 MB stacks from pool_start(); this one only runs
        // the protocol loop, but secondary threads on iOS default to 512 KB, so be generous.
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 8u << 20);
        pthread_t thread;
        pthread_create(&thread, &attr, engine_thread, nullptr);
        pthread_attr_destroy(&attr);
        pthread_detach(thread);

        g_commands.push("isready");
    });
}

extern "C" void creatica_engine_send(const char * command) {
    g_commands.push(command);
}

extern "C" int creatica_validate_fen(const char * fen, char * reason, int reason_len) {
    if (!wait_ready()) { write_reason(reason, reason_len, "engine is not running"); return 0; }

    Board b{};
    if (fen2board(b, fen) != 0) { write_reason(reason, reason_len, "the FEN cannot be parsed"); return 0; }

    const uint64_t kings = b.pieceTypes[King - 1];
    for (Color c : {ColorWhite, ColorBlack}) {
        const char * who = c == ColorWhite ? "White" : "Black";
        char msg[96];
        const int nk = bitCount(b.side[c] & kings);
        if (nk != 1) {
            std::snprintf(msg, sizeof msg, "%s must have exactly one king (has %d)", who, nk);
            write_reason(reason, reason_len, msg);
            return 0;
        }
        if (bitCount(b.side[c]) > 16) {
            std::snprintf(msg, sizeof msg, "%s has more than 16 pieces", who);
            write_reason(reason, reason_len, msg);
            return 0;
        }
        if (bitCount(b.side[c] & b.pieceTypes[Pawn - 1]) > 8) {
            std::snprintf(msg, sizeof msg, "%s has more than 8 pawns", who);
            write_reason(reason, reason_len, msg);
            return 0;
        }
    }
    if (b.pieceTypes[Pawn - 1] & (RANK1 | RANK8)) {
        write_reason(reason, reason_len, "pawns cannot stand on the first or last rank");
        return 0;
    }

    // The side that just moved cannot have left its own king in check.
    Board flipped = b;
    flipped.sideToMove = b.sideToMove == ColorWhite ? ColorBlack : ColorWhite;
    if (getCheckers(flipped, kingSquare(flipped, flipped.sideToMove)) != 0) {
        write_reason(reason, reason_len, "the side not to move is in check");
        return 0;
    }
    if (bitCount(getCheckers(b, kingSquare(b, b.sideToMove))) > 2) {
        write_reason(reason, reason_len, "the king is attacked by more than two pieces");
        return 0;
    }
    return 1;
}

extern "C" int creatica_terminal_state(const char * fen) {
    if (!wait_ready()) return 0;
    Board b{};
    if (fen2board(b, fen) != 0) return 0;
    const BoardState bs = isCheckMateStaleMate(b);
    return bs.mate ? 1 : bs.stalemate ? 2 : 0;
}

extern "C" int creatica_uci_to_san(const char * fen, const char * uci_moves, char * out, int out_len) {
    if (out_len <= 0) return 0;
    out[0] = '\0';
    if (!wait_ready()) return 0;

    Board b{};
    if (fen2board(b, fen) != 0) return 0;

    std::istringstream in(uci_moves);
    std::string token, result;
    int converted = 0;
    while (in >> token) {
        if (token.size() < 4 || token.size() > 5) break;
        Move m = {};
        uci2move_idx(token.c_str(), m);
        normalise_castling(b, m);
        if (illegal_reason(b, m) != nullptr) break;

        // move2san() reads the pre-move board; it works out captures, castling and the check
        // or mate suffix itself.
        char san[16] = "";
        if (move2san(b, m, san) == nullptr) break;
        if (!result.empty()) result += ' ';
        result += san;
        StateInfo st{};
        do_move(b, m, st);
        ++converted;
    }
    std::snprintf(out, (size_t)out_len, "%s", result.c_str());
    return converted;
}

extern "C" int creatica_play_moves(const char * fen, const char * uci_moves, char * out_fen, int out_len) {
    if (out_len <= 0) return 0;
    out_fen[0] = '\0';
    if (!wait_ready()) return 0;

    Board b{};
    if (fen2board(b, fen) != 0) return 0;

    std::istringstream in(uci_moves);
    std::string token;
    int played = 0;
    while (in >> token) {
        if (token.size() < 4 || token.size() > 5) break;
        Move m = {};
        uci2move_idx(token.c_str(), m);
        normalise_castling(b, m);
        if (illegal_reason(b, m) != nullptr) break;
        StateInfo st{};
        do_move(b, m, st);
        ++played;
    }
    char buf[MAX_FEN_STRING_LEN];
    std::snprintf(out_fen, (size_t)out_len, "%s", board2fen(b, buf));
    return played;
}
