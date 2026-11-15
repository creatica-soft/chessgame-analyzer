"""Positions to render: the start, the positions of tools/game.pgn, and random legal games cut at
every length, so that boards from full to nearly empty, and every piece on every kind of square,
turn up. (The classifier names one square at a time; how natural the whole position is matters
less than variety.)

usage: positions.py out.json count [seed]
"""
import sys, json, random, os
import chess, chess.pgn

if __name__ == '__main__':
    out, count = sys.argv[1], int(sys.argv[2])
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 0)
    fens = [chess.Board().board_fen()]
    pgn = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'game.pgn')
    game = chess.pgn.read_game(open(pgn))
    board = game.board()
    for move in game.mainline_moves():
        board.push(move)
        fens.append(board.board_fen())
    while len(fens) < count:
        board = chess.Board()
        # Mostly openings and middlegames, some endgames.
        plies = int(rng.triangular(0, 160, 30))
        for _ in range(plies):
            moves = list(board.legal_moves)
            if not moves:
                break
            # Captures a little more often than chance, so that material comes off the board.
            captures = [m for m in moves if board.is_capture(m)]
            board.push(rng.choice(captures if captures and rng.random() < 0.3 else moves))
        fens.append(board.board_fen())
    rng.shuffle(fens)
    json.dump(fens[:count], open(out, 'w'))
    print(len(fens[:count]), 'positions')
