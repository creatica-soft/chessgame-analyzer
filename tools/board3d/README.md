# Real board piece classifier

`App/Resources/PieceClassifier.mlpackage` names the piece standing on one square of a photo of a real
board, from a tall crop of that square. `App/Engine/BoardFinder.swift` and `BoardReader.swift` are the
app's side; `grid.py` here is the board finder they were ported from, where it was developed.

The training data is video of one board, filmed while a game was played through: a short clip
after each move, so every frame's position is known from the game's PGN. The clips themselves are
not in git (`tools/training/` is ignored).

1. Frames. `frames.swift` (AVFoundation; no ffmpeg needed) prints a clip's length and saves frames:

       swiftc -O -o frames frames.swift
       for f in ../training/*.MOV; do ./frames $f frames/q4 0.25 1280; done

   The labels: replay the PGN with python-chess. The first clips show the starting position;
   then each clip is the position after the next half-move (see the conversation of 2026-11-14:
   clips 9030-9032 are the start, 9033-9098 the 64 half-moves of `tools/game.pgn`).

2. The board in every frame (`locate.py`, uses `grid.py`): the 9 x 9 grid of square corners from
   the X-corners where four squares meet, the 8 x 8 block that is the board, and its corners named
   a1, h1, h8, a8 (camera on White's side: rank 1 nearest it). Frames where the squares' colours
   disagree with the naming (a1 must be dark) are left out.

       python3 locate.py frames/q4 located.json

   `eval_chessred.py` measures the finder against hand-marked corners of another board (ChessReD2K,
   CC BY-NC-SA; used for measuring only).

3. Crops (`crops.py`): each square as a 48 x 96 RGB crop, as wide as the square and reaching 2.4
   widths of its front edge up the picture, where its piece shows. The constants must match
   `BoardReader` (`wide`, `tall`, `below`, crop size).

       python3 crops.py frames/q4 located.json labels.json crops.npz

4. Train (PyTorch, MPS) with every fourth clip held out, and export:

       python3 train3d.py crops.npz piecenet.pt 10
       python3 export3d.py piecenet.pt ../../App/Resources/PieceClassifier.mlpackage

   Results on the held-out clips (16 clips, 470 frames at four a second): the shipped model,
   trained 10 epochs on four frames a second, reads 96.2% of frames with every square right
   (95.3% for the first, trained on one frame a second); nearly all the rest are frames whose grid
   was placed a square off. All of these clips are filmed from White's side: views from the side
   or corner-on are read poorly, and need clips filmed from there.
